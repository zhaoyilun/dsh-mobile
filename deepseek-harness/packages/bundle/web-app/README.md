# `@deepseek-ai/dsh-web-app`

English | [中文](README.zh.md)

The dsh browser-surface bundle. [`cordis.patch.yml`](cordis.patch.yml) rides over [`dsh-base`](../base/README.md): it sets the coding persona, inserts the Web host rows (webserver, API gateway, workspace, projection cache, storage) and the browser plugin roster, the always-on client-plugin reload chain ([`dsh-client-hmr`](../../client/hmr/README.md), idle until a rebuild watcher rewrites client bundles), and mounts this package's `web-runtime` glue plugin (config `{printUrl, surfaceContext, trustedHosts, webToken}`). That plugin resolves the built frontend dists through the frontend packages' exports — `@deepseek-ai/dsh-web-frontend` on the webserver fallback seat and `@deepseek-ai/dsh-mobile-frontend` under the `/m` prefix, two [`frontend-static`](../../host/frontend-static/README.md) rows that receive the same index taps and therefore the same `window.__DSH_BOOT__` client composition — samples bind-dependent LAN trust once, provides it as `webRuntime` to the browser-trust fence and client roster, registers the harness-source and web-surface prompt sections plus the bash-visible `DSH_WEB_URL` runtime variable when `surfaceContext` is true, and prints the `dsh web:` URL line when `printUrl` is true, after its Loader tree settles so a sibling failure cannot announce a dead app. A non-empty `webToken` additionally installs the non-loopback request guard on the webserver and registers the `/pair` pairing endpoint. This bundle also owns the app command line: the ordinary `web-startup` provider ([`src/startup.ts`](src/startup.ts)) injects `ctx.cmdlineArgs` ([`dsh-cmdline`](../../boot/cmdline/README.md)), parses `--host`, `--port`, repeatable `--trusted-host`, `--web-token`, and the app's `--help`, then provides `webStartup`. It rejects `--host 0.0.0.0` before publishing that service unless a web token is configured, because binding all interfaces exposes the unauthenticated server to the network and the request guard installed from the token is the only authentication on that surface. Flag-configured rows inject the service and read it directly from lazy config, so nothing binds a port before argument resolution and `dsh --profile web --help` starts no server. [`dsh-headless`](../headless/README.md) is a sibling surface over the same base and does not mount this bundle.

## Web-token authentication and phone pairing

`dsh --profile web --web-token <token>` (or the `DSH_WEB_TOKEN` environment variable; the flag wins) turns on shared-secret authentication for every non-loopback request — HTTP and WebSocket upgrades, including static files — while loopback requests (the desktop browser) stay unauthenticated. Without a token the server behaves exactly as before: no guard, no `/pair` route, no pairing output. Credentials are accepted three ways: the `dsh_web_token` cookie (set by pairing), `Authorization: Bearer <token>`, and — for WebSocket handshakes only — the `?token=` query parameter. Failed requests answer a bare 401 with no detail; failed upgrades are dropped without a handshake. Token comparison is constant-time (sha256 digests compared with `crypto.timingSafeEqual`).

The pairing flow connects a phone on the LAN: run with a token on an all-interfaces bind, and the server prints `dsh web: phone pairing: http://<LAN-IP>:<port>/pair?token=<token>` plus a scannable terminal QR code right after the URL line. Scanning opens `/pair?token=...` on the phone, which — for the correct token — sets `dsh_web_token` (`HttpOnly`, `SameSite=Lax`, `Path=/`) and redirects to `/`, so the token leaves the address bar. Wrong tokens answer 401 after a fixed one-second delay. `/pair` authenticates itself: even loopback clients must present the correct token. See [docs/MOBILE-ACCESS.md](../../../docs/MOBILE-ACCESS.md) for the full flow, security notes, and planned improvements.

Security notes: the token is a shared secret for a LAN, not a credential store — anyone who sees the printed pairing line or QR can authenticate, so print it only where you trust the audience. The token never appears in logs, prompt sections, or `DSH_WEB_URL`; it appears only in the pairing line and QR code, which are the pairing mechanism by design. Over plain HTTP the token and the session cookie travel in cleartext on the LAN — pair only on a network you trust, and prefer `Authorization: Bearer` for programmatic clients. The token is not validated for URL/cookie safety: choose an alphanumeric token so the pairing URL and cookie transport it verbatim.

## Model Experience

### Harness-source and Web-surface context

#### What the model sees

When `surfaceContext` is true, the `harness:source` section identifies the on-disk Harness implementation without claiming it is the working directory, and the `app:web-surface` global section (order −98) orients the model to the GUI: the canonical local URL, the "this page" referent, the update contract (the reload receiver is always on; no-refresh reloads additionally need the `pnpm run dev:web` watcher), and the instruction not to start replacement servers. `DSH_WEB_URL` additionally appears in the managed bash environment with its description, resolved per invocation from the live server. When it is false, neither section nor the variable is registered.

#### Token effect

One source line and one prompt paragraph per session plus two managed-environment variable lines; constant per process.

#### KV Cache effect

The prompt section sits near the system prompt's head and is stable for the life of the process (the port is a boot fact), so it does not invalidate the cache across turns.

## Known Limitations and Deferred Work

- **The frontend dist must be built** — `require.resolve` of the dist fails loud at activation with a build hint; there is no source-serving fallback.
- **`lanAddresses` is a boot-time snapshot** — interface changes after boot are not re-advertised; the printed LAN URL always matches the configured trust fence.
- **Pairing is reachable only over an authenticated all-interfaces bind** — the CLI accepts `--host 0.0.0.0` only together with `--web-token`/`DSH_WEB_TOKEN`; the pairing QR prints for that bind, and every non-loopback request carries the guard.
- **The web token is a static shared secret** — no rotation, no expiry, no per-device tokens; one leaked pairing line authenticates until the server restarts with a new token. One-time pairing tokens and TLS are planned ([docs/MOBILE-ACCESS.md](../../../docs/MOBILE-ACCESS.md)).
- **Token characters are not validated** — choose an alphanumeric token; URL- or cookie-hostile characters would break the pairing URL or the session cookie.
