# Mobile access to the dsh Web GUI

The `dsh web` server optionally authenticates phone and other LAN clients with a shared web token (`--web-token <token>`, falling back to `DSH_WEB_TOKEN`). This document describes the pairing flow, the security properties, and the planned hardening. The feature ships disabled: without a token the server behaves exactly as before.

## When the guard applies

A configured token makes the webserver require a credential from every request whose `Host` is not a loopback authority (`localhost`, `[::1]`, or any `127/8` address) — HTTP and WebSocket upgrades, including static files. Loopback requests (the desktop browser on the same machine) pass without credentials. Three credentials are accepted: the `dsh_web_token` cookie, `Authorization: Bearer <token>`, and — for WebSocket handshakes only — the `?token=` query parameter. A rejected HTTP request answers a bare 401 with no detail; a rejected upgrade is dropped without a handshake. Token comparison is constant-time: both sides are sha256-digested and compared with `crypto.timingSafeEqual`, so response timing reveals nothing about a guess.

## Pairing flow

The pairing endpoint `GET /pair?token=<token>` is the one route the guard admits without a credential, because issuing the session cookie is its only job: it authenticates itself, even for loopback clients.

1. Start the server with a token on an all-interfaces bind: `dsh --profile web --host 0.0.0.0 --web-token <token>` (the all-interfaces host is rejected without a token).
2. The server prints, right after the `dsh web:` URL line, a pairing line `dsh web: phone pairing: http://<LAN-IP>:<port>/pair?token=<token>` followed by a scannable QR code rendered in terminal half-blocks.
3. Point the phone camera at the QR code (or type the pairing URL). The phone opens `/pair?token=<token>`.
4. With the correct token, the server answers `302` to `/` with `Set-Cookie: dsh_web_token=<token>; HttpOnly; SameSite=Lax; Path=/`. The token leaves the address bar; the cookie carries the session from then on.
5. With a wrong token, the server answers 401 after a fixed one-second delay. Repeated failures do not lock or crash the server.

The desktop browser is untouched by the flow: its loopback requests are exempt, so no pairing is needed on the host machine.

## Security notes

- **The token never enters logs, prompt sections, or `DSH_WEB_URL`.** It appears only in the printed pairing line and the QR code, which are the pairing mechanism by design. Anyone who sees that output can authenticate, so print it only where you trust the audience.
- **Loopback exemption is deliberate.** A local attacker who can already reach the host's loopback interface has more direct options; the desktop browser keeps working without a cookie or token.
- **Plain HTTP on the LAN is cleartext.** The pairing URL and the session cookie travel unencrypted, so on an untrusted network (shared Wi-Fi, a hostile switch) an eavesdropper can capture the token or replay the cookie. Pair only on a network you trust; prefer `Authorization: Bearer` for programmatic clients over raw HTTP.
- **The token is a static shared secret.** It has no expiry and no rotation: one leaked pairing line authenticates until the server restarts with a new token. Choose an alphanumeric token so the pairing URL and the cookie transport it verbatim (URL- or cookie-hostile characters are not validated).
- **The guard sits in front of every route.** It runs before route dispatch, so no static asset, API endpoint, or upgrade path leaks ahead of authentication.

## Limitations and planned hardening

- **One-time pairing tokens.** The token is a static shared secret valid for the whole process lifetime. A natural hardening is a pairing phase that issues the session cookie only after a short-lived, single-use token — the printed token would expire after one successful pair or a time window, so a photographed pairing line stops authenticating.
- **TLS.** Plain HTTP on the LAN carries the token and the cookie in cleartext. A TLS terminator (or built-in HTTPS) would make interception useless and is the largest single improvement for untrusted networks.
- **Rate limiting.** The fixed one-second delay on failed `/pair` attempts throttles online guessing per request, but there is no per-source accounting. A per-IP or per-token budget (exponential backoff, lockout after a threshold) belongs behind the pairing route.

## Combining with a public relay

*Placeholder: combining this LAN pairing with a public relay (for example a DSH relay that forwards traffic to a machine behind NAT) is not implemented yet. When it lands, this section will specify how the relay authenticates to the server (the relay would present the token or a relay-specific credential), how pairing through the relay differs from direct LAN pairing, and which trust boundary the relay itself occupies.*
