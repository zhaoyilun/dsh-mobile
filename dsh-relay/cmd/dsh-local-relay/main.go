// Command dsh-local-relay is the local half of the tunnel pair: it keeps a
// WebSocket connection to the cloud relay (cmd/dsh-cloud-relay) and executes
// the multiplexed requests it receives against the local DSH instance
// (http://127.0.0.1:3080), streaming the responses back. It speaks the same
// protocol as the cloud side (one JSON message per WebSocket message, both
// directions):
//
//	local -> cloud: {"type":"hello","token":"<tunnel-token>"}
//	cloud -> local: {"type":"ok"}
//	cloud -> local: {"type":"req","id":17,"request":"<base64 of httputil.DumpRequest>"}
//	local -> cloud: {"type":"head","id":17,"status":200,"header":{...}}
//	local -> cloud: {"type":"chunk","id":17,"data":"<base64>"}   (any number)
//	local -> cloud: {"type":"end","id":17}
//	local -> cloud: {"type":"error","id":17}   (request failed)
//
// Every tunneled request is rewritten so the local host sees a
// loopback-originated client: the Host header is pointed at the local endpoint
// and the browser-only security headers (Origin, Sec-Fetch-*) are dropped, so
// DSH treats all tunnel traffic as loopback and needs no --trusted-host /
// --web-token for the remote path.
//
// WebSocket passthrough: a "upgreq" carries a phone WebSocket handshake. The
// relay rewrites the handshake the same way (Host + browser headers, plus the
// WebSocket handshake headers the dialer manages itself) and performs the
// upgrade itself:
//
//	cloud -> local: {"type":"upgreq","id":18,"request":"<base64 of httputil.DumpRequest>"}
//	local -> cloud: {"type":"upg-ok","id":18}   (local host answered 101)
//	either  -> :    {"type":"upg-bin","id":18,"data":"<base64 of WS frame payload>"}
//	either  -> :    {"type":"upg-end","id":18}  (close the other end)
//
// If the local host answers the handshake with a plain HTTP response instead,
// the relay falls back to the ordinary head/chunk/end path so the phone
// receives a normal HTTP error.
//
// The tunnel is kept alive forever: on any connection loss the relay
// reconnects with exponential backoff (1s, 2s, 4s, ... capped at 30s). A
// WebSocket ping is sent every --ping-interval (default 30s); the tunnel is
// considered dead when no pong (or any other message) arrives within three
// intervals, which then feeds the same reconnect loop.
package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

const (
	chunkSize      = 32 * 1024 // response body chunk size streamed over the tunnel
	initialBackoff = 1 * time.Second
	maxBackoff     = 30 * time.Second
	helloTimeout   = 15 * time.Second // how long to wait for the cloud's "ok"
)

// responseHeaderTimeout bounds how long a local request may take to produce
// response headers before it is aborted with an "error" message. A var so
// tests can shorten it.
var responseHeaderTimeout = 30 * time.Second

// wire is one protocol message (same shape as cmd/dsh-cloud-relay).
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

type relay struct {
	cloudURL string // full ws(s):// URL including ?token=
	token    string // tunnel token (also embedded in cloudURL)
	localURL *url.URL
	client   *http.Client

	// pingInterval is the WebSocket keepalive interval. A ping is sent every
	// interval and the read deadline is refreshed on every pong or other
	// message; if nothing arrives within 3*pingInterval the tunnel is
	// considered dead and the reconnect loop takes over. Zero disables the
	// heartbeat.
	pingInterval time.Duration

	// writeMu serializes tunnel writes: gorilla/websocket allows only one
	// concurrent writer, and requests are handled concurrently.
	writeMu sync.Mutex

	upgMu sync.Mutex
	upgs  map[int64]*upg // active WebSocket passthrough sessions
}

// upgEvent is one event routed from the tunnel to a passthrough session.
type upgEvent struct {
	bin    []byte
	binary bool
	end    bool
}

// upg is one WebSocket passthrough session on the local side: the upgraded
// connection to the local host. The local socket has a single writer, the
// pumpTunnelToLocal goroutine (gorilla/websocket permits only one concurrent
// writer per connection).
type upg struct {
	id   int64
	conn *websocket.Conn // upgraded connection to the local host
	in   chan upgEvent   // buffered events from the tunnel
	done chan struct{}   // closed when the session ends
	once sync.Once
}

func main() {
	cloud := flag.String("cloud", "", "cloud relay WebSocket URL, e.g. wss://relay.example.com/tunnel?token=SECRET (required)")
	local := flag.String("local", "http://127.0.0.1:3080", "local DSH base URL")
	pingInterval := flag.Duration("ping-interval", 30*time.Second, "WebSocket ping interval (tunnel keepalive); the tunnel is considered dead after 3x without a pong or any message; 0 disables the heartbeat")
	flag.Parse()
	if *cloud == "" {
		log.Fatal("--cloud is required (wss://host/tunnel?token=XXX)")
	}
	u, err := url.Parse(*cloud)
	if err != nil {
		log.Fatalf("invalid --cloud URL: %v", err)
	}
	token := u.Query().Get("token")
	if token == "" {
		log.Fatal("--cloud URL must include a ?token= query parameter")
	}
	localURL, err := url.Parse(*local)
	if err != nil || (localURL.Scheme != "http" && localURL.Scheme != "https") {
		log.Fatalf("invalid --local URL %q", *local)
	}
	r := newRelay(*cloud, token, localURL, *pingInterval)
	log.Printf("dsh-local-relay starting: cloud=%s local=%s ping-interval=%s", *cloud, localURL, *pingInterval)
	r.run(context.Background())
}

func newRelay(cloudURL, token string, localURL *url.URL, pingInterval time.Duration) *relay {
	transport := &http.Transport{
		DialContext: (&net.Dialer{
			Timeout:   10 * time.Second,
			KeepAlive: 30 * time.Second,
		}).DialContext,
		// The relay is a transparent pipe: if the local request does not
		// produce response headers within this window, fail it with "error".
		ResponseHeaderTimeout: responseHeaderTimeout,
	}
	client := &http.Client{
		Transport: transport,
		// Do not follow redirects locally: hand the redirect response back to
		// the phone so it re-issues the request through the tunnel (also
		// avoids resending bodies that have no GetBody).
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	return &relay{
		cloudURL:     cloudURL,
		token:        token,
		localURL:     localURL,
		client:       client,
		pingInterval: pingInterval,
		upgs:         make(map[int64]*upg),
	}
}

// run keeps the tunnel alive forever, reconnecting with exponential backoff.
// It returns only when ctx is canceled.
func (r *relay) run(ctx context.Context) error {
	backoff := initialBackoff
	for {
		err := r.runSession(ctx)
		if ctx.Err() != nil {
			return ctx.Err()
		}
		log.Printf("tunnel lost (%v); reconnecting in %s", err, backoff)
		select {
		case <-time.After(backoff):
		case <-ctx.Done():
			return ctx.Err()
		}
		backoff *= 2
		if backoff > maxBackoff {
			backoff = maxBackoff
		}
	}
}

// runSession establishes one tunnel connection, completes the hello handshake,
// and processes requests until the connection fails.
func (r *relay) runSession(ctx context.Context) error {
	log.Printf("connecting to cloud relay %s", r.cloudURL)
	conn, _, err := websocket.DefaultDialer.DialContext(ctx, r.cloudURL, nil)
	if err != nil {
		return fmt.Errorf("dial: %w", err)
	}
	defer conn.Close()

	if err := r.write(conn, wire{Type: "hello", Token: r.token}); err != nil {
		return fmt.Errorf("send hello: %w", err)
	}
	if err := conn.SetReadDeadline(time.Now().Add(helloTimeout)); err != nil {
		return fmt.Errorf("set read deadline: %w", err)
	}
	_, payload, err := conn.ReadMessage()
	if err != nil {
		return fmt.Errorf("waiting for ok: %w", err)
	}
	var msg wire
	if err := json.Unmarshal(payload, &msg); err != nil || msg.Type != "ok" {
		return fmt.Errorf("unexpected hello reply: %s", payload)
	}
	// Heartbeat: send WS pings and require the peer (or the TLS terminator /
	// load balancer in front of it) to answer with pongs, so NAT and reverse
	// proxy idle timeouts cannot silently kill the tunnel and a dead tunnel is
	// detected within pongWait instead of hanging forever. On timeout the read
	// below fails and run() reconnects with exponential backoff.
	pongWait := time.Duration(0)
	if r.pingInterval > 0 {
		pongWait = 3 * r.pingInterval
		if err := conn.SetReadDeadline(time.Now().Add(pongWait)); err != nil {
			return fmt.Errorf("set read deadline: %w", err)
		}
		conn.SetPongHandler(func(string) error {
			return conn.SetReadDeadline(time.Now().Add(pongWait))
		})
		pingStop := make(chan struct{})
		defer close(pingStop)
		go r.pingLoop(conn, pingStop)
	} else {
		_ = conn.SetReadDeadline(time.Time{}) // no heartbeat: no read deadline
	}
	log.Printf("tunnel established")

	// Cancel in-flight local requests when this connection goes away so their
	// goroutines cannot outlive the tunnel they would reply on.
	sessionCtx, cancel := context.WithCancel(ctx)
	defer cancel()

	for {
		_, payload, err := conn.ReadMessage()
		if err != nil {
			return fmt.Errorf("read: %w", err)
		}
		if pongWait > 0 {
			// Any traffic proves the tunnel is alive; keep the deadline fresh.
			if derr := conn.SetReadDeadline(time.Now().Add(pongWait)); derr != nil {
				return fmt.Errorf("set read deadline: %w", derr)
			}
		}
		var msg wire
		if err := json.Unmarshal(payload, &msg); err != nil {
			log.Printf("dropping unparseable message: %s", payload)
			continue
		}
		switch msg.Type {
		case "req":
			go r.handleRequest(sessionCtx, conn, msg)
		case "upgreq":
			go r.handleUpgreq(sessionCtx, conn, msg)
		case "upg-bin", "upg-end":
			r.routeUpg(msg)
		default:
			log.Printf("ignoring unknown message type %q", msg.Type)
		}
	}
}

// handleRequest executes one multiplexed request against the local service and
// streams the response back over the tunnel: head, then chunks, then end (or
// error if the local request fails).
func (r *relay) handleRequest(ctx context.Context, conn *websocket.Conn, msg wire) {
	defer func() {
		if p := recover(); p != nil {
			log.Printf("panic handling request %d: %v", msg.ID, p)
			_ = r.write(conn, wire{Type: "error", ID: msg.ID})
		}
	}()

	req, ok := r.parseRequest(msg)
	if !ok {
		_ = r.write(conn, wire{Type: "error", ID: msg.ID})
		return
	}
	req = req.WithContext(ctx)

	resp, err := r.client.Do(req)
	if err != nil {
		log.Printf("req %d: local request failed: %v", msg.ID, err)
		_ = r.write(conn, wire{Type: "error", ID: msg.ID})
		return
	}
	defer resp.Body.Close()

	total := r.streamLocalResponse(conn, msg.ID, resp)
	log.Printf("req %d: %s %s -> %d (%d bytes)", msg.ID, req.Method, req.URL.RequestURI(), resp.StatusCode, total)
}

// parseRequest decodes the dumped request of a "req" or "upgreq" message and
// points it at the local endpoint while keeping the original path and query.
// The request is rewritten so the local host sees a loopback-originated
// client: req.Host is set to the local endpoint's host (Go's client uses it
// for the Host header; ReadRequest removed it from req.Header) and the
// browser-only security headers (Origin, Sec-Fetch-*) are dropped — the same
// rewrite the upgrade path applies to WebSocket handshakes, applied to every
// tunneled request. The original body and the remaining headers are untouched.
func (r *relay) parseRequest(msg wire) (*http.Request, bool) {
	dump, err := base64.StdEncoding.DecodeString(msg.Request)
	if err != nil {
		log.Printf("req %d: bad base64 request: %v", msg.ID, err)
		return nil, false
	}
	req, err := http.ReadRequest(bufio.NewReader(bytes.NewReader(dump)))
	if err != nil {
		log.Printf("req %d: bad request dump: %v", msg.ID, err)
		return nil, false
	}
	req.URL.Scheme = r.localURL.Scheme
	req.URL.Host = r.localURL.Host
	req.RequestURI = ""        // client requests must not carry RequestURI
	req.Host = r.localURL.Host // the local service sees a loopback client
	stripBrowserHeaders(req.Header)
	return req, true
}

// stripBrowserHeaders removes the browser-only security headers from a dumped
// request so the local host treats the connection as loopback-originated. It
// is applied to every tunneled request; the upgrade path additionally strips
// the WebSocket handshake headers (see stripHandshakeHeaders).
func stripBrowserHeaders(h http.Header) {
	for k := range h {
		ck := http.CanonicalHeaderKey(k)
		switch ck {
		case "Origin":
			h.Del(k)
		default:
			if strings.HasPrefix(ck, "Sec-Fetch-") {
				h.Del(k)
			}
		}
	}
}

// handleUpgreq forwards a phone WebSocket handshake to the local host. It
// performs the upgrade handshake with the local host itself; on a 101 it
// acknowledges with upg-ok and then pumps frames in both directions, and on a
// plain HTTP response it falls back to the ordinary head/chunk/end path so
// the phone receives a normal HTTP error.
func (r *relay) handleUpgreq(ctx context.Context, conn *websocket.Conn, msg wire) {
	defer func() {
		if p := recover(); p != nil {
			log.Printf("panic handling upgreq %d: %v", msg.ID, p)
			_ = r.write(conn, wire{Type: "error", ID: msg.ID})
		}
	}()

	req, ok := r.parseRequest(msg)
	if !ok {
		_ = r.write(conn, wire{Type: "error", ID: msg.ID})
		return
	}
	// The dump is a browser WebSocket handshake: rewrite it so the local host
	// sees a loopback-originated client and its trust fence lets it through.
	// Host is set from the dial URL below (localURL.Host); the browser-only
	// security headers (Origin, Sec-Fetch-*) and the headers the dialer
	// manages itself (Upgrade, Connection, Sec-Websocket-Key/Version/
	// Extensions, including the phone's own key) are dropped.
	stripHandshakeHeaders(req.Header)
	wsURL := *r.localURL
	switch wsURL.Scheme {
	case "http":
		wsURL.Scheme = "ws"
	case "https":
		wsURL.Scheme = "wss"
	}
	wsURL.Path = req.URL.Path
	wsURL.RawQuery = req.URL.RawQuery

	dialer := &websocket.Dialer{
		HandshakeTimeout: responseHeaderTimeout,
		NetDialContext:   (&net.Dialer{Timeout: 10 * time.Second, KeepAlive: 30 * time.Second}).DialContext,
	}
	lconn, resp, err := dialer.DialContext(ctx, wsURL.String(), req.Header)
	if err == nil {
		// 101: acknowledge, then pump frames in both directions.
		u := &upg{
			id:   msg.ID,
			conn: lconn,
			in:   make(chan upgEvent, 1024),
			done: make(chan struct{}),
		}
		r.upgMu.Lock()
		r.upgs[msg.ID] = u
		r.upgMu.Unlock()
		if werr := r.write(conn, wire{Type: "upg-ok", ID: msg.ID}); werr != nil {
			r.finishUpg(u, conn, false)
			return
		}
		log.Printf("upgreq %d: %s %s upgraded", msg.ID, req.Method, req.URL.RequestURI())
		go r.pumpLocal(ctx, conn, u)
		go r.pumpTunnelToLocal(conn, u)
		return
	}
	// Not a 101: fall back to the plain response path so the phone's
	// WebSocket client receives a normal HTTP error.
	if resp != nil {
		log.Printf("upgreq %d: local host answered %d, falling back to plain HTTP", msg.ID, resp.StatusCode)
		r.streamLocalResponse(conn, msg.ID, resp)
		return
	}
	log.Printf("upgreq %d: local dial failed: %v", msg.ID, err)
	_ = r.write(conn, wire{Type: "error", ID: msg.ID})
}

// stripHandshakeHeaders removes the browser-only security headers and the
// WebSocket handshake headers from a dumped handshake so the local host treats
// the connection as loopback-originated. The phone's own Sec-WebSocket-Key is
// removed too: the dialer generates a fresh key for the handshake with the
// local host (the phone's handshake with the cloud is independent and
// self-consistent).
func stripHandshakeHeaders(h http.Header) {
	stripBrowserHeaders(h)
	for k := range h {
		ck := http.CanonicalHeaderKey(k)
		switch ck {
		case "Sec-Websocket-Key", "Sec-Websocket-Version",
			"Sec-Websocket-Extensions", "Upgrade", "Connection":
			h.Del(k)
		}
	}
}

// pingLoop sends a WebSocket ping control frame every pingInterval. The cloud
// relay (or the TLS terminator in front of it) answers with a pong that keeps
// the session's read deadline refreshed; the pong handler and the read-loop
// deadline refresh together keep the tunnel alive while it is otherwise quiet.
// The loop exits when the session ends or the write fails; the read loop then
// notices the dead connection and the reconnect loop takes over.
func (r *relay) pingLoop(conn *websocket.Conn, stop <-chan struct{}) {
	ticker := time.NewTicker(r.pingInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			// WriteControl is safe concurrently with the writeMu-serialized
			// protocol writes (gorilla permits one writer, and control frames
			// take their own lock).
			if err := conn.WriteControl(websocket.PingMessage, nil, time.Now().Add(10*time.Second)); err != nil {
				return
			}
		case <-stop:
			return
		}
	}
}

// pumpLocal reads data frames from the local host's upgraded socket and
// forwards the payloads to the tunnel as upg-bin messages. When the local
// host closes, it sends upg-end so the cloud closes the phone connection. It
// only reads the local socket; all writes come from pumpTunnelToLocal.
func (r *relay) pumpLocal(ctx context.Context, conn *websocket.Conn, u *upg) {
	// Close the local socket when the tunnel session dies so the read below
	// unblocks and the session can tear itself down.
	go func() {
		select {
		case <-ctx.Done():
		case <-u.done:
		}
		r.finishUpg(u, conn, false)
	}()
	for {
		mt, data, err := u.conn.ReadMessage()
		if err != nil {
			r.finishUpg(u, conn, true) // local host closed: tell the cloud
			return
		}
		if err := r.write(conn, wire{
			Type:   "upg-bin",
			ID:     u.id,
			Data:   base64.StdEncoding.EncodeToString(data),
			Binary: mt == websocket.BinaryMessage,
		}); err != nil {
			r.finishUpg(u, conn, true)
			return
		}
	}
}

// pumpTunnelToLocal drains upg-bin/upg-end events from the tunnel for this
// session and writes the payloads to the local socket. It is the local
// socket's single writer (gorilla/websocket permits one concurrent writer).
func (r *relay) pumpTunnelToLocal(conn *websocket.Conn, u *upg) {
	for {
		select {
		case ev := <-u.in:
			if ev.end {
				r.finishUpg(u, conn, false) // the cloud signalled the end
				return
			}
			mt := websocket.TextMessage
			if ev.binary {
				mt = websocket.BinaryMessage
			}
			if err := u.conn.WriteMessage(mt, ev.bin); err != nil {
				r.finishUpg(u, conn, true)
				return
			}
		case <-u.done:
			return
		}
	}
}

// routeUpg handles upg-bin/upg-end messages from the tunnel for an active
// passthrough session. It runs on the tunnel reader and only enqueues: the
// local socket's single writer is pumpTunnelToLocal.
func (r *relay) routeUpg(msg wire) {
	r.upgMu.Lock()
	u := r.upgs[msg.ID]
	r.upgMu.Unlock()
	if u == nil {
		return
	}
	switch msg.Type {
	case "upg-bin":
		data, err := base64.StdEncoding.DecodeString(msg.Data)
		if err != nil {
			log.Printf("upg %d: bad upg-bin base64", msg.ID)
			return
		}
		select {
		case u.in <- upgEvent{bin: data, binary: msg.Binary}:
		default:
			log.Printf("upg %d: tunnel buffer full, dropping frame", msg.ID)
		}
	case "upg-end":
		select {
		case u.in <- upgEvent{end: true}:
		default:
		}
	}
}

// finishUpg tears down one passthrough session: it removes it from the
// registry, closes the local socket and, unless the cloud already signalled
// the end, sends upg-end so the cloud closes the phone connection.
func (r *relay) finishUpg(u *upg, conn *websocket.Conn, sendEnd bool) {
	u.once.Do(func() {
		close(u.done)
		r.upgMu.Lock()
		delete(r.upgs, u.id)
		r.upgMu.Unlock()
		_ = u.conn.Close()
		if sendEnd {
			_ = r.write(conn, wire{Type: "upg-end", ID: u.id})
		}
	})
}

// streamLocalResponse sends a plain HTTP response (already obtained from the
// local host, e.g. a 401/403 rejection of a WebSocket handshake) back over
// the tunnel using the ordinary head/chunk/end messages. It returns the
// number of body bytes relayed.
func (r *relay) streamLocalResponse(conn *websocket.Conn, id int64, resp *http.Response) int64 {
	defer resp.Body.Close()
	if err := r.write(conn, wire{Type: "head", ID: id, Status: resp.StatusCode, Header: resp.Header}); err != nil {
		return 0 // tunnel is gone; nothing left to do
	}
	buf := make([]byte, chunkSize)
	var total int64
	for {
		n, err := resp.Body.Read(buf)
		if n > 0 {
			total += int64(n)
			if werr := r.write(conn, wire{Type: "chunk", ID: id, Data: base64.StdEncoding.EncodeToString(buf[:n])}); werr != nil {
				return total
			}
		}
		if err == io.EOF {
			break
		}
		if err != nil {
			log.Printf("req %d: body read failed: %v", id, err)
			_ = r.write(conn, wire{Type: "error", ID: id})
			return total
		}
	}
	if err := r.write(conn, wire{Type: "end", ID: id}); err != nil {
		return total
	}
	return total
}

// write sends one protocol message. All tunnel writes go through writeMu
// because gorilla/websocket permits only a single concurrent writer.
func (r *relay) write(conn *websocket.Conn, msg wire) error {
	payload, err := json.Marshal(msg)
	if err != nil {
		return err
	}
	r.writeMu.Lock()
	defer r.writeMu.Unlock()
	return conn.WriteMessage(websocket.TextMessage, payload)
}
