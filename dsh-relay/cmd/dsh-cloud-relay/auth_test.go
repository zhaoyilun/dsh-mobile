package main

// Tests for the F1 phone authentication (three credentials + cookie session)
// and the F4 /healthz endpoint.

import (
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

// noFollow is an HTTP client that never follows redirects, so 302 responses
// can be asserted directly.
var noFollow = &http.Client{
	CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
}

func doRequest(t *testing.T, req *http.Request) *http.Response {
	t.Helper()
	resp, err := noFollow.Do(req)
	if err != nil {
		t.Fatalf("request %s %s: %v", req.Method, req.URL, err)
	}
	t.Cleanup(func() { _ = resp.Body.Close() })
	return resp
}

func TestHealthz(t *testing.T) {
	_, cloud := newCloudRelayServer(t)
	resp, err := http.Get(cloud.URL + "/healthz")
	if err != nil {
		t.Fatalf("healthz: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("healthz status: got %d, want 200", resp.StatusCode)
	}
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read healthz body: %v", err)
	}
	if string(body) != "ok" {
		t.Fatalf("healthz body: got %q, want %q", body, "ok")
	}
}

// TestPhoneAuthCredentials covers the three credential forms. No tunnel is
// established, so a request that passes the auth gate answers 502 (local host
// not ready) instead of 401 — that status is the proof the credential was
// accepted.
func TestPhoneAuthCredentials(t *testing.T) {
	_, cloud := newCloudRelayServer(t)

	t.Run("header", func(t *testing.T) {
		req, err := http.NewRequest(http.MethodGet, cloud.URL+"/m/", nil)
		if err != nil {
			t.Fatalf("new request: %v", err)
		}
		req.Header.Set(passHeader, "phone-pass")
		resp := doRequest(t, req)
		if resp.StatusCode != http.StatusBadGateway {
			t.Fatalf("header auth: got %d, want 502 (auth accepted, no tunnel)", resp.StatusCode)
		}
		// First success via header establishes the session cookie.
		if got := resp.Header.Get("Set-Cookie"); !strings.HasPrefix(got, passCookie+"=phone-pass") {
			t.Fatalf("header auth: Set-Cookie %q, want prefix %q", got, passCookie+"=phone-pass")
		}
	})

	t.Run("query", func(t *testing.T) {
		req, err := http.NewRequest(http.MethodGet, cloud.URL+"/m/?pass=phone-pass&foo=bar", nil)
		if err != nil {
			t.Fatalf("new request: %v", err)
		}
		resp := doRequest(t, req)
		if resp.StatusCode != http.StatusFound {
			t.Fatalf("query auth: got %d, want 302", resp.StatusCode)
		}
		// Redirect target = same path, only the pass parameter stripped; the
		// passphrase leaves the address bar.
		if got := resp.Header.Get("Location"); got != "/m/?foo=bar" {
			t.Fatalf("query auth: Location %q, want %q", got, "/m/?foo=bar")
		}
		if got := resp.Header.Get("Set-Cookie"); !strings.HasPrefix(got, passCookie+"=phone-pass") {
			t.Fatalf("query auth: Set-Cookie %q, want prefix %q", got, passCookie+"=phone-pass")
		}
	})

	t.Run("cookie", func(t *testing.T) {
		req, err := http.NewRequest(http.MethodGet, cloud.URL+"/m/", nil)
		if err != nil {
			t.Fatalf("new request: %v", err)
		}
		req.AddCookie(&http.Cookie{Name: passCookie, Value: "phone-pass"})
		resp := doRequest(t, req)
		if resp.StatusCode != http.StatusBadGateway {
			t.Fatalf("cookie auth: got %d, want 502 (auth accepted, no tunnel)", resp.StatusCode)
		}
		// Session already established: no cookie is re-issued.
		if got := resp.Header.Get("Set-Cookie"); got != "" {
			t.Fatalf("cookie auth: unexpected Set-Cookie %q on an established session", got)
		}
	})

	t.Run("no-open-redirect", func(t *testing.T) {
		// A path starting with "//" must never produce a scheme-relative
		// Location (open redirect); the relay refuses to redirect instead.
		req, err := http.NewRequest(http.MethodGet, cloud.URL+"//evil.example.com?pass=phone-pass", nil)
		if err != nil {
			t.Fatalf("new request: %v", err)
		}
		resp := doRequest(t, req)
		if resp.StatusCode == http.StatusFound {
			if loc := resp.Header.Get("Location"); strings.HasPrefix(loc, "//") {
				t.Fatalf("open redirect: scheme-relative Location %q", loc)
			}
		}
	})
}

// TestPhoneAuthFailureDelay asserts the fixed ~1s delay on failed attempts.
func TestPhoneAuthFailureDelay(t *testing.T) {
	_, cloud := newCloudRelayServer(t)
	start := time.Now()
	req, err := http.NewRequest(http.MethodGet, cloud.URL+"/m/", nil)
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	req.Header.Set(passHeader, "wrong-pass")
	resp := doRequest(t, req)
	elapsed := time.Since(start)
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("wrong pass: got %d, want 401", resp.StatusCode)
	}
	if elapsed < 900*time.Millisecond {
		t.Fatalf("wrong pass answered in %s, want the fixed ~1s delay", elapsed)
	}
}

// TestPhoneUpgradeAuth covers WebSocket upgrade authentication: cookie and
// ?pass= both yield 101 (never a redirect), and no credentials is rejected
// with 401.
func TestPhoneUpgradeAuth(t *testing.T) {
	_, cloud := newCloudRelayServer(t)

	// Tunnel + hello + a fake local relay that answers every upgreq with
	// upg-ok (so the phone side completes the upgrade).
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

	wsBase := "ws" + strings.TrimPrefix(cloud.URL, "http")

	t.Run("upgrade-with-cookie", func(t *testing.T) {
		pc, _, err := websocket.DefaultDialer.Dial(wsBase+"/api/events.mux", http.Header{"Cookie": {passCookie + "=phone-pass"}})
		if err != nil {
			t.Fatalf("dial with cookie: %v", err)
		}
		_ = pc.Close()
	})

	t.Run("upgrade-with-query-pass", func(t *testing.T) {
		pc, resp, err := websocket.DefaultDialer.Dial(wsBase+"/api/events.mux?pass=phone-pass", nil)
		if err != nil {
			t.Fatalf("dial with ?pass=: %v", err)
		}
		defer pc.Close()
		// The cookie rides the 101 response so the WebView's next requests are
		// authenticated.
		if got := resp.Header.Get("Set-Cookie"); !strings.HasPrefix(got, passCookie+"=phone-pass") {
			t.Fatalf("upgrade with ?pass=: Set-Cookie %q, want prefix %q", got, passCookie+"=phone-pass")
		}
	})

	t.Run("upgrade-without-credentials", func(t *testing.T) {
		_, resp, err := websocket.DefaultDialer.Dial(wsBase+"/api/events.mux", nil)
		if err == nil {
			t.Fatalf("expected handshake rejection, got a connection")
		}
		if resp == nil || resp.StatusCode != http.StatusUnauthorized {
			t.Fatalf("no credentials: got %+v, want 401", resp)
		}
	})
}

// TestTunnelSurvivesPing proves the cloud side needs no heartbeat logic: the
// gorilla server's default ping handler answers pings with pongs automatically
// and the tunnel read loop is undisturbed (F3).
func TestTunnelSurvivesPing(t *testing.T) {
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

	local, _ := fakeLocalHost(t)
	relayDone := serveFakeRelay(t, conn, local.URL)
	defer func() {
		_ = conn.Close()
		<-relayDone
	}()

	// A ping control frame (the local relay's heartbeat) must be answered with
	// a pong by gorilla's default handler and must not disturb the tunnel.
	if err := conn.WriteControl(websocket.PingMessage, nil, time.Now().Add(time.Second)); err != nil {
		t.Fatalf("write ping: %v", err)
	}
	time.Sleep(100 * time.Millisecond) // let the pong round-trip

	req, err := http.NewRequest(http.MethodGet, cloud.URL+"/api/items", nil)
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	req.Header.Set(passHeader, "phone-pass")
	resp, err := noFollow.Do(req)
	if err != nil {
		t.Fatalf("phone request after ping: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("phone request after ping: got %d, want 201", resp.StatusCode)
	}
}
