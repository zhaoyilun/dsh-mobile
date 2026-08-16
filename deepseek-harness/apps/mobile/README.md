# @deepseek-ai/dsh-mobile-frontend

Mobile-first application entry: `vite build` over the [`@deepseek-ai/dsh-client-mobile`](../../packages/client/mobile/README.md) shell library. The built `dist/` is served by `dsh web` under the `/m` prefix (the web-app bundle mounts a second frontend-static row with `path: '/m'`), so every asset URL in the dist is `/m/`-rooted and the index is injected with the SAME `window.__DSH_BOOT__` manifest as the desktop page — both shells share one client plugin composition.

The app bundles the mobile shell and the shared platform words directly through Vite (same alias discipline as [`apps/web`](../web/README.md)); the `base: '/m/'` config keeps every built asset under the mount prefix. `index.html` carries the PWA manifest ("DSH Mobile", `display: standalone`, 192/512 placeholder icons), an apple-touch-icon link, and a mobile viewport. The build refuses bare `vite dev`/`vite preview` serving (a boot-manifest-free shell must not be exposed).

## No service worker (by design)

Browsers register service workers only in secure contexts, and the LAN HTTP deployment (`http://<host>:<port>/m`) is not one — so the app deliberately ships NO service worker. The web manifest and apple-touch-icon still let iOS "Add to Home Screen" present the shell as a standalone app; offline caching is deferred to the TLS follow-up (self-signed or reverse-proxy HTTPS makes a service worker possible).

## Known Limitations and Deferred Work

- **No offline cache** — see above; the manifest is present but a service worker is not.
- **Icons are placeholder solids** — the 192/512 manifest icons and the apple-touch-icon are generated solid-color placeholders, not brand art.
- **Touch/gesture polish is minimal** — the conversation detail has a back bar but no swipe-back gesture yet; bottom-nav and row hit targets are sized for fingers but not browser-tested at all device widths.
