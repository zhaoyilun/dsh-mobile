/**
 * Optional shared-secret web-token authentication for the dsh Web server:
 * the request guard, the `/pair` pairing endpoint, and the terminal pairing
 * line with its QR code. Everything here is inert until a token is configured
 * (via `--web-token` or `DSH_WEB_TOKEN`); with no token the webserver behaves
 * exactly as before. The token itself never enters logs, prompt sections, or
 * `DSH_WEB_URL` — it appears only in the printed pairing line and the QR code,
 * which are the pairing mechanism by design.
 * @module @deepseek-ai/dsh-web-app/pairing
 */

import { createHash, randomBytes, timingSafeEqual } from 'node:crypto'
import type { IncomingMessage, ServerResponse } from 'node:http'
import type { WebRequestGuard, WebServer } from '@deepseek-ai/dsh-host-webserver'
import { WS_TICKET_PATH } from '@deepseek-ai/dsh-client-connection'
import { isLoopbackHostname } from './loopback-hostname.ts'
import qrcodegen from './qrcode.ts'

/** Cookie name carrying an authenticated pairing session. */
export const WEB_TOKEN_COOKIE = 'dsh_web_token'

/** The pairing endpoint pathname; the guard admits it because it authenticates itself. */
export const PAIR_PATH = '/pair'

/** Lifetime of a one-time upgrade ticket, from mint to handshake. */
const WS_TICKET_TTL_MS = 60_000

/** One-time upgrade tickets: ticket value → expiry epoch ms. */
const wsTickets = new Map<string, number>()

/** Fixed delay before a rejected pairing response, throttling token brute force. */
const PAIR_FAIL_DELAY_MS = 1000

/** Base URL for parsing relative request URLs. */
const BASE_URL = 'http://x'

/**
 * Constant-time token equality: both sides are sha256-digested first so the
 * comparison always runs over equal-length buffers and timing reveals nothing
 * about how close a guess is.
 * @param expected - the configured token.
 * @param presented - the client-supplied credential.
 * @returns true when the two tokens are equal.
 */
export function tokenMatches(expected: string, presented: string): boolean {
  const expectedDigest = createHash('sha256').update(expected).digest()
  const presentedDigest = createHash('sha256').update(presented).digest()
  return timingSafeEqual(expectedDigest, presentedDigest)
}

/** One named cookie's value from a `Cookie` header, or undefined when absent. */
function cookieValue(header: string | undefined, name: string): string | undefined {
  if (header === undefined) return undefined
  const prefix = `${name}=`
  for (const part of header.split(';')) {
    const trimmed = part.trim()
    if (trimmed.startsWith(prefix)) return trimmed.slice(prefix.length)
  }
  return undefined
}

/** The token from an `Authorization: Bearer <token>` header, or undefined. */
function bearerValue(header: string | undefined): string | undefined {
  if (header === undefined) return undefined
  const match = /^Bearer\s+(.+)$/i.exec(header)
  return match?.[1]
}

/** The request's credential: cookie, Bearer, or (upgrades only) the `?token=` query. */
function credentialFrom(req: IncomingMessage, upgrade: boolean): string | undefined {
  const cookie = cookieValue(req.headers.cookie, WEB_TOKEN_COOKIE)
  if (cookie !== undefined) return cookie
  const bearer = bearerValue(req.headers.authorization)
  if (bearer !== undefined) return bearer
  if (upgrade) {
    const queryToken = new URL(req.url ?? '/', BASE_URL).searchParams.get('token')
    return queryToken ?? undefined
  }
  return undefined
}

/**
 * Mint a one-time upgrade ticket. Expired tickets sweep lazily on each mint.
 * @returns the ticket value to present once on a WebSocket handshake.
 */
function mintWsTicket(): string {
  const now = Date.now()
  for (const [stale, expiry] of wsTickets) {
    if (expiry <= now) wsTickets.delete(stale)
  }
  const ticket = randomBytes(24).toString('hex')
  wsTickets.set(ticket, now + WS_TICKET_TTL_MS)
  return ticket
}

/**
 * Consume one upgrade ticket: valid only on its first presentation and before
 * its expiry. The lookup is a bearer-token redemption, not a secret comparison.
 * @param presented - the `?ticket=` value from the handshake.
 * @returns true when the ticket redeems.
 */
function consumeWsTicket(presented: string): boolean {
  const expiry = wsTickets.get(presented)
  if (expiry === undefined) return false
  wsTickets.delete(presented)
  return expiry > Date.now()
}

/** Answer a rejected non-loopback HTTP request: small body, no details leaked. */
function rejectUnauthenticated(res: ServerResponse | undefined): void {
  if (res === undefined) return // upgrade rejection: the server destroys the socket
  if (res.headersSent) return
  res.writeHead(401, { 'content-type': 'text/plain; charset=utf-8' })
  res.end('unauthorized')
}

/**
 * Build the request-authentication gate for a configured token: loopback
 * hosts pass without credentials, `/pair` is admitted for its own
 * self-authentication, and every other request must present the token as the
 * pairing cookie, a Bearer credential, or — for upgrades only — the `?token=`
 * query parameter.
 * @param token - the configured shared secret.
 * @returns the gate to install via `webServer.setRequestGuard`.
 */
export function createRequestGuard(token: string): WebRequestGuard {
  return (req, res, upgrade): boolean => {
    const url = new URL(req.url ?? '/', BASE_URL)
    if (url.pathname === PAIR_PATH) return true
    const host = req.headers.host
    if (host !== undefined) {
      try {
        if (isLoopbackHostname(new URL(`http://${host}`).hostname)) return true
      } catch {
        // An unparsable Host authority cannot be loopback; fall through to the credential check.
      }
    }
    const presented = credentialFrom(req, upgrade)
    if (presented !== undefined && tokenMatches(token, presented)) return true
    // One-time upgrade ticket: minted over cookie-authenticated HTTP, redeemed
    // on exactly one handshake. WebViews that strip cookies from WebSocket
    // handshakes authenticate through this path.
    if (upgrade) {
      const ticket = url.searchParams.get('ticket')
      if (ticket !== null && consumeWsTicket(ticket)) return true
    }
    rejectUnauthenticated(res)
    return false
  }
}

/** Sleep for a fixed period (the pairing-failure throttle). */
function delay(ms: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, ms))
}

/**
 * Sanitize the `next` redirect target of the pairing endpoint: only a
 * same-origin path is honored, so the phone lands on the surface it was
 * pairing for (the mobile shell hands `/m/`); anything else falls back to the
 * app root. Same-origin means a single leading slash, no scheme, no
 * backslash, no CR/LF.
 * @param raw - the `?next=` value, or null when absent.
 * @returns the sanitized redirect target.
 */
export function sanitizePairNext(raw: string | null): string {
  if (raw === null) return '/'
  if (!raw.startsWith('/') || raw.startsWith('//')) return '/'
  if (/[\\\r\n]/.test(raw)) return '/'
  return raw
}

/**
 * Register the upgrade-ticket mint: a cookie-authenticated GET returns one
 * single-use ticket. The guard does not exempt this route — it authenticates
 * like any other, so only an already-paired client can mint handshake tickets.
 * @param server - the webserver service to register the route on.
 * @returns the route disposer.
 */
export function installWsTicketRoute(server: WebServer): () => void {
  return server.register({
    kind: 'exact',
    path: WS_TICKET_PATH,
    handler: (_req, res) => {
      res.writeHead(200, { 'content-type': 'application/json' })
      res.end(JSON.stringify({ ticket: mintWsTicket() }))
    },
  })
}

/**
 * Register the pairing endpoint: a correct `?token=` sets the session cookie
 * and redirects to the app root (the token leaves the address bar), anything
 * else answers 401 after a fixed delay. The endpoint authenticates itself, so
 * it also requires the token from loopback hosts — pairing is its only job.
 * @param server - the webserver service to register the route on.
 * @param token - the configured shared secret.
 * @returns the route disposer.
 */
export function installPairing(server: WebServer, token: string): () => void {
  return server.register({
    kind: 'exact',
    path: PAIR_PATH,
    handler: async (req, res) => {
      const params = new URL(req.url ?? '/', BASE_URL).searchParams
      const presented = params.get('token')
      if (presented !== null && tokenMatches(token, presented)) {
        res.writeHead(302, {
          Location: sanitizePairNext(params.get('next')),
          'Set-Cookie': `${WEB_TOKEN_COOKIE}=${token}; HttpOnly; SameSite=Lax; Path=/`,
        })
        res.end()
        return
      }
      await delay(PAIR_FAIL_DELAY_MS)
      res.writeHead(401, { 'content-type': 'text/plain; charset=utf-8' })
      res.end('pairing failed')
    },
  })
}

/**
 * Render a QR code for terminal display with Unicode half-block characters:
 * each output line encodes two module rows (▀ top dark, ▄ bottom dark, █ both
 * dark, space neither). A 4-module light quiet zone is added around the
 * symbol, as the QR spec requires for reliable scanning.
 * @param text - the payload (the pairing URL, token included).
 * @returns the multi-line terminal rendering.
 */
export function renderQrTerminal(text: string): string {
  const qr = qrcodegen.QrCode.encodeText(text, qrcodegen.QrCode.Ecc.LOW)
  const size = qr.size
  const quiet = 4
  const width = size + quiet * 2
  const lines: string[] = []
  for (let y = 0; y < width; y += 2) {
    const topRow = y - quiet
    const bottomRow = topRow + 1
    const topValid = topRow >= 0 && topRow < size
    const bottomValid = bottomRow >= 0 && bottomRow < size
    let line = ''
    for (let x = 0; x < width; x++) {
      const moduleX = x - quiet
      const inRange = moduleX >= 0 && moduleX < size
      const top = topValid && inRange && qr.getModule(moduleX, topRow)
      const bottom = bottomValid && inRange && qr.getModule(moduleX, bottomRow)
      line += top ? (bottom ? '█' : '▀') : (bottom ? '▄' : ' ')
    }
    lines.push(line)
  }
  return lines.join('\n')
}
