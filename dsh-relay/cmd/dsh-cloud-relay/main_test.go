package main

import (
	"bufio"
	"bytes"
	"encoding/base64"
	"encoding/json"
	"flag"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

// fakeLocalHost is the pretend local DSH instance behind the tunnel. It
// records the last path it served and answers with a fixed status, header and
// body so the test can verify everything was relayed.
func fakeLocalHost(t *testing.T) (*httptest.Server, *atomic.Value) {
	t.Helper()
	var sawPath atomic.Value
	sawPath.Store("")
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		sawPath.Store(r.URL.Path)
		w.Header().Set("X-Custom", "from-local")
		w.WriteHeader(201)
		_, _ = io.WriteString(w, "body-from-local")
	}))
	t.Cleanup(srv.Close)
	return srv, &sawPath
}

// serveFakeRelay runs the local-relay side of the protocol against the cloud
// relay: it decodes every "req", forwards it to the fake local host and
// answers with head/chunk/end messages. It stops when the connection closes.
func serveFakeRelay(t *testing.T, conn *websocket.Conn, localURL string) chan struct{} {
	t.Helper()
	done := make(chan struct{})
	go func() {
		defer close(done)
		for {
			_, payload, err := conn.ReadMessage()
			if err != nil {
				return
			}
			var msg wire
			if json.Unmarshal(payload, &msg) != nil || msg.Type != "req" {
				continue
			}
			dump, err := base64.StdEncoding.DecodeString(msg.Request)
			if err != nil {
				t.Errorf("fake relay: bad request base64: %v", err)
				return
			}
			req, err := http.ReadRequest(bufio.NewReader(bytes.NewReader(dump)))
			if err != nil {
				t.Errorf("fake relay: cannot parse dumped request: %v", err)
				return
			}
			req.URL.Scheme = "http"
			req.URL.Host = strings.TrimPrefix(localURL, "http://")
			req.RequestURI = ""
			req.Host = req.URL.Host
			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				t.Errorf("fake relay: forward to local host failed: %v", err)
				return
			}
			if err := conn.WriteJSON(wire{Type: "head", ID: msg.ID, Status: resp.StatusCode, Header: resp.Header}); err != nil {
				return
			}
			buf := make([]byte, 512)
			for {
				n, err := resp.Body.Read(buf)
				if n > 0 {
					if werr := conn.WriteJSON(wire{Type: "chunk", ID: msg.ID, Data: base64.StdEncoding.EncodeToString(buf[:n])}); werr != nil {
						return
					}
				}
				if err != nil {
					break
				}
			}
			_ = resp.Body.Close()
			if err := conn.WriteJSON(wire{Type: "end", ID: msg.ID}); err != nil {
				return
			}
		}
	}()
	return done
}

func dialTunnel(t *testing.T, cloudURL, token string) *websocket.Conn {
	t.Helper()
	wsURL := "ws" + strings.TrimPrefix(cloudURL, "http") + "/tunnel?token=" + token
	conn, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatalf("dial tunnel: %v", err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	return conn
}

func TestPhoneThroughTunnel(t *testing.T) {
	r := &relay{
		tunnelToken: "tunnel-token",
		phonePass:   "phone-pass",
		pending:     make(map[int64]chan []byte),
		upgs:        make(map[int64]*phoneUpg),
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/tunnel", r.handleTunnel)
	mux.HandleFunc("/", r.handlePhone)
	cloud := httptest.NewServer(mux)
	defer cloud.Close()

	local, sawPath := fakeLocalHost(t)

	phone := func(pass, path string) *http.Response {
		t.Helper()
		req, err := http.NewRequest(http.MethodGet, cloud.URL+path, nil)
		if err != nil {
			t.Fatalf("new phone request: %v", err)
		}
		req.Header.Set("X-DC-Pass", pass)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatalf("phone request: %v", err)
		}
		t.Cleanup(func() { _ = resp.Body.Close() })
		return resp
	}

	// 1. No tunnel established at all -> 502.
	resp := phone("phone-pass", "/api/items")
	if resp.StatusCode != http.StatusBadGateway {
		t.Fatalf("no tunnel: got status %d, want 502", resp.StatusCode)
	}

	// waitTunnelGone blocks until the relay has dropped the current tunnel,
	// so a later dial is never rejected as a "second tunnel".
	waitTunnelGone := func() {
		t.Helper()
		deadline := time.Now().Add(2 * time.Second)
		for {
			r.mu.Lock()
			gone := r.conn == nil
			r.mu.Unlock()
			if gone {
				return
			}
			if time.Now().After(deadline) {
				t.Fatalf("tunnel did not go away in time")
			}
			time.Sleep(5 * time.Millisecond)
		}
	}

	// 2. Tunnel connected but hello not yet received: the request must not be
	//    forwarded (502) and nothing may reach the relay socket. This probe
	//    connection is discarded afterwards (gorilla websocket caches read
	//    errors permanently, so a timed-out probe cannot be reused).
	probe := dialTunnel(t, cloud.URL, "tunnel-token")
	resp = phone("phone-pass", "/api/items")
	if resp.StatusCode != http.StatusBadGateway {
		t.Fatalf("before hello: got status %d, want 502", resp.StatusCode)
	}
	_ = probe.SetReadDeadline(time.Now().Add(250 * time.Millisecond))
	if _, _, err := probe.ReadMessage(); err == nil {
		t.Fatalf("tunnel forwarded a request before hello")
	} else if ne, ok := err.(net.Error); !ok || !ne.Timeout() {
		t.Fatalf("unexpected read result before hello: %v", err)
	}
	_ = probe.Close()
	waitTunnelGone()

	// 3. Wrong hello token -> the cloud relay closes the connection.
	conn := dialTunnel(t, cloud.URL, "tunnel-token")
	if err := conn.WriteJSON(wire{Type: "hello", Token: "wrong-token"}); err != nil {
		t.Fatalf("write bad hello: %v", err)
	}
	_ = conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, _, err := conn.ReadMessage(); err == nil {
		t.Fatalf("expected connection close after bad hello token, got a message")
	} else if ne, ok := err.(net.Error); ok && ne.Timeout() {
		t.Fatalf("connection stayed open after bad hello token")
	}
	_ = conn.SetReadDeadline(time.Time{})
	waitTunnelGone()

	// 4. Correct hello -> "ok", then requests flow.
	conn2 := dialTunnel(t, cloud.URL, "tunnel-token")
	if err := conn2.WriteJSON(wire{Type: "hello", Token: "tunnel-token"}); err != nil {
		t.Fatalf("write hello: %v", err)
	}
	_ = conn2.SetReadDeadline(time.Now().Add(2 * time.Second))
	_, payload, err := conn2.ReadMessage()
	if err != nil {
		t.Fatalf("read ok: %v", err)
	}
	var helloResp wire
	if err := json.Unmarshal(payload, &helloResp); err != nil || helloResp.Type != "ok" {
		t.Fatalf("expected ok, got %s", payload)
	}
	_ = conn2.SetReadDeadline(time.Time{})
	relayDone := serveFakeRelay(t, conn2, local.URL)
	defer func() {
		_ = conn2.Close()
		<-relayDone
	}()

	// 5. Correct passphrase: status/header/body from the local host come back,
	//    plus the X-DC-Relay marker.
	resp = phone("phone-pass", "/api/items")
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read relayed body: %v", err)
	}
	if resp.StatusCode != 201 {
		t.Fatalf("relayed status: got %d, want 201", resp.StatusCode)
	}
	if string(body) != "body-from-local" {
		t.Fatalf("relayed body: got %q, want %q", body, "body-from-local")
	}
	if got := resp.Header.Get("X-Custom"); got != "from-local" {
		t.Fatalf("relayed header X-Custom: got %q, want %q", got, "from-local")
	}
	if got := resp.Header.Get("X-DC-Relay"); got != "cloud-relay" {
		t.Fatalf("X-DC-Relay: got %q, want %q", got, "cloud-relay")
	}
	if got := sawPath.Load().(string); got != "/api/items" {
		t.Fatalf("local host saw path %q, want %q", got, "/api/items")
	}

	// 6. Wrong passphrase -> 401.
	resp = phone("wrong-pass", "/api/items")
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("wrong pass: got status %d, want 401", resp.StatusCode)
	}
}

func TestVersionFlag(t *testing.T) {
	oldArgs := os.Args
	oldCmd := flag.CommandLine
	defer func() {
		os.Args = oldArgs
		flag.CommandLine = oldCmd
	}()
	os.Args = []string{"dsh-cloud-relay", "-version"}
	flag.CommandLine = flag.NewFlagSet("dsh-cloud-relay", flag.ExitOnError)
	main() // must print the version and return before required-flag validation
}
