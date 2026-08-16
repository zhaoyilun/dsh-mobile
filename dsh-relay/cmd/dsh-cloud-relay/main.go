// dsh-cloud-relay is a single-binary public relay: phones hit this server over
// HTTPS, and each request is multiplexed through the WebSocket tunnel that the
// local dsh-local-relay process established. It knows nothing about the
// business. Phone access is gated by a single passphrase accepted in one of
// three forms (all compared in constant time): the X-DC-Pass header
// (programmatic clients), the ?pass= query parameter (the mobile WebView's
// first navigation, which cannot set custom headers) or the dsh_relay_pass
// session cookie set on the first success. A failed attempt answers 401 after
// a fixed delay; WebSocket upgrades are authenticated without redirect.
// Protocol (one JSON message per WebSocket message, both directions):
//
//	local -> cloud: {"type":"hello","token":"<tunnel-token>"}
//	cloud -> local: {"type":"ok"}
//	cloud -> local: {"type":"req","id":17,"request":"<base64 of httputil.DumpRequest>"}
//	local -> cloud: {"type":"head","id":17,"status":200,"header":{...}}
//	local -> cloud: {"type":"chunk","id":17,"data":"<base64>"}   (any number)
//	local -> cloud: {"type":"end","id":17}
//	local -> cloud: {"type":"error","id":17}   (request failed)
//
// WebSocket passthrough (for DSH's /api/events.mux and /api/events.host): a
// phone request carrying "Upgrade: websocket" is not relayed as an ordinary
// request but as an upgrade session:
//
//	cloud -> local: {"type":"upgreq","id":18,"request":"<base64 of httputil.DumpRequest>"}
//	local -> cloud: {"type":"upg-ok","id":18}   (local host answered 101)
//	either  -> :    {"type":"upg-bin","id":18,"data":"<base64 of WS frame payload>"}
//	either  -> :    {"type":"upg-end","id":18}  (close the other end)
//
// The phone connection is upgraded only after "upg-ok": if the local host
// answers the handshake with a plain HTTP response (401/403/redirect...), the
// local relay falls back to the ordinary head/chunk/end path and the phone's
// WebSocket client receives a normal HTTP error.
package main

import (
	"context"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httputil"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
)

// version is printed by --version.
const version = "0.1.0"

// Phone passphrase credentials. The session cookie is set on the first
// successful authentication (via header or query) and is thereafter accepted
// on its own.
const (
	passHeader = "X-DC-Pass" // programmatic clients
	passCookie = "dsh_relay_pass"
)

// authFailDelay is the fixed delay before answering a failed phone
// authentication, to slow down passphrase brute force (aligned with DSH's
// /pair behavior).
const authFailDelay = 1 * time.Second

func main() {
	listen := flag.String("listen", ":8090", "listen address (behind nginx/caddy) or :443 for direct TLS")
	tunnelToken := flag.String("tunnel-token", "", "token the local relay must present (required)")
	phonePass := flag.String("phone-pass", "", "access passphrase phones must present (required)")
	tlsCert := flag.String("tls-cert", "", "optional TLS certificate path (direct mode)")
	tlsKey := flag.String("tls-key", "", "optional TLS key path (direct mode)")
	showVersion := flag.Bool("version", false, "print version and exit")
	flag.Parse()
	if *showVersion {
		fmt.Println("dsh-cloud-relay " + version)
		return
	}
	if *tunnelToken == "" || *phonePass == "" {
		log.Fatal("--tunnel-token and --phone-pass are required")
	}

	relay := &relay{
		tunnelToken: *tunnelToken,
		phonePass:   *phonePass,
		pending:     make(map[int64]chan []byte),
		upgs:        make(map[int64]*phoneUpg),
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/tunnel", relay.handleTunnel)
	mux.HandleFunc("/healthz", handleHealthz)
	mux.HandleFunc("/", relay.handlePhone)

	server := &http.Server{Addr: *listen, Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	log.Printf("dsh-cloud-relay listening on %s (tls=%v)", *listen, *tlsCert != "")
	var err error
	if *tlsCert != "" {
		err = server.ListenAndServeTLS(*tlsCert, *tlsKey)
	} else {
		err = server.ListenAndServe()
	}
	log.Fatal(err)
}

type relay struct {
	tunnelToken string
	phonePass   string
	mu          sync.Mutex
	conn        *websocket.Conn
	hello       atomic.Bool // true once the local relay presented a valid hello
	writeMu     sync.Mutex
	nextID      atomic.Int64
	pending     map[int64]chan []byte // response channels for plain requests
	upgs        map[int64]*phoneUpg   // active WebSocket passthrough sessions
}

type wire struct {
	Type    string              `json:"type"`
	Token   string              `json:"token,omitempty"`
	ID      int64               `json:"id,omitempty"`
	Request string              `json:"request,omitempty"`
	Status  int                 `json:"status,omitempty"`
	Header  map[string][]string `json:"header,omitempty"`
	Data    string              `json:"data,omitempty"`
	Binary  bool                `json:"binary,omitempty"`
}

// upgEvent is one event routed from the tunnel to a phone upgrade session.
type upgEvent struct {
	bin    []byte
	binary bool
	end    bool
}

// phoneUpg is one WebSocket passthrough session on the cloud side. The phone
// connection has a single writer: the drain goroutine started by upgradePhone
// (gorilla/websocket permits only one concurrent writer per connection).
type phoneUpg struct {
	id     int64
	conn   *websocket.Conn // phone side; nil until the upgrade completes
	in     chan upgEvent   // buffered events from the tunnel
	done   chan struct{}   // closed when the session ends
	once   sync.Once
	tunnel *websocket.Conn // tunnel connection, for upg-bin/upg-end replies
}

// handleTunnel is the one long-lived WebSocket from the local relay.
func (r *relay) handleTunnel(w http.ResponseWriter, req *http.Request) {
	if subtle.ConstantTimeCompare([]byte(req.URL.Query().Get("token")), []byte(r.tunnelToken)) != 1 {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	upgrader := websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}
	conn, err := upgrader.Upgrade(w, req, nil)
	if err != nil {
		log.Printf("tunnel upgrade: %v", err)
		return
	}
	r.mu.Lock()
	if r.conn != nil {
		r.mu.Unlock()
		_ = conn.Close()
		log.Printf("second tunnel rejected")
		return
	}
	r.conn = conn
	r.mu.Unlock()
	log.Printf("tunnel established from %s", req.RemoteAddr)

	// Reader: route every tunnel message to the pending request, the matching
	// upgrade session, or discard.
	defer func() {
		r.mu.Lock()
		if r.conn == conn {
			r.conn = nil
			r.hello.Store(false)
		}
		upgs := make([]*phoneUpg, 0, len(r.upgs))
		for _, u := range r.upgs {
			upgs = append(upgs, u)
		}
		r.mu.Unlock()
		_ = conn.Close()
		for _, u := range upgs {
			r.finishUpg(u, false) // unblocks the phone pumps; tunnel is gone
		}
		log.Printf("tunnel closed")
	}()
	for {
		_, payload, err := conn.ReadMessage()
		if err != nil {
			return
		}
		var msg wire
		if json.Unmarshal(payload, &msg) != nil {
			continue
		}
		if msg.Type == "hello" {
			if subtle.ConstantTimeCompare([]byte(msg.Token), []byte(r.tunnelToken)) != 1 {
				// Bad token: drop the connection without answering.
				return
			}
			r.hello.Store(true)
			r.write(conn, wire{Type: "ok"})
			continue
		}
		r.mu.Lock()
		ch := r.pending[msg.ID]
		u := r.upgs[msg.ID]
		r.mu.Unlock()
		switch msg.Type {
		case "upg-bin", "upg-end":
			if u == nil {
				continue
			}
			u.route(msg)
		default:
			if ch != nil {
				select {
				case ch <- payload:
				default:
				}
			}
		}
	}
}

// route forwards one tunnel message to the phone upgrade session. It runs on
// the tunnel reader and only enqueues: the drain goroutine is the phone
// connection's single writer.
func (u *phoneUpg) route(msg wire) {
	switch msg.Type {
	case "upg-bin":
		data, err := base64.StdEncoding.DecodeString(msg.Data)
		if err != nil {
			log.Printf("upg %d: bad upg-bin base64", u.id)
			return
		}
		select {
		case u.in <- upgEvent{bin: data, binary: msg.Binary}:
		default:
			log.Printf("upg %d: phone buffer full, dropping frame", u.id)
		}
	case "upg-end":
		select {
		case u.in <- upgEvent{end: true}:
		default:
		}
	}
}

// phoneAuth is the outcome of authenticating a phone request against the
// phone passphrase.
type phoneAuth int

const (
	authFail     phoneAuth = iota // no valid credential: 401 after a fixed delay
	authByCookie                  // valid dsh_relay_pass cookie: session already established
	authByQuery                   // valid ?pass=: establish the session and (plain HTTP) redirect
	authByHeader                  // valid X-DC-Pass header: establish the session, no redirect
)

// authenticatePhone accepts the passphrase in any of its three forms, all
// compared in constant time (crypto/subtle): the dsh_relay_pass cookie, the
// ?pass= query parameter (WebView first navigation) and the X-DC-Pass header
// (programmatic clients). Query is preferred over header so a valid ?pass=
// always leaves the address bar via the redirect.
func (r *relay) authenticatePhone(req *http.Request) phoneAuth {
	pass := []byte(r.phonePass)
	if c, err := req.Cookie(passCookie); err == nil {
		if subtle.ConstantTimeCompare([]byte(c.Value), pass) == 1 {
			return authByCookie
		}
	}
	if q := req.URL.Query().Get("pass"); q != "" {
		if subtle.ConstantTimeCompare([]byte(q), pass) == 1 {
			return authByQuery
		}
	}
	if h := req.Header.Get(passHeader); h != "" {
		if subtle.ConstantTimeCompare([]byte(h), pass) == 1 {
			return authByHeader
		}
	}
	return authFail
}

// setPassCookie establishes the phone session cookie.
func setPassCookie(w http.ResponseWriter, pass string) {
	http.SetCookie(w, sessionCookie(pass))
}

func sessionCookie(pass string) *http.Cookie {
	return &http.Cookie{
		Name:     passCookie,
		Value:    pass,
		Path:     "/",
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
	}
}

// ctxSetCookieKey carries the passphrase to set on a WebSocket upgrade
// response. gorilla's Upgrader writes the 101 response itself from the raw
// socket (it ignores w.Header()), so a session cookie for a first success that
// rides an upgrade must be passed through the responseHeader argument instead.
type ctxSetCookieKey struct{}

func requestWithSessionCookie(req *http.Request, pass string) *http.Request {
	return req.WithContext(context.WithValue(req.Context(), ctxSetCookieKey{}, pass))
}

// redirectStripPass answers with a 302 to the same path with the ?pass=
// parameter removed (other query parameters survive), so the passphrase leaves
// the address bar. The target is derived from the request URL only, never from
// client-supplied Location data, and paths that would resolve to another host
// ("//host" or backslash tricks) are refused, so no open redirect is possible.
func redirectStripPass(w http.ResponseWriter, req *http.Request) {
	u := *req.URL
	if strings.HasPrefix(u.Path, "//") || strings.Contains(u.Path, "\\") {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	q := u.Query()
	q.Del("pass")
	u.RawQuery = q.Encode()
	http.Redirect(w, req, u.RequestURI(), http.StatusFound)
}

// handleHealthz is the unauthenticated liveness endpoint for monitoring and
// load-balancer probes; it returns a fixed "ok" body and leaks nothing.
func handleHealthz(w http.ResponseWriter, req *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	_, _ = io.WriteString(w, "ok")
}

// handlePhone authenticates the phone and forwards the request through the
// tunnel. The three credentials are checked in authenticatePhone; a first
// success via header or query establishes the cookie session, and a query
// success additionally 302-redirects to the same path without the passphrase.
// WebSocket upgrade requests are never redirected (WebSocket clients cannot
// follow 3xx): they are authenticated and upgraded directly, carrying the
// session cookie to the phone in the 101 response. SSE and other streams flow
// through the same multiplexed channel.
func (r *relay) handlePhone(w http.ResponseWriter, req *http.Request) {
	upgrade := strings.EqualFold(req.Header.Get("Upgrade"), "websocket")
	switch r.authenticatePhone(req) {
	case authFail:
		time.Sleep(authFailDelay)
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	case authByQuery:
		if upgrade {
			// no redirect on upgrade; the cookie rides the 101 response
			req = requestWithSessionCookie(req, r.phonePass)
			break
		}
		setPassCookie(w, r.phonePass)
		redirectStripPass(w, req)
		return
	case authByHeader:
		if upgrade {
			req = requestWithSessionCookie(req, r.phonePass)
			break
		}
		setPassCookie(w, r.phonePass) // first success via header: establish the session
	case authByCookie:
		// session already established
	}
	// Nothing is forwarded until the local relay completed the hello handshake.
	if !r.hello.Load() {
		http.Error(w, "local host not ready", http.StatusBadGateway)
		return
	}
	if upgrade {
		r.handlePhoneUpgrade(w, req)
		return
	}
	dump, err := httputil.DumpRequest(req, true)
	if err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	id := r.nextID.Add(1)
	ch := make(chan []byte, 64)
	r.mu.Lock()
	if r.conn == nil {
		r.mu.Unlock()
		http.Error(w, "local host unreachable", http.StatusBadGateway)
		return
	}
	conn := r.conn
	r.pending[id] = ch
	r.mu.Unlock()
	defer func() {
		r.mu.Lock()
		delete(r.pending, id)
		r.mu.Unlock()
	}()

	if err := r.write(conn, wire{Type: "req", ID: id, Request: base64.StdEncoding.EncodeToString(dump)}); err != nil {
		http.Error(w, "tunnel write failed", http.StatusBadGateway)
		return
	}
	r.streamResponse(w, ch, id)
}

// handlePhoneUpgrade forwards a phone WebSocket handshake through the tunnel.
// The phone is not upgraded until the local relay confirms the local host
// answered 101 ("upg-ok"); if the local host answers with a plain HTTP
// response instead, that response is relayed verbatim so the phone's
// WebSocket client sees an ordinary HTTP error.
func (r *relay) handlePhoneUpgrade(w http.ResponseWriter, req *http.Request) {
	dump, err := httputil.DumpRequest(req, true)
	if err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	id := r.nextID.Add(1)
	ch := make(chan []byte, 64)
	u := &phoneUpg{
		id:   id,
		in:   make(chan upgEvent, 1024),
		done: make(chan struct{}),
	}
	r.mu.Lock()
	if r.conn == nil {
		r.mu.Unlock()
		http.Error(w, "local host unreachable", http.StatusBadGateway)
		return
	}
	u.tunnel = r.conn
	r.pending[id] = ch
	r.upgs[id] = u
	r.mu.Unlock()
	defer func() {
		r.mu.Lock()
		delete(r.pending, id)
		if u.conn == nil {
			// The phone was never upgraded (fallback/error/timeout path): no
			// pumps are running, so drop the session from the registry.
			delete(r.upgs, id)
		}
		r.mu.Unlock()
	}()

	if err := r.write(u.tunnel, wire{Type: "upgreq", ID: id, Request: base64.StdEncoding.EncodeToString(dump)}); err != nil {
		http.Error(w, "tunnel write failed", http.StatusBadGateway)
		return
	}
	// Wait for the local relay's decision. The first message is either
	// "upg-ok" (upgrade the phone and pump frames) or the head of a plain
	// HTTP response (fall back to the ordinary relay path).
	deadline := time.NewTimer(30 * time.Second)
	defer deadline.Stop()
	for {
		select {
		case payload := <-ch:
			var msg wire
			if json.Unmarshal(payload, &msg) != nil || msg.ID != id {
				continue
			}
			if msg.Type == "upg-ok" {
				r.upgradePhone(w, req, u)
				return
			}
			switch msg.Type {
			case "head":
				r.applyHead(w, msg)
			case "chunk":
				data, err := base64.StdEncoding.DecodeString(msg.Data)
				if err != nil {
					continue
				}
				_, _ = w.Write(data)
				if f, ok := w.(http.Flusher); ok {
					f.Flush()
				}
			case "end":
				return
			case "error":
				http.Error(w, "local host error", http.StatusBadGateway)
				return
			}
		case <-deadline.C:
			http.Error(w, "tunnel timeout", http.StatusGatewayTimeout)
			return
		}
	}
}

// upgradePhone completes the WebSocket handshake with the phone and pumps
// frames in both directions between the phone connection and the tunnel.
func (r *relay) upgradePhone(w http.ResponseWriter, req *http.Request, u *phoneUpg) {
	upgrader := websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}
	// A first success via ?pass= or header must establish the session cookie.
	// The Upgrader writes the 101 response itself, so the cookie goes through
	// its responseHeader argument rather than w.Header().
	var responseHeader http.Header
	if pass, ok := req.Context().Value(ctxSetCookieKey{}).(string); ok {
		responseHeader = http.Header{}
		responseHeader.Add("Set-Cookie", sessionCookie(pass).String())
	}
	pc, err := upgrader.Upgrade(w, req, responseHeader)
	if err != nil {
		log.Printf("phone upgrade: %v", err)
		r.finishUpg(u, true) // tell the local relay to close the local socket
		return
	}
	r.mu.Lock()
	u.conn = pc
	r.mu.Unlock()
	log.Printf("phone upgraded id=%d from %s", u.id, req.RemoteAddr)

	// Phone -> tunnel: read data frames from the phone and forward the
	// payloads as upg-bin messages.
	go func() {
		for {
			mt, data, err := pc.ReadMessage()
			if err != nil {
				r.finishUpg(u, true)
				return
			}
			if err := r.write(u.tunnel, wire{
				Type:   "upg-bin",
				ID:     u.id,
				Data:   base64.StdEncoding.EncodeToString(data),
				Binary: mt == websocket.BinaryMessage,
			}); err != nil {
				r.finishUpg(u, true)
				return
			}
		}
	}()
	// Tunnel -> phone: drain buffered events and write the payloads to the
	// phone. This goroutine is the phone connection's single writer.
	go func() {
		for {
			select {
			case ev := <-u.in:
				if ev.end {
					r.finishUpg(u, false) // the tunnel signalled the end
					return
				}
				mt := websocket.TextMessage
				if ev.binary {
					mt = websocket.BinaryMessage
				}
				if err := pc.WriteMessage(mt, ev.bin); err != nil {
					r.finishUpg(u, true)
					return
				}
			case <-u.done:
				return
			}
		}
	}()
}

// finishUpg tears down one phone upgrade session: it closes the phone
// connection and, when the local relay did not already signal the end, sends
// upg-end so the local relay closes the local WebSocket socket too.
func (r *relay) finishUpg(u *phoneUpg, sendEnd bool) {
	u.once.Do(func() {
		close(u.done)
		r.mu.Lock()
		delete(r.upgs, u.id)
		pc := u.conn
		r.mu.Unlock()
		if pc != nil {
			_ = pc.Close()
		}
		if sendEnd && u.tunnel != nil {
			_ = r.write(u.tunnel, wire{Type: "upg-end", ID: u.id})
		}
		log.Printf("phone upgrade id=%d closed", u.id)
	})
}

// applyHead writes the relayed response head to the phone.
func (r *relay) applyHead(w http.ResponseWriter, msg wire) {
	w.Header().Set("X-DC-Relay", "cloud-relay")
	for k, values := range msg.Header {
		if k == http.CanonicalHeaderKey("X-DC-Relay") {
			continue // ours, do not let the local host clobber it
		}
		for _, v := range values {
			w.Header().Add(k, v)
		}
	}
	w.WriteHeader(msg.Status)
}

// streamResponse relays a local host response from the tunnel channel to the
// phone as a plain HTTP response: head, then chunks, until end.
func (r *relay) streamResponse(w http.ResponseWriter, ch chan []byte, id int64) {
	deadline := time.NewTimer(30 * time.Second)
	defer deadline.Stop()
	for {
		select {
		case payload := <-ch:
			var msg wire
			if json.Unmarshal(payload, &msg) != nil || msg.ID != id {
				continue
			}
			switch msg.Type {
			case "head":
				r.applyHead(w, msg)
			case "chunk":
				data, err := base64.StdEncoding.DecodeString(msg.Data)
				if err != nil {
					continue
				}
				_, _ = w.Write(data)
				if f, ok := w.(http.Flusher); ok {
					f.Flush()
				}
			case "end":
				return
			case "error":
				http.Error(w, "local host error", http.StatusBadGateway)
				return
			}
		case <-deadline.C:
			http.Error(w, "tunnel timeout", http.StatusGatewayTimeout)
			return
		}
	}
}

func (r *relay) write(conn *websocket.Conn, msg wire) error {
	payload, err := json.Marshal(msg)
	if err != nil {
		return err
	}
	r.writeMu.Lock()
	defer r.writeMu.Unlock()
	return conn.WriteMessage(websocket.TextMessage, payload)
}
