# `@deepseek-ai/dsh-host-frontend-static`

English | [中文](README.zh.md)

SPA dist server for the Web shell: a function plugin (config `{distIndex, path?}`) that serves the built frontend directory with the shell's locked semantics — traversal outside the dist root is 403, any miss falls back to `index.html` with HTTP 200 (SPA routing), unknown extensions ship as `application/octet-stream`, and non-GET/HEAD without a matching named route is 405. Every index response runs through the webserver's registered index taps (`applyIndexTaps`), which is how the boot manifest reaches the page. `distIndex` is an assembly fact of the composing application: [`dsh-web-app`](../../bundle/web-app/README.md) resolves it through the frontend package's exports and mounts this plugin; a deployment never hardcodes it.

By default the plugin claims the [webserver](../webserver/README.md)'s single fallback seat. The optional `path` (an absolute prefix without a trailing slash, e.g. `/m`) instead registers a prefix route: the fallback seat stays free and only requests under `path` (and `path` itself) are served, with the prefix stripped before the static resolution — so two instances can serve two dists from one server (the desktop shell on the fallback seat, the mobile-first shell under `/m`), each with the same static semantics and the same index taps.

The fallback seat is single-owner (a second claim throws) and effect-scoped: disposing the plugin's fiber releases the seat (or removes the prefix route), after which the unclaimed webserver answers 404.

## Model Experience

None, as the package serves browser assets; nothing here reaches a model request.

#### KV Cache effect

None; this package neither assembles nor sends a provider request.

## Known Limitations and Deferred Work

- **The starter MIME table is minimal** — it covers the Vite-emitted asset set plus the shipped PWA manifest; other extensions fall back to `application/octet-stream` until an asset class actually ships.
