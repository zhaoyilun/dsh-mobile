package main

// Tests for the F3 tunnel heartbeat: the local relay sends WS ping frames and
// reconnects (via the existing exponential-backoff loop) when the peer stops
// answering with pongs.

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

// fakeCloud plays the cloud-relay side of the tunnel: it accepts the WS
// connection, answers the hello handshake with "ok" and then keeps reading.
// With pong=true it answers ping control frames with pongs (like the real
// cloud relay, whose gorilla default ping handler does this automatically);
// with pong=false it swallows them so the local relay's heartbeat times out.
type fakeCloud struct {
	srv   *httptest.Server
	wsURL string
	mu    sync.Mutex
	conns int             // accepted tunnel connections
	pings int             // ping control frames received
	cur   *websocket.Conn // most recent tunnel connection
}

// closeTunnel closes the current tunnel connection, unblocking the local
// relay's read loop (the relay itself runs forever and only returns when its
// context is canceled or the connection dies).
func (fc *fakeCloud) closeTunnel() {
	fc.mu.Lock()
	c := fc.cur
	fc.cur = nil
	fc.mu.Unlock()
	if c != nil {
		_ = c.Close()
	}
}

func newFakeCloud(t *testing.T, pong bool) *fakeCloud {
	t.Helper()
	fc := &fakeCloud{}
	upgrader := websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}
	mux := http.NewServeMux()
	mux.HandleFunc("/tunnel", func(w http.ResponseWriter, r *http.Request) {
		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer conn.Close()
		fc.mu.Lock()
		fc.conns++
		fc.cur = conn
		fc.mu.Unlock()
		defer func() {
			fc.mu.Lock()
			if fc.cur == conn {
				fc.cur = nil
			}
			fc.mu.Unlock()
		}()
		conn.SetPingHandler(func(appData string) error {
			fc.mu.Lock()
			fc.pings++
			fc.mu.Unlock()
			if !pong {
				return nil // swallow: the local relay must time out
			}
			return conn.WriteControl(websocket.PongMessage, []byte(appData), time.Now().Add(5*time.Second))
		})
		for {
			_, payload, err := conn.ReadMessage()
			if err != nil {
				return
			}
			var msg wire
			if json.Unmarshal(payload, &msg) != nil || msg.Type != "hello" {
				continue
			}
			if err := conn.WriteJSON(wire{Type: "ok"}); err != nil {
				return
			}
		}
	})
	fc.srv = httptest.NewServer(mux)
	t.Cleanup(fc.srv.Close)
	fc.wsURL = "ws" + strings.TrimPrefix(fc.srv.URL, "http") + "/tunnel?token=test-token"
	return fc
}

// testRelay builds a relay wired to the fake cloud with a short heartbeat.
func testRelay(cloudURL string, pingInterval time.Duration) *relay {
	localURL, _ := url.Parse("http://127.0.0.1:3080")
	return &relay{
		cloudURL:     cloudURL,
		token:        "test-token",
		localURL:     localURL,
		client:       &http.Client{},
		pingInterval: pingInterval,
		upgs:         make(map[int64]*upg),
	}
}

// TestLocalSendsPing: with a healthy peer the local relay emits ping frames on
// the configured interval (the fake cloud records them).
func TestLocalSendsPing(t *testing.T) {
	fc := newFakeCloud(t, true)
	r := testRelay(fc.wsURL, 50*time.Millisecond)
	ctx, cancel := context.WithCancel(context.Background())
	runDone := make(chan struct{})
	go func() {
		_ = r.run(ctx)
		close(runDone)
	}()
	deadline := time.Now().Add(3 * time.Second)
	for {
		fc.mu.Lock()
		n := fc.pings
		fc.mu.Unlock()
		if n >= 1 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("no ping received within 3s (pings=%d)", n)
		}
		time.Sleep(10 * time.Millisecond)
	}
	cancel()
	fc.closeTunnel() // unblock the tunnel read loop so run() can return
	select {
	case <-runDone:
	case <-time.After(2 * time.Second):
		t.Fatalf("run did not stop after cancel")
	}
}

// TestLocalReconnectsWhenTunnelDies: a peer that swallows pongs must be
// declared dead after 3x the ping interval, and the relay must reconnect
// through the existing exponential-backoff loop (a second tunnel connection is
// established).
func TestLocalReconnectsWhenTunnelDies(t *testing.T) {
	fc := newFakeCloud(t, false) // swallows pongs: the heartbeat must time out
	r := testRelay(fc.wsURL, 50*time.Millisecond)
	ctx, cancel := context.WithCancel(context.Background())
	runDone := make(chan struct{})
	go func() {
		_ = r.run(ctx)
		close(runDone)
	}()
	deadline := time.Now().Add(8 * time.Second)
	for {
		fc.mu.Lock()
		n := fc.conns
		fc.mu.Unlock()
		if n >= 2 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("no reconnect: tunnel connections=%d, want >= 2 (first died on missing pong, backoff reconnected)", n)
		}
		time.Sleep(20 * time.Millisecond)
	}
	cancel()
	fc.closeTunnel() // unblock the tunnel read loop so run() can return
	select {
	case <-runDone:
	case <-time.After(2 * time.Second):
		t.Fatalf("run did not stop after cancel")
	}
}
