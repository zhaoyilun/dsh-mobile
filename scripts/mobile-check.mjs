// DSH mobile-shell self-check: load /m/ in headless Chromium against a LAN-mode
// server, capture console/network/WS facts, and report a verdict. Loopback access
// is guard-exempt, so no pairing is needed from the Mac.
// Usage: node scripts/mobile-check.mjs [baseUrl]   (default http://127.0.0.1:3099)
// playwright is resolved from the harness checkout (no workspace root of our own).
import { createRequire } from 'node:module'
import { resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = fileURLToPath(import.meta.url)
const requireFromHarnessWeb = createRequire(resolve(here, '../deepseek-harness/apps/web/package.json'))
const { chromium } = requireFromHarnessWeb('playwright')

const base = process.argv[2] ?? 'http://127.0.0.1:3080'
const browser = await chromium.launch({ args: ['--no-proxy-server'] })
const page = await browser.newPage({ viewport: { width: 390, height: 844 } })

const facts = { console: [], ws: [], fail: [] }
page.on('console', m => { if (['error', 'warning'].includes(m.type())) facts.console.push(`${m.type()}: ${m.text().slice(0, 160)}`) })
page.on('requestfailed', r => facts.fail.push(`net: ${r.url().slice(0, 120)} :: ${r.failure()?.errorText}`))
page.on('response', r => { if (r.status() >= 400) facts.fail.push(`http ${r.status()} ${r.url().slice(0, 120)}`) })
page.on('websocket', ws => {
  const url = ws.url().slice(0, 90)
  facts.ws.push(`open ${url}`)
  ws.on('close', () => facts.ws.push(`close ${url}`))
})

await page.goto(`${base}/m/`, { waitUntil: 'domcontentloaded', timeout: 20000 })
// Wait for the session list to settle: rows render, or the pending hint stays.
await page.waitForTimeout(9000)

const rows = await page.locator('[data-mobile-nav] ~ * button, .\\? div[class*="row"], button').allInnerTexts().catch(() => [])
const body = (await page.locator('body').innerText()).slice(0, 1500)
const subagentLeak = /你是|执行型编码代理|专家简报/.test(body)
// ChatGPT 版式:首屏=当前会话对话视图(顶栏 ≡/标题/✚),列表在抽屉里。
const hasList = body.includes('✚') && !/正在加载/.test(body)
const connected = await page.getByText('已连接').count().catch(() => 0)

console.log('=== 页面文本（前 700 字）===')
console.log(body.slice(0, 700))
console.log('=== WS 事件 ===')
console.log(facts.ws.join('\n') || '(none)')
console.log('=== 网络失败/4xx ===')
console.log(facts.fail.join('\n') || '(none)')
console.log('=== console error/warn ===')
console.log(facts.console.join('\n') || '(none)')
console.log('=== 判定 ===')
console.log(`首屏对话视图渲染(≡/✚/标题): ${hasList ? 'PASS' : 'FAIL'}`)
console.log(`子代理泄漏: ${subagentLeak ? 'FAIL（列表里出现子代理 prompt 开头）' : 'PASS（无泄漏）'}`)
console.log(`设置页"已连接"文案存在: ${connected > 0 ? 'PASS' : '（未进入设置页，跳过）'}`)
await browser.close()
process.exit(hasList && !subagentLeak && facts.fail.length === 0 ? 0 : 1)
