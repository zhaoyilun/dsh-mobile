/**
 * Mobile shell library entry. The shell's product is {@link AppMobileEntry} —
 * apps/mobile's vite entry runs it against #root; everything else (the
 * mobile app-shell assembly, the frame and its pages) is internal to the boot
 * chain. Re-exported kernel pieces let tests and the app entry stay on the
 * package face.
 * @module @deepseek-ai/dsh-client-mobile
 */

export { AppMobileEntry, type BootSeams } from './boot.tsx'
export { MOBILE_SHELL_ID, type AppShellService, type MobileFrameInjected } from './app-shell.ts'
export { buildMobileRenderApp, type AssemblyDeps } from './app.tsx'
export type { MobileFrameProps } from './frame/MobileFrame.tsx'
