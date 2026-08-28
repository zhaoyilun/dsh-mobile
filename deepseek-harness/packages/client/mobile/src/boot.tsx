/**
 * Mobile boot kernel for DSH 0.1.1+.
 *
 * Mirrors the official 0.1.1 web boot (`@deepseek-ai/dsh-client-web`):
 * the host pre-installs `window.__ModuleLoader__` and `__DSH_BOOT__`; this
 * kernel creates the client module system, runs every client entry, then
 * mounts the mobile root slot (our MobileFrame shadows the desktop layout).
 * The desktop-only ui-layout row is filtered out so the mobile frame can own
 * the top-level child seats; a minimal ctx.layout face is provided by
 * app-shell instead.
 */
import { Context } from '@deepseek-ai/cordis'
import Loader from '@deepseek-ai/cordis-plugin-loader'
import { createRoot, type Root } from 'react-dom/client'
import type { ClientModuleCreateOptions, DshWindow } from '@deepseek-ai/dsh-client-modules/client'
import { getStaticModules } from '@deepseek-ai/dsh-client-web'
import { STATE_LABELS } from '@deepseek-ai/dsh-client-web/src/loader-status.ts'
import * as MobileAppShell from './app-shell.ts'
import { MOBILE_SHELL_ID } from './app-shell.ts'
import './base.css'

/** Module transport hook replaced by jsdom tests. */
export type BootSeams = Pick<ClientModuleCreateOptions, 'loadBundle'>

/** Desktop layout row filtered out: the mobile frame replaces it as root. */
const SKIPPED_CLIENT_ROWS = new Set([
  '@deepseek-ai/dsh-client-ui-layout',
])

/** Boot timeout: a remote/slow relay should never leave a blank screen forever. */
const BOOT_TIMEOUT_MS = 30_000

/** Render the centered splash (also used before the timeout). */
function renderSplash(root: Root): void {
  root.render(
    <div className="dsh-mobile-screen dsh-mobile-splash" data-dsh-boot>
      <div className="dsh-mobile-splashLogo">DSH</div>
      <p className="dsh-mobile-splashTitle">Mobile</p>
      <div className="dsh-mobile-spinner" aria-label="加载中" />
    </div>,
  )
}

/** Render a recoverable error screen with a manual reload action. */
function renderBootError(root: Root, message: string): void {
  root.render(
    <div className="dsh-mobile-screen dsh-mobile-error">
      <div className="dsh-mobile-splashLogo">DSH</div>
      <p className="dsh-mobile-errorTitle">移动端加载失败</p>
      <pre className="dsh-mobile-errorMessage">{message}</pre>
      <button
        type="button"
        className="dsh-mobile-retry"
        onClick={() => { globalThis.location.reload() }}
      >
        重新加载
      </button>
    </div>,
  )
}

/** Mobile shell kernel: see module doc. */
export class AppMobileEntry {
  private readonly seams: BootSeams | undefined
  private modules!: ReturnType<NonNullable<DshWindow['__ModuleLoader__']>['create']>
  private root: Root
  private bootSettled = false
  private bootTimer: number | undefined

  constructor(el: HTMLElement, seams?: BootSeams) {
    this.seams = seams
    this.root = createRoot(el)
    renderSplash(this.root)
  }

  /** Run the two-stage boot and mount the mobile root slot. */
  async run(): Promise<void> {
    try {
      const win = globalThis as DshWindow
      const moduleLoader = win.__ModuleLoader__
      if (moduleLoader === undefined) {
        throw new Error('mobile boot: window.__ModuleLoader__ bootstrap facade is missing')
      }
      // Inject the mobile app-shell as an extra graph entry. It is provided
      // through the static module seed (not a fetched bundle), so url/rev are
      // placeholders and resolution never reaches them.
      const wire = win.__DSH_BOOT__ as { entries?: unknown[] } | undefined
      if (wire == null || !Array.isArray(wire.entries)) {
        throw new Error('mobile boot: window.__DSH_BOOT__ is missing or malformed')
      }
      const originalEntries = wire.entries
      wire.entries = [
        ...originalEntries,
        {
          id: MOBILE_SHELL_ID,
          url: '',
          rev: '0',
          inject: ['slots', 'sessions', 'workspaces', 'locale', 'remote'],
          external: [],
        },
      ]

      const transport = (globalThis as {
        __DSH_TRANSPORT__?: { loadBundle?: ClientModuleCreateOptions['loadBundle'] }
      }).__DSH_TRANSPORT__
      this.modules = moduleLoader.create({
        boot: win.__DSH_BOOT__,
        staticModules: {
          ...getStaticModules(),
          [MOBILE_SHELL_ID]: MobileAppShell,
        },
        ...transport?.loadBundle === undefined ? {} : { loadBundle: transport.loadBundle },
        ...this.seams,
      })

      // Fail-loud timeout: if a relay/network stall leaves plugin boot
      // pending, show a recoverable error instead of an endless white screen.
      this.bootTimer = globalThis.setTimeout(() => {
        if (!this.bootSettled) {
          renderBootError(this.root, '启动超时（30 秒），请检查网络后重新加载。')
        }
      }, BOOT_TIMEOUT_MS)

      const prefetching = this.prefetchImmediateTier()
      const ctx = new Context()
      await this.runPluginBoot(ctx, prefetching)
      clearTimeout(this.bootTimer)
      this.bootTimer = undefined
      await this.mountMobile(ctx)
      this.bootSettled = true
    } catch (reason) {
      console.error(reason)
      const message = reason instanceof Error ? reason.message : String(reason)
      if (this.bootTimer !== undefined) {
        clearTimeout(this.bootTimer)
        this.bootTimer = undefined
      }
      renderBootError(this.root, message)
    }
  }

  /** Dispose the mobile React root. */
  dispose(): void {
    if (this.bootTimer !== undefined) clearTimeout(this.bootTimer)
    this.root.unmount()
  }

  /** Mount the mobile application: the root slot renders MobileFrame. */
  private async mountMobile(ctx: Context): Promise<void> {
    this.root.render(ctx.slots.renderSlot('root', {}))
  }

  /** Prefetch stage-one bundles exactly like the upstream web boot. */
  private async prefetchImmediateTier(): Promise<void> {
    const transport = (globalThis as {
      __DSH_TRANSPORT__?: { loadBundle?: unknown }
    }).__DSH_TRANSPORT__
    if (transport?.loadBundle !== undefined) return
    await Promise.all(this.modules.manifest.plugins
      .filter(row => !SKIPPED_CLIENT_ROWS.has(row.id))
      .filter(row => row.immediately)
      .map(row => this.modules.prefetch(row.id).catch((_error: unknown) => {
        // Prefetch failures are retried by the loader import path.
      })))
  }

  /** Load all client entries (minus desktop ui-layout) and await quiescence. */
  private async runPluginBoot(ctx: Context, prefetching: Promise<void>): Promise<void> {
    await ctx.plugin(Loader)
    const loader = ctx.loader
    loader.internal = this.modules as never

    ctx.on('internal/status', () => {
      // The mobile loading page intentionally stays minimal; no per-entry status line.
    })

    const rows = this.modules.manifest.plugins
      .filter(row => !SKIPPED_CLIENT_ROWS.has(row.id))
      .map(row => row.id)
    await prefetching
    await Promise.all(rows.map(async (name) => {
      const id = await loader.create({ name })
      if (loader.resolve(id).fiber === undefined) {
        // Marked by the upstream assert below.
      }
    }))

    await loader.await()
    this.assertEntriesActive(ctx)
  }

  /** Same fail-loud activation audit as the upstream web boot. */
  private assertEntriesActive(ctx: Context): void {
    const failures: string[] = []
    for (const entry of ctx.loader.entries()) {
      const name = entry.options.name
      if (entry.fiber === undefined) {
        failures.push(`${name}: import failed (see console for the import error)`)
        continue
      }
      const state = STATE_LABELS[entry.fiber.state]
      if (state === 'active') continue
      if (state === 'pending') {
        const missing = Object.keys(entry.fiber.inject).filter(service => ctx.get(service) === undefined)
        failures.push(`${name}: pending (waiting for services: ${missing.join(', ') || 'unknown'})`)
      } else {
        failures.push(`${name}: ${state}`)
      }
    }
    if (failures.length > 0) {
      throw new Error(`mobile boot: ${failures.length} entries did not activate\n${failures.join('\n')}`)
    }
  }
}
