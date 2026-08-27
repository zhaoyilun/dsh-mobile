/**
 * Mobile shell library entry. The shell's product is {@link AppMobileEntry}.
 */
export { AppMobileEntry, type BootSeams } from './boot.tsx'
export { MOBILE_SHELL_ID, type MobileFrameInjected } from './app-shell.ts'
export { buildMobileRenderApp, type AssemblyDeps } from './app.tsx'
export type { MobileFrameProps } from './frame/MobileFrame.tsx'
