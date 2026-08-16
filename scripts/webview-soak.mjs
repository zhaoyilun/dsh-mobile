// WebView-resilience soak: hold the mobile shell open like the App does, inject
// the failures a flaky LAN produces (subresource 4xx, WS drop, offline windows),
// and assert the SPA self-heals WITHOUT any document-level navigation.
import { createRequire } from 'node:module'
import { resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = fileURLToPath(import.meta.url)
const requireFromHarnessWeb = createRequire(resolve(here, '../deepseek-harness/apps/web/package.json'))
const { chromium } = requireFromHarnessWeb('playwright')

const base = process.argv[2] ?? 'http://127.0.0.1:3080'
const browser = await chromium.launch({ args: ['--no-proxy-server'] })
const page = await browser.newPage({ viewport: { width: 390, height: 844 } })

let navigations = 0
let wsDrops = 0
const markers = []
page.on('framenavigated', f => { if (f === page.mainFrame()) navigations++ })
page.on('websocket', ws => {
  ws.on('close', () => { wsDrops++ })
})

// Track the SPA's own connection state via console warnings.
page.on('console', m => {
  const t = m.text()
  if (t.includes('connection lost')) markers.push(`retry: ${t.slice(0, 60)}`)
})
page.on('pageerror', e => markers.push(`PAGEERROR: ${String(e).slice(0, 120)}`))

await page.goto(`${base}/m/`, { waitUntil: 'domcontentloaded', timeout: 20000 })
await page.waitForTimeout(6000)
const navAfterLoad = navigations

// Fault 1: subresource 4xx storm (like credentials.describe 403 + a stray 404).
await page.evaluate(async () => {
  for (const path of ['/api/credentials.describe', '/api/nope-404', '/api/settings.describe']) {
    await fetch(path, { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{}' }).catch(() => {})
  }
})
await page.waitForTimeout(2500)

// Fault 2: kill both WebSockets from inside (simulates radio drop).
await page.evaluate(() => {
  // The shell owns its sockets; reaching the WebSocket global is unavailable,
  // so simulate via offline instead.
})
const cdp = await page.context().newCDPSession(page)
await cdp.send('Network.enable')
await cdp.send('Network.emulateNetworkConditions', { offline: true, latency: 0, downloadThroughput: 0, uploadThroughput: 0 })
await page.waitForTimeout(4000)
await cdp.send('Network.emulateNetworkConditions', { offline: false, latency: 0, downloadThroughput: -1, uploadThroughput: -1 })
await page.waitForTimeout(12000)

// Fault 3: another subresource 4xx round after recovery.
await page.evaluate(async () => {
  await fetch('/api/nope-404', { method: 'POST', body: '{}' }).catch(() => {})
})
await page.waitForTimeout(3000)

const body = await page.locator('body').innerText()
const healed = !/正在加载会话|连接中/.test(body)
console.log('=== 长跑结果 ===')
console.log(`主文档导航次数: 加载后 ${navigations - navAfterLoad} 次 ${navigations - navAfterLoad === 0 ? 'PASS（零刷新）' : 'FAIL（发生页面刷新）'}`)
console.log(`WS 掉线次数: ${wsDrops}（>0 说明注入生效）`)
console.log(`SPA 内部重连尝试: ${markers.filter(m => m.startsWith('retry')).length} 次`)
console.log(`页面未捕获异常: ${markers.filter(m => m.startsWith('PAGEERROR')).length} ${markers.filter(m => m.startsWith('PAGEERROR')).length === 0 ? 'PASS' : 'FAIL'}`)
console.log(`恢复后界面健康(无加载态残留): ${healed ? 'PASS' : 'FAIL: ' + body.slice(0, 120)}`)
console.log('--- markers ---')
console.log(markers.slice(0, 10).join('\n') || '(none)')
await browser.close()
