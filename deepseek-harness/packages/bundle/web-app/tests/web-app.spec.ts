/**
 * Web runtime glue behavior: dist resolution through the bundle's own hook,
 * the frontend-static child claiming the fallback seat, the web-surface
 * prompt section and bash runtime variables, and URL-line printing with the
 * runtime's bind-dependent LAN snapshot.
 */

import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { Context } from '@deepseek-ai/cordis'
import SystemPrompt from '@deepseek-ai/dsh-system-prompt'
import HttpServer from '@deepseek-ai/dsh-host-webserver'
import type { WebServer } from '@deepseek-ai/dsh-host-webserver'
import { apply, Config, internals } from '../src/index.ts'

vi.mock('node:os', async importOriginal => ({
  ...await importOriginal<typeof import('node:os')>(),
  networkInterfaces: () => ({
    lo0: [{ family: 'IPv4', internal: true, address: '127.0.0.1' }],
    en0: [{ family: 'IPv4', internal: false, address: '192.168.1.5' }],
  }),
}))

let dist: string | undefined

afterEach(() => {
  vi.restoreAllMocks()
  internals.resolveDistIndex = originalResolve
  internals.resolveMobileDistIndex = originalResolveMobile
  if (dist !== undefined) rmSync(dist, { recursive: true, force: true })
  dist = undefined
})

const originalResolve = internals.resolveDistIndex
const originalResolveMobile = internals.resolveMobileDistIndex

/** Stage a dist fixture and point the bundle's resolver at it. */
function stageDist(): string {
  dist = mkdtempSync(join(tmpdir(), 'dsh-web-app-'))
  mkdirSync(join(dist, 'dist'))
  const index = join(dist, 'dist', 'index.html')
  writeFileSync(index, '<head></head><body>shell</body>')
  internals.resolveDistIndex = () => index
  // Every apply() also mounts the mobile row; existing suites keep the mobile
  // resolver stubbed to the same fixture so the extra row is inert.
  internals.resolveMobileDistIndex = () => index
  return index
}

/** Stage a second dist fixture and point the bundle's mobile resolver at it. */
function stageMobileDist(): { root: string; index: string } {
  const root = mkdtempSync(join(tmpdir(), 'dsh-web-app-mobile-'))
  mkdirSync(join(root, 'dist'))
  mkdirSync(join(root, 'dist', 'assets'))
  const index = join(root, 'dist', 'index.html')
  writeFileSync(index, '<head></head><body>mobile-shell</body>')
  writeFileSync(join(root, 'dist', 'assets', 'x.js'), 'export {}')
  internals.resolveMobileDistIndex = () => index
  return { root, index }
}

/** A fake webServer capturing the fallback seat, index taps, guard, and routes. */
function fakeHttpServer(host: '127.0.0.1' | '0.0.0.0' = '127.0.0.1'): {
  server: WebServer
  seat: () => unknown
  guards: unknown[]
  routes: unknown[]
} {
  let fallback: unknown
  const guards: unknown[] = []
  const routes: unknown[] = []
  const server = {
    host,
    port: 4567,
    registerFallback: (handler: unknown) => {
      fallback = handler
      return () => { fallback = undefined }
    },
    applyIndexTaps: (html: string) => html,
    setRequestGuard: (check: unknown) => {
      guards.push(check)
      return () => {}
    },
    register: (route: unknown) => {
      routes.push(route)
      return () => {}
    },
  } as unknown as WebServer
  return { server, seat: () => fallback, guards, routes }
}

/** A fake Loader whose settlement the test controls (the URL line waits on it). */
function provideLoader(ctx: Context, settle: () => Promise<void> = async () => {}): void {
  ctx.provide('loader', { await: settle } as never)
}

interface BashContribution {
  name: string
  variables: Record<string, { description: string }>
  resolve: () => Record<string, string>
}

describe('web-app runtime glue', () => {
  it('mounts dist serving, prompt section, bash variables, and prints the URL with the LAN snapshot', async () => {
    stageDist()
    const ctx = new Context()
    const { server, seat } = fakeHttpServer('0.0.0.0')
    ctx.provide('webServer', server)
    const contributions: BashContribution[] = []
    ctx.provide('shellEnv', {
      register: (contribution: BashContribution) => {
        contributions.push(contribution)
        return () => {}
      },
    } as never)
    provideLoader(ctx)
    const log = vi.spyOn(console, 'log').mockImplementation(() => {})
    apply(ctx, new Config({ printUrl: true, surfaceContext: true, trustedHosts: ['lab.internal'] }))
    await ctx.plugin(SystemPrompt, { persona: '' })
    // Settle the injected registrations.
    await new Promise(resolve => setTimeout(resolve, 0))

    expect(seat()).toBeDefined() // frontend-static claimed the fallback
    expect(ctx.get('webRuntime')).toEqual({
      lanAddresses: ['192.168.1.5'],
      trustedHosts: ['192.168.1.5', 'lab.internal'],
    })
    expect(log).toHaveBeenCalledWith('dsh web: http://127.0.0.1:4567 (LAN: http://192.168.1.5:4567)')
    const assembly = await ctx.systemPrompt.assemble()
    expect(assembly.sections.find(entry => entry.name === 'harness:source')?.text).toContain('DeepSeek Harness implementation checkout')
    const section = assembly.sections.find(entry => entry.name === 'app:web-surface')
    expect(section?.text).toContain('http://127.0.0.1:4567')
    // The single update contract: the receiver is always on; no-refresh
    // reloads additionally need the rebuild watcher.
    expect(section?.text).toContain('pnpm run dev:web')
    const webRuntime = contributions.find(contribution => contribution.name === 'web-runtime')
    expect(webRuntime?.resolve()).toEqual({ DSH_WEB_URL: 'http://127.0.0.1:4567' })
    await ctx.fiber.dispose()
  })

  it('stays quiet with printUrl off', async () => {
    stageDist()
    const ctx = new Context()
    ctx.provide('webServer', fakeHttpServer().server)
    const log = vi.spyOn(console, 'log').mockImplementation(() => {})
    apply(ctx, new Config({ printUrl: false, surfaceContext: true, trustedHosts: [] }))
    await ctx.plugin(SystemPrompt, { persona: '' })
    await new Promise(resolve => setTimeout(resolve, 0))
    expect(log).not.toHaveBeenCalled()
    const assembly = await ctx.systemPrompt.assemble()
    expect(assembly.sections.find(entry => entry.name === 'app:web-surface')?.text)
      .toContain('rebuilding the affected Web artifacts')
    await ctx.fiber.dispose()
  })

  it('skips the surface context when disabled (the one-shot layer): no prompt section, no bash variables', async () => {
    stageDist()
    const ctx = new Context()
    ctx.provide('webServer', fakeHttpServer().server)
    const contributions: BashContribution[] = []
    ctx.provide('shellEnv', {
      register: (contribution: BashContribution) => {
        contributions.push(contribution)
        return () => {}
      },
    } as never)
    apply(ctx, new Config({ printUrl: false, surfaceContext: false, trustedHosts: [] }))
    await ctx.plugin(SystemPrompt, { persona: '' })
    await new Promise(resolve => setTimeout(resolve, 0))
    const assembly = await ctx.systemPrompt.assemble()
    expect(assembly.sections.some(entry => entry.name === 'app:web-surface')).toBe(false)
    expect(assembly.sections.some(entry => entry.name === 'harness:source')).toBe(false)
    expect(contributions).toEqual([])
    await ctx.fiber.dispose()
  })

  it('prints the loopback-only URL line when no LAN snapshot exists', async () => {
    stageDist()
    const ctx = new Context()
    ctx.provide('webServer', fakeHttpServer().server)
    const log = vi.spyOn(console, 'log').mockImplementation(() => {})
    apply(ctx, new Config({ printUrl: true, surfaceContext: true, trustedHosts: [] }))
    await new Promise(resolve => setTimeout(resolve, 0))
    expect(log).toHaveBeenCalledWith('dsh web: http://127.0.0.1:4567')
    await ctx.fiber.dispose()
  })

  it('prints the pairing line and QR after the URL line on an all-interfaces bind, keeping the token out of the prompt and DSH_WEB_URL', async () => {
    stageDist()
    const ctx = new Context()
    const { server, guards, routes } = fakeHttpServer('0.0.0.0')
    ctx.provide('webServer', server)
    const contributions: BashContribution[] = []
    ctx.provide('shellEnv', {
      register: (contribution: BashContribution) => {
        contributions.push(contribution)
        return () => {}
      },
    } as never)
    const log = vi.spyOn(console, 'log').mockImplementation(() => {})
    const token = 'pair-secret-9f2c'
    apply(ctx, new Config({ printUrl: true, surfaceContext: true, trustedHosts: [], webToken: token }))
    await ctx.plugin(SystemPrompt, { persona: '' })
    await new Promise(resolve => setTimeout(resolve, 0))

    // The token config installs the guard and the /pair route; the mobile
    // shell mounts its /m prefix route alongside.
    expect(guards).toHaveLength(1)
    expect(routes).toMatchObject([
      { kind: 'exact', path: '/pair' },
      { kind: 'exact', path: '/ws-ticket' },
      { kind: 'prefix', path: '/m' },
    ])

    const pairingUrl = `http://192.168.1.5:4567/pair?token=${token}`
    expect(log.mock.calls.map(call => String(call[0]))).toEqual([
      'dsh web: http://127.0.0.1:4567 (LAN: http://192.168.1.5:4567)',
      `dsh web: phone pairing: ${pairingUrl}`,
      expect.stringContaining('▀') as unknown as string,
    ])
    const qr = log.mock.calls[2]![0] as string
    // One output line per two module rows of a 37-wide symbol (29 modules + quiet zone).
    expect(qr.split('\n')).toHaveLength(19)
    expect(qr.split('\n')[0]).toHaveLength(37)

    // The token stays out of the model-visible surface and the bash variable.
    const assembly = await ctx.systemPrompt.assemble()
    for (const entry of assembly.sections) expect(entry.text).not.toContain(token)
    const webRuntime = contributions.find(contribution => contribution.name === 'web-runtime')
    expect(webRuntime?.resolve().DSH_WEB_URL).not.toContain(token)
    await ctx.fiber.dispose()
  })

  it('defers the URL line until Loader settlement and drops it on failure or teardown', async () => {
    stageDist()
    // Settlement path: the line waits for loader.await() so supervisors can
    // RPC immediately after observing it.
    const settled = new Context()
    settled.provide('webServer', fakeHttpServer().server)
    let release: () => void
    const settlement = new Promise<void>((resolve) => { release = resolve })
    provideLoader(settled, () => settlement)
    const log = vi.spyOn(console, 'log').mockImplementation(() => {})
    apply(settled, new Config({ printUrl: true, surfaceContext: true, trustedHosts: [] }))
    await new Promise(resolve => setTimeout(resolve, 0))
    expect(log).not.toHaveBeenCalled()
    release!()
    await new Promise(resolve => setTimeout(resolve, 0))
    expect(log).toHaveBeenCalledWith('dsh web: http://127.0.0.1:4567')
    await settled.fiber.dispose()

    // Failed path: Loader reports the sibling failure; the app prints no URL
    // for a process that is about to exit.
    log.mockClear()
    const failed = new Context()
    failed.provide('webServer', fakeHttpServer().server)
    provideLoader(failed, async () => { throw new Error('boot failed') })
    apply(failed, new Config({ printUrl: true, surfaceContext: true, trustedHosts: [] }))
    await new Promise(resolve => setTimeout(resolve, 0))
    expect(log).not.toHaveBeenCalled()
    await failed.fiber.dispose()

    // Torn-down path: settlement resolves after the webserver is gone — no
    // line, no crash.
    log.mockClear()
    const torn = new Context()
    const child = torn.plugin((childCtx: Context) => {
      childCtx.provide('webServer', fakeHttpServer().server)
    })
    await child
    let releaseTorn: () => void
    const tornSettlement = new Promise<void>((resolve) => { releaseTorn = resolve })
    provideLoader(torn, () => tornSettlement)
    apply(torn, new Config({ printUrl: true, surfaceContext: true, trustedHosts: [] }))
    await child.dispose() // the webServer service goes away
    releaseTorn!()
    await new Promise(resolve => setTimeout(resolve, 0))
    expect(log).not.toHaveBeenCalled()
    await torn.fiber.dispose()
  })

  it('fails loud when the prompt section resolves against a portless webserver', async () => {
    stageDist()
    const ctx = new Context()
    // A webserver whose bound port is gone (torn down mid-request): the
    // section must throw, never render a URL with an undefined port.
    const { server } = fakeHttpServer()
    Object.defineProperty(server, 'port', { get: () => undefined })
    ctx.provide('webServer', server)
    apply(ctx, new Config({ printUrl: false, surfaceContext: true, trustedHosts: [] }))
    await ctx.plugin(SystemPrompt, { persona: '' })
    await new Promise(resolve => setTimeout(resolve, 0))
    await expect(ctx.systemPrompt.assemble()).rejects.toThrow('webServer service missing')
    await ctx.fiber.dispose()
  })

  it('resolves the real built frontend dist through the package exports, failing loud unbuilt', () => {
    // The production resolver (not the test hook). A built checkout resolves
    // the frontend package's index.html; a dist-less one (the CI coverage
    // lane runs before any build) must fail with the build hint, never a
    // silent fallback.
    try {
      expect(originalResolve()).toMatch(/dist[/\\]index\.html$/)
    } catch (error) {
      expect((error as Error).message).toContain('frontend dist not built')
    }
  })

  it('mounts the mobile dist under /m with the same index taps and static semantics', { timeout: 30_000 }, async () => {
    stageDist()
    const mobile = stageMobileDist()
    const ctx = new Context()
    await ctx.plugin(HttpServer, { host: '127.0.0.1', port: 0 })
    apply(ctx, new Config({ printUrl: false, surfaceContext: true, trustedHosts: [] }))
    // The modules node half injects window.__DSH_BOOT__ through index taps;
    // the tap is global, so both shells' index responses must carry it.
    const untap = ctx.webServer.tapIndex(html => html.replace('<head>', '<head><script>window.__DSH_BOOT__={rev:"x"}</script>'))
    await new Promise(resolve => setTimeout(resolve, 0))
    const port = ctx.webServer.port

    // Desktop fallback untouched: index through the same taps, real assets.
    const desktop = await fetch(`http://127.0.0.1:${String(port)}/`)
    expect(desktop.status).toBe(200)
    const desktopBody = await desktop.text()
    expect(desktopBody).toContain('__DSH_BOOT__')
    expect(desktopBody).toContain('shell')

    // Mobile index under /m: injected with the same __DSH_BOOT__, its own body.
    const mobileIndex = await fetch(`http://127.0.0.1:${String(port)}/m/`)
    expect(mobileIndex.status).toBe(200)
    const mobileBody = await mobileIndex.text()
    expect(mobileBody).toContain('__DSH_BOOT__')
    expect(mobileBody).toContain('mobile-shell')

    // Mobile assets resolve under the /m prefix.
    const asset = await fetch(`http://127.0.0.1:${String(port)}/m/assets/x.js`)
    expect(asset.status).toBe(200)
    expect(await asset.text()).toBe('export {}')

    // SPA fallback under /m routes through index taps too.
    const spa = await fetch(`http://127.0.0.1:${String(port)}/m/no/such/route`)
    expect(spa.status).toBe(200)
    expect(await spa.text()).toContain('__DSH_BOOT__')

    untap()
    rmSync(mobile.root, { recursive: true, force: true })
    await ctx.fiber.dispose()
  })
})
