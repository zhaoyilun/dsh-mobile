/**
 * End-to-end web-token authentication over a real webserver: the bundle's
 * apply() installs the guard and the /pair route, and every assertion walks
 * the real HTTP surface — loopback exemption, cookie/Bearer credentials, WS
 * upgrade credentials (cookie and ?token=), and the pairing flow with its
 * cookie issuance and throttled failures.
 */

import { connect } from 'node:net'
import { request as httpRequest } from 'node:http'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { Context } from '@deepseek-ai/cordis'
import WebServer from '@deepseek-ai/dsh-host-webserver'
import { WEB_TOKEN_COOKIE } from '../src/pairing.ts'
import { apply, Config, internals } from '../src/index.ts'

const TOKEN = 'pair-secret-9f2c'

let dist: string | undefined

afterEach(() => {
  internals.resolveDistIndex = originalResolve
  if (dist !== undefined) rmSync(dist, { recursive: true, force: true })
  dist = undefined
})

const originalResolve = internals.resolveDistIndex

/** Stage a dist fixture and point the bundle's resolver at it (apply() resolves eagerly). */
function stageDist(): void {
  const dir = mkdtempSync(join(tmpdir(), 'dsh-web-token-'))
  dist = dir
  writeFileSync(join(dir, 'index.html'), '<head></head><body>shell</body>')
  internals.resolveDistIndex = () => join(dir, 'index.html')
}

/**
 * Boot the real webserver plus the bundle glue with the given token (empty
 * disables authentication) and register the probe route.
 * @param token - the configured web token, or '' for no token.
 * @returns the live context, port, and a dispose function.
 */
async function boot(token: string): Promise<{ ctx: Context; port: number; dispose: () => Promise<void> }> {
  stageDist()
  const ctx = new Context()
  await ctx.plugin(WebServer, { host: '127.0.0.1', port: 0 })
  apply(ctx, new Config({ printUrl: false, surfaceContext: false, trustedHosts: [], webToken: token }))
  await new Promise(resolve => setTimeout(resolve, 0)) // let the frontend-static child settle
  ctx.webServer.register({
    kind: 'exact',
    path: '/probe',
    handler: (_req, res) => { res.writeHead(200); res.end('PROBE') },
  })
  return {
    ctx,
    port: ctx.webServer.port,
    dispose: async () => { await ctx.fiber.dispose() },
  }
}

/** One HTTP GET against the server with an explicit Host header (default loopback). */
function httpGet(
  port: number,
  path: string,
  host = '127.0.0.1',
  extraHeaders: Record<string, string> = {},
): Promise<{ status: number; headers: Record<string, string | string[] | undefined>; body: string }> {
  return new Promise((resolve, reject) => {
    const req = httpRequest({
      port,
      path,
      headers: { host: `${host}:${String(port)}`, ...extraHeaders },
    }, (res) => {
      let body = ''
      res.setEncoding('utf8')
      res.on('data', (chunk) => { body += String(chunk) })
      res.on('end', () => { resolve({ status: res.statusCode ?? 0, headers: res.headers, body }) })
    })
    req.on('error', reject)
    req.end()
  })
}

/** One raw WS-upgrade attempt against a non-loopback Host; resolves on the 101 or the close. */
function upgradeAttempt(
  port: number,
  path: string,
  extraHeaders: string[] = [],
): Promise<{ ok: boolean }> {
  return new Promise((resolve) => {
    const socket = connect(port, '127.0.0.1')
    socket.on('error', () => { /* The server-side reset is the fixture outcome. */ })
    let data = ''
    let settled = false
    const finish = (): void => {
      if (settled) return
      settled = true
      socket.destroy()
      resolve({ ok: data.includes('101 Switching Protocols') })
    }
    socket.on('data', (chunk) => {
      data += String(chunk)
      if (data.includes('101 Switching Protocols')) finish()
    })
    socket.on('close', finish)
    socket.on('connect', () => {
      socket.write([
        `GET ${path} HTTP/1.1`,
        `Host: 192.168.1.5:${String(port)}`,
        'Connection: Upgrade',
        'Upgrade: dsh-test',
        ...extraHeaders,
        '',
        '',
      ].join('\r\n'))
    })
  })
}

/** The /pair success cookie, asserted on both attributes and value. */
function expectPairingCookie(response: { headers: Record<string, string | string[] | undefined> }): void {
  const setCookie = response.headers['set-cookie']
  expect(setCookie).toBeDefined()
  const value = Array.isArray(setCookie) ? setCookie.join(';') : setCookie
  expect(value).toContain(`${WEB_TOKEN_COOKIE}=${TOKEN}`)
  expect(value).toContain('HttpOnly')
  expect(value).toContain('SameSite=Lax')
  expect(value).toContain('Path=/')
}

describe('web-token authentication over a real webserver', () => {
  it('lets loopback requests through without credentials and 401s non-loopback ones', async () => {
    const { port, dispose } = await boot(TOKEN)
    try {
      expect(await httpGet(port, '/probe', '127.0.0.1')).toMatchObject({ status: 200, body: 'PROBE' })
      const denied = await httpGet(port, '/probe', '192.168.1.5')
      expect(denied.status).toBe(401)
      expect(denied.body).not.toContain('PROBE')
      // Cookie credential.
      expect((await httpGet(port, '/probe', '192.168.1.5', { cookie: `${WEB_TOKEN_COOKIE}=${TOKEN}` })).status).toBe(200)
      // Bearer credential.
      expect((await httpGet(port, '/probe', '192.168.1.5', { authorization: `Bearer ${TOKEN}` })).status).toBe(200)
      // A wrong credential stays denied.
      expect((await httpGet(port, '/probe', '192.168.1.5', { cookie: `${WEB_TOKEN_COOKIE}=wrong` })).status).toBe(401)
    } finally {
      await dispose()
    }
  })

  it('guards WS upgrades: no credential is destroyed, cookie and ?token= pass', async () => {
    const { ctx, port, dispose } = await boot(TOKEN)
    try {
      ctx.webServer.registerUpgrade({
        path: '/events',
        handler: (_req, socket) => {
          socket.write('HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: dsh-test\r\n\r\n')
        },
      })
      expect(await upgradeAttempt(port, '/events')).toMatchObject({ ok: false })
      expect(await upgradeAttempt(port, '/events', [`Cookie: ${WEB_TOKEN_COOKIE}=${TOKEN}`])).toMatchObject({ ok: true })
      expect(await upgradeAttempt(port, `/events?token=${encodeURIComponent(TOKEN)}`)).toMatchObject({ ok: true })
      expect(await upgradeAttempt(port, '/events?token=wrong')).toMatchObject({ ok: false })
    } finally {
      await dispose()
    }
  })

  it('mints one-time upgrade tickets over cookie-authenticated HTTP and redeems each exactly once', async () => {
    const { ctx, port, dispose } = await boot(TOKEN)
    try {
      ctx.webServer.registerUpgrade({
        path: '/events',
        handler: (_req, socket) => {
          socket.write('HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: dsh-test\r\n\r\n')
        },
      })
      // Minting requires the pairing credential: no cookie → 401.
      expect((await httpGet(port, '/ws-ticket', '192.168.1.5')).status).toBe(401)
      // A wrong ticket never redeems.
      expect(await upgradeAttempt(port, '/events?ticket=deadbeef')).toMatchObject({ ok: false })
      // Cookie-authenticated mint → single redemption on the handshake.
      const mint = await httpGet(port, '/ws-ticket', '192.168.1.5', { cookie: `${WEB_TOKEN_COOKIE}=${TOKEN}` })
      expect(mint.status).toBe(200)
      const ticket = (JSON.parse(mint.body) as { ticket?: string }).ticket
      expect(typeof ticket).toBe('string')
      expect(ticket).not.toContain(TOKEN)
      expect(await upgradeAttempt(port, `/events?ticket=${encodeURIComponent(ticket ?? '')}`)).toMatchObject({ ok: true })
      // Single use: the same ticket is dead on its second handshake.
      expect(await upgradeAttempt(port, `/events?ticket=${encodeURIComponent(ticket ?? '')}`)).toMatchObject({ ok: false })
      // A fresh mint works again (the mint route itself stays cookie-guarded).
      const again = await httpGet(port, '/ws-ticket', '192.168.1.5', { cookie: `${WEB_TOKEN_COOKIE}=${TOKEN}` })
      const second = (JSON.parse(again.body) as { ticket?: string }).ticket
      expect(second).not.toBe(ticket)
      expect(await upgradeAttempt(port, `/events?ticket=${encodeURIComponent(second ?? '')}`)).toMatchObject({ ok: true })
    } finally {
      await dispose()
    }
  })

  it('pairs: correct token issues the cookie and redirects, wrong tokens 401 after the fixed delay', async () => {
    const { port, dispose } = await boot(TOKEN)
    try {
      const ok = await httpGet(port, `/pair?token=${encodeURIComponent(TOKEN)}`, '192.168.1.5')
      expect(ok.status).toBe(302)
      expect(ok.headers.location).toBe('/')
      expectPairingCookie(ok)

      // The `next` target is honored only as a same-origin path: the mobile
      // shell hands `/m/`, and anything that could leave the origin falls back
      // to the root.
      const toMobile = await httpGet(port, `/pair?token=${encodeURIComponent(TOKEN)}&next=/m/`, '192.168.1.5')
      expect(toMobile.status).toBe(302)
      expect(toMobile.headers.location).toBe('/m/')
      for (const hostile of ['next=https://evil.example/', 'next=//evil.example/', 'next=%2F%2Fevil.example/', 'next=/x%5Cy', 'next=/x%0Ay']) {
        const guarded = await httpGet(port, `/pair?token=${encodeURIComponent(TOKEN)}&${hostile}`, '192.168.1.5')
        expect(guarded.headers.location).toBe('/')
      }

      const started = Date.now()
      const wrong = await httpGet(port, '/pair?token=wrong', '192.168.1.5')
      expect(wrong.status).toBe(401)
      expect(Date.now() - started).toBeGreaterThanOrEqual(900)

      // /pair authenticates itself: even loopback hosts must present the token.
      expect((await httpGet(port, '/pair')).status).toBe(401)

      // Three consecutive failures never crash or lock the server: the issued
      // cookie still authenticates the app afterwards.
      const failures = await Promise.all([
        httpGet(port, '/pair?token=a', '192.168.1.5'),
        httpGet(port, '/pair?token=b', '192.168.1.5'),
        httpGet(port, '/pair?token=c', '192.168.1.5'),
      ])
      expect(failures.map(failure => failure.status)).toEqual([401, 401, 401])
      expect((await httpGet(port, '/probe', '192.168.1.5', { cookie: `${WEB_TOKEN_COOKIE}=${TOKEN}` })).status).toBe(200)
    } finally {
      await dispose()
    }
  })

  it('stays unauthenticated and byte-identical when no token is configured', async () => {
    const { port, dispose } = await boot('')
    try {
      expect(await httpGet(port, '/probe', '192.168.1.5')).toMatchObject({ status: 200, body: 'PROBE' })
      // No token means no pairing route: /pair is served by the SPA fallback
      // and never issues a session cookie.
      const pair = await httpGet(port, '/pair', '192.168.1.5')
      expect(pair.status).toBe(200)
      expect(pair.headers['set-cookie']).toBeUndefined()
    } finally {
      await dispose()
    }
  })
})
