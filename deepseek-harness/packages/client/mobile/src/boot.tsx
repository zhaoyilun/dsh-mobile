/**
 * Mobile shell boot kernel — the face consumed by the apps/mobile entry,
 * mirroring the desktop kernel (`@deepseek-ai/dsh-client-web`'s boot.tsx) with
 * the mobile app-shell assembly substituted. The two-stage chain is identical
 * to the desktop shell's (module face → plugin face → settled), and it reuses
 * the desktop kernel's exported machinery verbatim — `parseBootManifest` /
 * `ClientModuleSystem` (modules), `getStaticModules` (platform table), and
 * `AppRoot` / `createSignal` / `createLoaderStatusStore` / `STATE_LABELS`
 * (loading gate). The one divergence is the shell-own assembly entry: the
 * mobile assembly (`{@link MOBILE_SHELL_ID}`) installs a renderer configured
 * to dispatch the mobile 'mobile-frame' slot instead of 'root', so the desktop
 * frame registered into 'root' stays inert — one client composition, two
 * shells.
 *
 * Shell self-sufficiency rule (inherited from the desktop kernel): nothing
 * here value-imports a plugin package — the loading page must work while
 * (especially when) plugins fail. The one sanctioned exception is the modules
 * package (bootstrap identity), exactly as in the desktop kernel.
 */
import { Context } from '@deepseek-ai/cordis'
import Loader from '@deepseek-ai/cordis-plugin-loader'
import { createRoot, type Root } from 'react-dom/client'
import * as ModulesClient from '@deepseek-ai/dsh-client-modules/client'
import {
  ClientModuleSystem, parseBootManifest,
  type BootManifest, type ClientModuleSystemOptions, type DshWindow,
} from '@deepseek-ai/dsh-client-modules/client'
import {
  AppRoot, getStaticModules, STATE_LABELS, createLoaderStatusStore, createSignal,
} from '@deepseek-ai/dsh-client-web'
import * as MobileAppShell from './app-shell.ts'
import { MOBILE_SHELL_ID } from './app-shell.ts'
import './base.css'

/** Module transport hook the shell passes through (jsdom tests replace the <script> path). */
export type BootSeams = Pick<ClientModuleSystemOptions, 'loadBundle'>

/**
 * The modules package's own graph row id — same adoption handoff as the
 * desktop kernel: the wrapper is statically registered and must be skipped by
 * the plugin-row loop (the vendored Group.create does not deduplicate by
 * name, and a second fiber would provide 'modules' twice).
 */
const MODULES_ID = '@deepseek-ai/dsh-client-modules'

/**
 * The mobile shell kernel: mounts the loading page into a DOM element and runs
 * the two-stage boot over the host graph. Structurally identical to the
 * desktop AppWebEntry; the mobile assembly id is the only kernel difference.
 */
export class AppMobileEntry {
  private readonly el: HTMLElement
  private readonly seams: BootSeams | undefined
  private readonly status = createLoaderStatusStore()
  private readonly settled = createSignal(false)
  private readonly error = createSignal<string | undefined>(undefined)
  // Assigned by run() before any private method or settled-gated closure reads them.
  private ctx!: Context
  private modules!: ClientModuleSystem
  private manifest!: BootManifest
  private root: Root | undefined

  /**
   * Hold the mount point; all work happens in {@link run}.
   * @param el - mount point (the app's #root).
   * @param seams - Optional module transport overrides for test environments.
   */
  constructor(el: HTMLElement, seams?: BootSeams) {
    this.el = el
    this.seams = seams
  }

  /**
   * Run the boot chain to settlement. Boot-chain failures resolve (not
   * reject): the loading page stays up and renders the failure report (the
   * fail-loud surface the kernel owns). Rejects only when the boot manifest
   * is missing or malformed — there is nothing to boot against.
   * @returns resolves once the UI settled or the failure report rendered.
   */
  async run(): Promise<void> {
    this.manifest = parseBootManifest((globalThis as DshWindow).__DSH_BOOT__)

    this.modules = new ClientModuleSystem({
      modules: this.manifest.modules, staticModules: getStaticModules(), ...this.seams,
    })
    // The mobile app-shell assembly is the only shell-own module: every other
    // graph row is a plugin bundle arriving through fetch.
    this.modules.registerStatic(MOBILE_SHELL_ID, MobileAppShell)
    this.modules.registerStatic(MODULES_ID, ModulesClient)
    ;(globalThis as DshWindow).__DSH_MODULES__ = this.modules

    this.root = createRoot(this.el)
    this.root.render(
      <AppRoot
        settled={this.settled}
        status={this.status}
        error={this.error}
        renderApp={() => {
          const shell = this.ctx.get('appShell')
          // Unreachable after a clean settle (the app-shell entry is in every graph).
          if (shell === undefined) throw new Error('mobile boot: appShell service missing after settled')
          return shell.renderApp()
        }}
      />,
    )

    // The immediately tier prefetches in parallel with Loader mounting (same
    // cross-package require-edge rationale as the desktop kernel).
    const prefetching = this.prefetchImmediateTier()
    this.ctx = new Context()
    try {
      await this.runPluginBoot(prefetching)
      this.settled.set(true)
    } catch (reason) {
      // Stay on the loading page; surface the sweep report (fail loud).
      console.error(reason)
      this.error.set(reason instanceof Error ? reason.message : String(reason))
    }
  }

  /** Unmount the shell (loading page or settled UI). */
  dispose(): void {
    this.root?.unmount()
  }

  /** Prefetch the immediately tier (factory registration only; failures defer to the import path). */
  private async prefetchImmediateTier(): Promise<void> {
    await Promise.all(this.manifest.plugins
      .filter(row => row.immediately)
      .map(row => this.modules.prefetch(row.id).catch(() => {
        // Import reloads and reports this loudly per entry; swallowing
        // here keeps one failing prefetch from masking the others.
      })))
  }

  /** Plugin face: mount the Loader, inject the `internal` contract, adopt modules, create the graph entries, settle, sweep. */
  private async runPluginBoot(prefetching: Promise<void>): Promise<void> {
    const ctx = this.ctx
    await ctx.plugin(Loader)
    const loader = ctx.loader
    loader.internal = this.modules as never

    ctx.on('internal/status', (fiber) => {
      const entry = fiber.entry
      if (entry === undefined || entry.fiber === undefined) return
      this.status.set(entry.options.name, STATE_LABELS[entry.fiber.state])
    })

    // Barrier before any entry exists (same immediate-tier factory rationale
    // as the desktop kernel).
    await prefetching

    const rows = [MODULES_ID, ...this.manifest.plugins.map(row => row.id).filter(id => id !== MODULES_ID), MOBILE_SHELL_ID]
    await Promise.all(rows.map(async (name) => {
      this.status.set(name, 'loading')
      const id = await loader.create({ name })
      if (loader.resolve(id).fiber === undefined) {
        this.status.set(name, 'failed')
      }
    }))

    await loader.await()
    this.assertEntriesActive()
  }

  /**
   * Sweep every loader entry after the tree quiesced: an entry without a
   * fiber failed its import; a fiber not ACTIVE is FAILED (apply threw) or
   * PENDING (a required service never arrived — cordis inject waiting has no
   * timeout, so this sweep is the fail-loud compensation).
   */
  private assertEntriesActive(): void {
    const ctx = this.ctx
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
        failures.push(`${name}: pending (waiting for service${missing.length === 1 ? '' : 's'}: ${missing.join(', ') || 'unknown'})`)
      } else {
        failures.push(`${name}: ${state}`)
      }
    }
    if (failures.length > 0) {
      throw new Error(`mobile boot: ${String(failures.length)} entr${failures.length === 1 ? 'y' : 'ies'} did not activate\n${failures.join('\n')}`)
    }
  }
}
