package main

// End-to-end test of the WebSocket upgrade passthrough: the two real relay
// binaries are built and started as subprocesses with real listeners, a real
// tunnel is established, and a phone WebSocket client goes through
//
//	phone -> dsh-cloud-relay -> tunnel -> dsh-local-relay -> echo "DSH"
//
// covering the upgrade success path, bidirectional frame integrity, close
// propagation in both directions, and the non-101 fallback path.

import (
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

// newEchoServer is the pretend local DSH: a gorilla WebSocket echo endpoint
// plus a plain endpoint that rejects upgrades with 401 (for the fallback
// path). echoClosed turns true once a /ws connection's read loop ends (the
// relay closed the socket), and lastPayload records the latest message.
func newEchoServer(t *testing.T) (srv *httptest.Server, echoClosed *atomic.Bool, lastPayload *atomic.Value) {
	t.Helper()
	echoClosed = new(atomic.Bool)
	lastPayload = new(atomic.Value)
	lastPayload.Store("")
	upgrader := websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}
	mux := http.NewServeMux()
	mux.HandleFunc("/ws", func(w http.ResponseWriter, r *http.Request) {
		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer conn.Close()
		for {
			mt, data, err := conn.ReadMessage()
			if err != nil {
				echoClosed.Store(true)
				return
			}
			lastPayload.Store(string(data))
			if string(data) == "die" {
				// "die" makes the local host close the socket: the phone must
				// observe the close through the tunnel.
				_ = conn.WriteMessage(mt, []byte("bye"))
				return
			}
			if err := conn.WriteMessage(mt, data); err != nil {
				return
			}
		}
	})
	mux.HandleFunc("/reject", func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "forbidden by dsh", http.StatusUnauthorized)
	})
	// /plain reports how the request reached the local host, so the test can
	// assert the F2 loopback rewrite (Host points at the local endpoint, the
	// browser-only security headers are stripped).
	mux.HandleFunc("/plain", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, "host=%s|origin=%s|sec-fetch-mode=%s", r.Host, r.Header.Get("Origin"), r.Header.Get("Sec-Fetch-Mode"))
	})
	srv = httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv, echoClosed, lastPayload
}

// buildRelays builds both relay binaries into a temp dir.
func buildRelays(t *testing.T) (cloudBin, localBin string) {
	t.Helper()
	_, thisFile, _, _ := runtime.Caller(0)
	// thisFile is <root>/cmd/dsh-cloud-relay/e2e_test.go; three Dirs -> <root>.
	moduleRoot := filepath.Dir(filepath.Dir(filepath.Dir(thisFile)))
	dir := t.TempDir()
	cloudBin = filepath.Join(dir, "dsh-cloud-relay")
	localBin = filepath.Join(dir, "dsh-local-relay")
	for _, b := range []struct{ bin, pkg string }{
		{cloudBin, "./cmd/dsh-cloud-relay"},
		{localBin, "./cmd/dsh-local-relay"},
	} {
		cmd := exec.Command("go", "build", "-o", b.bin, b.pkg)
		cmd.Dir = moduleRoot
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("go build %s: %v\n%s", b.pkg, err, out)
		}
	}
	return cloudBin, localBin
}

func freePort(t *testing.T) int {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("free port: %v", err)
	}
	port := l.Addr().(*net.TCPAddr).Port
	_ = l.Close()
	return port
}

func startProc(t *testing.T, name, bin string, args ...string) {
	t.Helper()
	cmd := exec.Command(bin, args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		t.Fatalf("start %s: %v", name, err)
	}
	t.Cleanup(func() {
		_ = cmd.Process.Kill()
		_, _ = cmd.Process.Wait()
	})
}

// waitTunnelReady polls the cloud relay until the local relay completed the
// hello handshake (any status other than 502 proves the tunnel forwards).
func waitTunnelReady(t *testing.T, cloudURL, pass string) {
	t.Helper()
	deadline := time.Now().Add(20 * time.Second)
	for time.Now().Before(deadline) {
		req, _ := http.NewRequest(http.MethodGet, cloudURL+"/ping", nil)
		req.Header.Set("X-DC-Pass", pass)
		resp, err := http.DefaultClient.Do(req)
		if err == nil {
			_ = resp.Body.Close()
			if resp.StatusCode != http.StatusBadGateway {
				return
			}
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Fatal("tunnel never became ready")
}

func TestE2EUpgradePassthrough(t *testing.T) {
	cloudBin, localBin := buildRelays(t)
	echo, echoClosed, _ := newEchoServer(t)

	const tunnelToken = "tunnel-token-e2e"
	const phonePass = "phone-pass-e2e"
	cloudPort := freePort(t)
	cloudURL := fmt.Sprintf("http://127.0.0.1:%d", cloudPort)
	startProc(t, "cloud", cloudBin,
		"--listen", fmt.Sprintf("127.0.0.1:%d", cloudPort),
		"--tunnel-token", tunnelToken,
		"--phone-pass", phonePass)
	startProc(t, "local", localBin,
		"--cloud", fmt.Sprintf("ws://127.0.0.1:%d/tunnel?token=%s", cloudPort, tunnelToken),
		"--local", echo.URL)
	waitTunnelReady(t, cloudURL, phonePass)

	wsBase := "ws" + strings.TrimPrefix(cloudURL, "http")
	dial := func(path string, pass string) (*websocket.Conn, *http.Response, error) {
		return websocket.DefaultDialer.Dial(wsBase+path, http.Header{"X-DC-Pass": {pass}})
	}

	t.Run("plain-http-host-rewrite", func(t *testing.T) {
		// A phone request arrives with the public hostname and browser-only
		// security headers; the local relay must rewrite it so the DSH-side
		// host sees a loopback-originated client (F2): Host = the --local
		// endpoint, Origin and Sec-Fetch-* gone. This is what lets DSH serve
		// tunnel traffic with zero extra flags.
		req, err := http.NewRequest(http.MethodGet, cloudURL+"/plain", nil)
		if err != nil {
			t.Fatalf("new request: %v", err)
		}
		req.Header.Set("X-DC-Pass", phonePass)
		req.Header.Set("Origin", "https://relay.example.com")
		req.Header.Set("Sec-Fetch-Mode", "cors")
		req.Host = "relay.example.com"
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatalf("plain request through tunnel: %v", err)
		}
		defer resp.Body.Close()
		body, err := io.ReadAll(resp.Body)
		if err != nil {
			t.Fatalf("read body: %v", err)
		}
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("plain request: got status %d, want 200", resp.StatusCode)
		}
		wantHost := strings.TrimPrefix(echo.URL, "http://")
		want := fmt.Sprintf("host=%s|origin=|sec-fetch-mode=", wantHost)
		if string(body) != want {
			t.Fatalf("DSH-side view: got %q, want %q (Host must be the loopback endpoint, browser headers stripped)", body, want)
		}
	})

	t.Run("upgrade-echo-and-phone-close", func(t *testing.T) {
		pc, _, err := dial("/ws", phonePass)
		if err != nil {
			t.Fatalf("phone dial: %v", err)
		}
		defer pc.Close()
		// Bidirectional frame integrity through the whole chain.
		for _, want := range []string{"hello-1", "hello-2", "hello-3"} {
			if err := pc.WriteMessage(websocket.BinaryMessage, []byte(want)); err != nil {
				t.Fatalf("phone write: %v", err)
			}
			_, data, err := pc.ReadMessage()
			if err != nil {
				t.Fatalf("phone read: %v", err)
			}
			if string(data) != want {
				t.Fatalf("echo: got %q, want %q", data, want)
			}
		}
		// Phone closes: the local host's socket must observe the close.
		_ = pc.Close()
		deadline := time.Now().Add(5 * time.Second)
		for !echoClosed.Load() {
			if time.Now().After(deadline) {
				t.Fatalf("local host never saw the phone close")
			}
			time.Sleep(10 * time.Millisecond)
		}
	})

	t.Run("local-host-close-propagates", func(t *testing.T) {
		pc, _, err := dial("/ws", phonePass)
		if err != nil {
			t.Fatalf("phone dial: %v", err)
		}
		defer pc.Close()
		if err := pc.WriteMessage(websocket.BinaryMessage, []byte("die")); err != nil {
			t.Fatalf("phone write: %v", err)
		}
		_, data, err := pc.ReadMessage()
		if err != nil {
			t.Fatalf("phone read: %v", err)
		}
		if string(data) != "bye" {
			t.Fatalf("got %q, want %q", data, "bye")
		}
		// The local host closed: the phone must observe a close, not a hang.
		_ = pc.SetReadDeadline(time.Now().Add(5 * time.Second))
		if _, _, err := pc.ReadMessage(); err == nil {
			t.Fatalf("expected phone close after local host closed, got a message")
		}
	})

	t.Run("fallback-non-101", func(t *testing.T) {
		// The local host rejects the upgrade with 401: the phone's WebSocket
		// client must receive a plain HTTP 401 (no upgrade happened).
		_, resp, err := dial("/reject", phonePass)
		if err == nil {
			t.Fatalf("expected handshake failure, got a connection")
		}
		if resp == nil {
			t.Fatalf("expected a non-nil HTTP response alongside the handshake error")
		}
		if resp.StatusCode != http.StatusUnauthorized {
			t.Fatalf("fallback status: got %d, want 401", resp.StatusCode)
		}
	})

	t.Run("wrong-phone-pass", func(t *testing.T) {
		// The cloud rejects the handshake with 401 before any upgrade.
		_, resp, err := dial("/ws", "wrong-pass")
		if err == nil {
			t.Fatalf("expected handshake failure, got a connection")
		}
		if resp == nil || resp.StatusCode != http.StatusUnauthorized {
			t.Fatalf("wrong pass: got %+v, want 401", resp)
		}
	})
}
