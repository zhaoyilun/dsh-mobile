package main

import (
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func b64(s string) string { return base64.StdEncoding.EncodeToString([]byte(s)) }

// lockedConn serializes writes to a tunnel connection: the test body and the
// fake local relay both write to the same gorilla connection, which permits
// only one concurrent writer.
type lockedConn struct {
	mu sync.Mutex
	c  *websocket.Conn
}

func (l *lockedConn) writeJSON(v interface{}) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.c.WriteJSON(v)
}

// newCloudRelayServer wires a relay + mux exactly like main() and returns the
// running httptest server.
func newCloudRelayServer(t *testing.T) (*relay, *httptest.Server) {
	t.Helper()
	r := &relay{
		tunnelToken: "tunnel-token",
		phonePass:   "phone-pass",
		pending:     make(map[int64]chan []byte),
		upgs:        make(map[int64]*phoneUpg),
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/tunnel", r.handleTunnel)
	mux.HandleFunc("/healthz", handleHealthz)
	mux.HandleFunc("/", r.handlePhone)
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return r, srv
}

// fakeLocalRelayUpg speaks the tunnel protocol like the local relay, but only
// for upgrade sessions: it answers upgreq with upg-ok and echoes every
// upg-bin payload back (as if the local host echoed it), and it records
// whether a phone-initiated close arrived as upg-end.
func fakeLocalRelayUpg(t *testing.T, lc *lockedConn, closed *atomic.Bool) {
	t.Helper()
	go func() {
		for {
			_, payload, err := lc.c.ReadMessage()
			if err != nil {
				return
			}
			var msg wire
			if json.Unmarshal(payload, &msg) != nil {
				continue
			}
			switch msg.Type {
			case "upgreq":
				if err := lc.writeJSON(wire{Type: "upg-ok", ID: msg.ID}); err != nil {
					return
				}
			case "upg-bin":
				if err := lc.writeJSON(wire{Type: "upg-bin", ID: msg.ID, Data: msg.Data, Binary: msg.Binary}); err != nil {
					return
				}
			case "upg-end":
				closed.Store(true)
			}
		}
	}()
}

// dialPhoneUpg opens a phone WebSocket through the cloud relay.
func dialPhoneUpg(t *testing.T, cloudURL, pass, path string) *websocket.Conn {
	t.Helper()
	wsURL := "ws" + strings.TrimPrefix(cloudURL, "http") + path
	conn, _, err := websocket.DefaultDialer.Dial(wsURL, http.Header{"X-DC-Pass": {pass}})
	if err != nil {
		t.Fatalf("phone dial: %v", err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	return conn
}

func TestCloudUpgradeEchoAndClose(t *testing.T) {
	_, cloud := newCloudRelayServer(t)

	conn := dialTunnel(t, cloud.URL, "tunnel-token")
	lc := &lockedConn{c: conn}
	if err := lc.writeJSON(wire{Type: "hello", Token: "tunnel-token"}); err != nil {
		t.Fatalf("write hello: %v", err)
	}
	_, payload, err := conn.ReadMessage()
	if err != nil {
		t.Fatalf("read ok: %v", err)
	}
	var helloResp wire
	if err := json.Unmarshal(payload, &helloResp); err != nil || helloResp.Type != "ok" {
		t.Fatalf("expected ok, got %s", payload)
	}
	var phoneClosed atomic.Bool
	fakeLocalRelayUpg(t, lc, &phoneClosed)

	// 1. The phone upgrades and text/binary frames both round-trip through the
	//    echo with their frame type preserved.
	pc := dialPhoneUpg(t, cloud.URL, "phone-pass", "/api/events.mux")
	frames := []struct {
		mt   int
		body string
	}{
		{websocket.TextMessage, "text-1"},
		{websocket.TextMessage, "text-2"},
		{websocket.BinaryMessage, "binary-1"},
	}
	for _, frame := range frames {
		if err := pc.WriteMessage(frame.mt, []byte(frame.body)); err != nil {
			t.Fatalf("phone write: %v", err)
		}
		mt, data, err := pc.ReadMessage()
		if err != nil {
			t.Fatalf("phone read: %v", err)
		} else if string(data) != frame.body {
			t.Fatalf("echo: got %q, want %q", data, frame.body)
		} else if mt != frame.mt {
			t.Fatalf("echo message type: got %d, want %d", mt, frame.mt)
		}
	}

	// 2. The local relay may end the session (as if the local host closed):
	//    the phone must observe a close.
	if err := lc.writeJSON(wire{Type: "upg-end", ID: 1}); err != nil {
		t.Fatalf("write upg-end: %v", err)
	}
	_ = pc.SetReadDeadline(time.Now().Add(3 * time.Second))
	if _, _, err := pc.ReadMessage(); err == nil {
		t.Fatalf("expected phone close after tunnel upg-end, got a message")
	}

	// 3. A phone-initiated close must reach the local relay as upg-end.
	pc2 := dialPhoneUpg(t, cloud.URL, "phone-pass", "/api/events.mux")
	_ = pc2.WriteMessage(websocket.BinaryMessage, []byte("x"))
	_, _, _ = pc2.ReadMessage() // consume the echo
	_ = pc2.Close()
	deadline := time.Now().Add(3 * time.Second)
	for !phoneClosed.Load() {
		if time.Now().After(deadline) {
			t.Fatalf("local relay never saw upg-end after the phone closed")
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func TestCloudUpgradeFallbackNon101(t *testing.T) {
	_, cloud := newCloudRelayServer(t)

	conn := dialTunnel(t, cloud.URL, "tunnel-token")
	if err := conn.WriteJSON(wire{Type: "hello", Token: "tunnel-token"}); err != nil {
		t.Fatalf("write hello: %v", err)
	}
	_, payload, err := conn.ReadMessage()
	if err != nil {
		t.Fatalf("read ok: %v", err)
	}
	var helloResp wire
	if err := json.Unmarshal(payload, &helloResp); err != nil || helloResp.Type != "ok" {
		t.Fatalf("expected ok, got %s", payload)
	}

	// The fake local relay rejects the upgrade with a plain 401 response.
	go func() {
		for {
			_, payload, err := conn.ReadMessage()
			if err != nil {
				return
			}
			var msg wire
			if json.Unmarshal(payload, &msg) != nil || msg.Type != "upgreq" {
				continue
			}
			hdr := map[string][]string{"Content-Type": {"text/plain; charset=utf-8"}}
			if err := conn.WriteJSON(wire{Type: "head", ID: msg.ID, Status: 401, Header: hdr}); err != nil {
				return
			}
			if err := conn.WriteJSON(wire{Type: "chunk", ID: msg.ID, Data: b64("rejected by dsh")}); err != nil {
				return
			}
			if err := conn.WriteJSON(wire{Type: "end", ID: msg.ID}); err != nil {
				return
			}
		}
	}()

	wsURL := "ws" + strings.TrimPrefix(cloud.URL, "http") + "/api/events.mux"
	_, resp, err := websocket.DefaultDialer.Dial(wsURL, http.Header{"X-DC-Pass": {"phone-pass"}})
	if err == nil {
		t.Fatalf("expected handshake failure, got a connection")
	}
	if resp == nil {
		t.Fatalf("expected a non-nil HTTP response alongside the handshake error")
	}
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("fallback status: got %d, want 401", resp.StatusCode)
	}
}
