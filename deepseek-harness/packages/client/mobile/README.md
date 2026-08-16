# @deepseek-ai/dsh-client-mobile

Mobile-first shell kernel: `new AppMobileEntry(el, seams?).run()` boots the SAME client composition the desktop shell boots — the identical two-stage chain (module face → plugin face → settle) reusing the desktop kernel's exported machinery (`AppRoot`, `getStaticModules`, loader-status signals) — then renders the mobile 'mobile-frame' slot instead of 'root'. The desktop frame (ui-layout's AppFrame) is registered into 'root' in the shared graph but never rendered, so the desktop three-column layout stays inert: one composition, two shells. The mobile app-shell assembly (`@deepseek-ai/dsh-client-mobile-app-shell`, a shell-owned pseudo entry) installs the renderer configured with `rootKey: 'mobile-frame'`, declares the mobile frame hole through the additive `shell.overlay` list slot, and registers the frame.

The frame ([`MobileFrame`](src/frame/MobileFrame.tsx)) composes the mobile layout over the sessions and workspaces services: the conversation home fills the viewport (the desktop 'conversation' column embedded whole, with a small floating drawer button instead of a duplicate header bar), the session list lives in a left drawer grouped by Workspace plus an "未分组" bucket — groups collapse from their header and show at most five rows before scrolling internally — and Settings is the single drawer footer entry; it shows connection/server/workspace/session identity and explains and opens the session-scoped plan/goal pages. Approval/question waits, completed sessions, and finished jobs surface as transient in-app notices (plus the system Notification API when permission is already granted). Drawer open/close and pushed pages are mirrored into browser history (`pushState`/`popstate`), and the drawer opens from the floating button or a rightward swipe starting in the middle 25%–75% band of the screen (the left/right edges are left to the OS gestures). On mobile the composer treats plain Enter as a newline and keeps Send as the primary button, with Stop exposed separately while a turn is running.

The web shell and this package share the platform-module table (`getStaticModules`), so the fetched plugin bundles resolve their externals identically in both shells.

## Model Experience

None, as the entry shell boots the browser plugin tree; nothing here reaches a model request.

#### KV Cache effect

None; this package neither assembles nor sends a provider request.

## Known Limitations and Deferred Work

- **No service worker / PWA installability on LAN HTTP** — the shell ships a web manifest and apple-touch-icon, but browsers refuse service workers outside a secure context, so the mobile app has no offline cache; iOS "Add to Home Screen" still works. See [`dsh-mobile-frontend`](../../../apps/mobile/README.md).
- **Desktop full settings stay out of the phone shell** — mobile settings show connection/identity and plan/goal entries; the desktop settings surface itself is not embedded. Server/pass editing belongs to the Flutter shell's own settings page.
- **New sessions are workspace-scoped** — mobile can reuse/create a workspace's blank session via the workspace header ✚; workspace registration/rename/delete remain desktop-side.
- **Plan/goal surfaces are conversation-integrated** — the plan page shows status + guidance (the plan chip is not exported for import), and goal creation stays on the desktop `/goal` command; the goal page reuses the desktop `GoalBar` for viewing and mutation.
- **Conversation narrow-screen adaptation is CSS-level** — the embedded desktop column is styled through this package's CSS overrides (content-width variables, safe-area insets); pixel-perfect phone rendering is not covered by an automated browser lane in this package.
