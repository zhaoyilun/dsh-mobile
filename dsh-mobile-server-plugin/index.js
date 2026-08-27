import { readFile } from 'node:fs/promises'
import { dirname, extname, join, normalize, resolve, sep } from 'node:path'

/**
 * dsh-mobile-server-plugin
 *
 * Serves the DSH mobile frontend under the `/m` prefix without replacing the
 * desktop fallback. The mobile dist anchor comes from either:
 *
 *   - `config.distIndex` in `cordis.patch.yml` (preferred, survives cold boot), or
 *   - the `DSH_MOBILE_DIST_INDEX` environment variable.
 *
 * If neither is set the plugin stays dormant instead of failing `dsh web`
 * startup; this keeps ordinary profiles bootable.
 */

export const name = 'dsh-mobile-static'

export const inject = ['webServer']

const MOUNT = '/m'

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.json': 'application/json',
  '.map': 'application/json',
  '.webmanifest': 'application/manifest+json',
  '.png': 'image/png',
}

async function serveMobile(pathname, res, renderIndex, distIndex, distRoot) {
  if (pathname === MOUNT) {
    res.writeHead(200, { 'content-type': MIME['.html'], 'cache-control': 'no-cache' })
    res.end(await renderIndex())
    return
  }
  const relative = pathname.startsWith(`${MOUNT}/`) ? pathname.slice(MOUNT.length) : '/'
  const target = resolve(normalize(join(distRoot, relative)))
  if (target !== distRoot && !target.startsWith(distRoot + sep)) {
    res.writeHead(403)
    res.end()
    return
  }
  if (target === distRoot || target === distIndex) {
    res.writeHead(200, { 'content-type': MIME['.html'], 'cache-control': 'no-cache' })
    res.end(await renderIndex())
    return
  }
  try {
    const body = await readFile(target)
    res.writeHead(200, {
      'content-type': MIME[extname(target)] ?? 'application/octet-stream',
      'cache-control': 'no-cache',
    })
    res.end(body)
  } catch {
    // Unknown asset paths fall back to the SPA index, like the desktop shell.
    res.writeHead(200, { 'content-type': MIME['.html'], 'cache-control': 'no-cache' })
    res.end(await renderIndex())
  }
}

export function apply(ctx, config = {}) {
  const distIndex = config?.distIndex ?? process.env.DSH_MOBILE_DIST_INDEX
  if (typeof distIndex !== 'string' || distIndex.length === 0) {
    ctx.logger?.warn('dsh-mobile-static: no config.distIndex or DSH_MOBILE_DIST_INDEX; /m mount stays dormant')
    return
  }
  const distRoot = dirname(distIndex)

  const renderIndex = async () => {
    const html = await readFile(distIndex, 'utf8')
    // 0.1.1+: webserver renders the structured injection table (boot wire rows:
    // queue shim / preloads / __DSH_BOOT__) then legacy taps; ≤rc.8 only has
    // applyIndexTaps. Feature-detect so one plugin serves both hosts.
    return typeof ctx.webServer.renderIndex === 'function'
      ? ctx.webServer.renderIndex(html)
      : ctx.webServer.applyIndexTaps(html)
  }
  const route = {
    kind: 'prefix',
    path: MOUNT,
    handler: async (req, res) => {
      if (req.method !== 'GET' && req.method !== 'HEAD') {
        res.writeHead(405)
        res.end()
        return
      }
      const pathname = decodeURIComponent(new URL(req.url ?? '/', 'http://x').pathname)
      try {
        await serveMobile(pathname, res, renderIndex, distIndex, distRoot)
      } catch (error) {
        if (error?.code === 'ENOENT') {
          res.writeHead(503, { 'content-type': 'text/plain; charset=utf-8' })
          res.end('mobile dist not found: build apps/mobile first')
          return
        }
        throw error
      }
    },
  }
  let dispose
  try {
    dispose = ctx.webServer.register(route)
  } catch (error) {
    // Once the installed dsh web-app gains its own /m prefix mount (the
    // integration build), this shim must step aside instead of colliding.
    if (String(error).includes(`duplicate prefix route "${MOUNT}"`)) {
      ctx.logger?.info('dsh-mobile-static: /m already mounted by dsh-web-app, staying dormant')
      return
    }
    throw error
  }
  ctx.logger?.info(`dsh-mobile-static: serving /m from ${distIndex}`)
  ctx.effect(() => dispose, 'dsh-mobile-static: /m prefix route')
}
