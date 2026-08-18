# DSH Mobile —— DeepSeek Harness 手机端设计

> 状态：实施中。方案冻结于 2026-08-14（user 拍板：Flutter 原生壳 + 局域网直连 + 公网中继）。
> 决策人（pro）：架构/契约/验收；执行（flash 子代理）：机械编码。

## 1. 目标与来源

把 digital-company 废弃项目里的手机互联思路落地为 DSH 本体手机端：

- digital-company 经验：Flutter 原生 App（会话列表→聊天流→内联审批卡）、SSE 流式、
  重连兜底、冷启动本地缓存、`X-DC-Pass` 口令鉴权、扫码配对、cloud-relay 公网 WS 隧道。
- 关键差异：DSH 的 Web GUI 本身就是"客户端组合"（`window.__DSH_BOOT__` 引导图 +
  `/api` RPC + `/api/events.mux|host` WebSocket 事件流），会话/消息/工具卡/审批/计划/目标
  全是现成客户端包。手机端 = 新写一个移动优先壳，**复用全部客户端包**，不重造 API 层。

## 2. 架构

```
手机 (Flutter App "dsh-mobile")
  ├─ 配置页: 服务器地址 + 访问令牌（Keystore 加密存储）
  ├─ WebView (webview_flutter):
  │    局域网: http://<LAN-IP>:3080/pair?token=T  → DSH 移动壳（/m）
  │    公网:   https://relay.example.com/pair?token=T
  │              → dsh-cloud-relay（公网）──WS隧道──► dsh-local-relay（Mac）
  │                  → 重写 Host 为 127.0.0.1 → http://127.0.0.1:3080
  └─ 断线重连 / 重试页

DSH（deepseek-harness 源码，4 处改动）
  1. packages/host/webserver        可选请求守卫（HTTP + WS upgrade 全覆盖）
  2. packages/bundle/web-app        --web-token/DSH_WEB_TOKEN、/pair?token= 路由、
                                   终端 QR、/m 移动壳挂载
  3. apps/mobile + packages/client/mobile-*  移动优先 SPA（复用客户端组合）
  4. 信任围栏/鉴权已有；远程路径经中继时本地中继重写 Host→loopback，围栏放行
```

## 3. 冻结契约（各工作流共同遵守）

### 3.1 鉴权（工作流 A）

- CLI：`dsh web --web-token <token>` 或环境变量 `DSH_WEB_TOKEN`。未设置 = 现状不变。
- 设置后：**非 loopback Host 的一切请求**（HTTP + WS upgrade + 静态）必须通过鉴权；
  loopback 请求豁免（桌面端无感）。
- 鉴权凭据：cookie `dsh_web_token`（HttpOnly, SameSite=Lax, Path=/）；
  非浏览器客户端可用 `Authorization: Bearer <token>`；WS 握手额外接受 `?token=` 查询参数兜底。
- 配对入口：`GET /pair?token=<token>`：常量时间比较成功 → Set-Cookie + 302 到 `/`；
  失败 → 401 + 固定延迟。口令绝不写入日志/URL 行。
- 终端输出：token 已设且绑定 0.0.0.0 时，打印配对 URL + 二维码（零依赖 QR 编码器 vendored，
  需保留 MIT 署名）。
- 实现落点：`WebServer.setRequestGuard()`（handle() 与 upgrade 分发前调用）；
  guard 本体与 /pair 路由由 web-app bundle 在 token 存在时注册。

### 3.2 移动壳（工作流 B）

- 新 SPA 挂在 `/m`（prefix 静态路由，index 响应必须过 `applyIndexTaps()` 注入同一份
  `__DSH_BOOT__`）；桌面 `/` 与现有 dist 完全不动。
- 移动壳复用：boot/loader 机制、sessions/events 服务、消息渲染、工具卡、审批/提问卡、
  计划/目标、模型切换。新写只有移动布局帧（栈导航：会话列表 → 会话详情 + 二级页）。
- 禁止重写任何服务/协议层；桌面 UI 零改动。

### 3.3 Flutter 壳（工作流 C）

- 新 Flutter 工程 `dsh-mobile/`（android + ios 平台文件，首期交付 Android APK）。
- 依赖对齐参考：webview_flutter / flutter_secure_storage / shared_preferences。
- 连接流程：`<server>/pair?token=<token>` 交给 WebView 加载，之后全站同源 cookie 会话。
- 服务器地址允许 http（局域网）与 https（公网中继）两种 scheme。
- Android 明文 HTTP：用 networkSecurityConfig 白名单而非全局 usesCleartextTraffic。

### 3.4 中继（工作流 D）

- 新 Go module `dsh-relay/`：`cmd/dsh-cloud-relay`（公网）+ `cmd/dsh-local-relay`（Mac）。
- 协议以 digital-company 的 tunnel 协议为基础（hello/req/head/chunk/end/error），
  **新增 WS upgrade 透传**（upgreq / upg-ok / upg-bin 双向 base64 帧），
  因为 DSH 浏览器端事件流只有 WebSocket 一种载体。
- 本地中继把请求 Host 重写为目标地址（127.0.0.1:3080）并剥离 Origin/Sec-*，
  使 DSH 视为 loopback（信任边界：远程路径唯一鉴权 = cloud-relay 的 phone-pass；
  本地中继只出站、不监听端口）。
- 默认 `--local http://127.0.0.1:3080`。

## 4. 工作流与顺序

| # | 内容 | 执行 | 状态 |
|---|---|---|---|
| A | DSH 鉴权（webserver guard + web-app 旗标/配对路由/QR） | flash | ✅ 完成，pro 已审查；CLI 闸修正为「`--host 0.0.0.0` 必须有令牌」 |
| C | Flutter 壳（dsh-mobile） | flash | ✅ 完成（analyze/test/APK 全绿） |
| D | Go 中继（dsh-relay + WS 透传 + 部署文档） | flash | ✅ 完成，pro 已审查；DEPLOY.md 已补 DSH 启动参数要求 |
| B | 移动 Web 壳（/m 挂载 + 移动优先 UI） | flash | ✅ 完成；槽机制扩展（rootKey/DeclaredSlotOutlet）经 pro 审查接受；472 相关测试绿 |
| I | 集成：全量构建 → 变更清单 → 应用到真实 clone → runbook | pro 主导 | ✅ 完成：副本全量 build 绿、7 个变更包 475 测试绿、62 文件已落盘真实 clone（未提交，待 user 审查）、`INTEGRATION.md` 就绪 |

全量测试中 35 个失败均为环境因素（开发副本无 .git、代理沙箱挡 `/bin/ps` 与嵌套
sandbox-exec），与本次改动无关。剩余门禁项（双语文档、THIRD_PARTY_NOTICES、
WebRequestGuard 类型链接、Agent Note）已列入 `INTEGRATION.md` §3。

---

## 第二阶段：公网服务器专向（user 拍板）

| # | 内容 | 执行 | 状态 |
|---|---|---|---|
| P1 | 远程全链路验证（旧两层模型） | pro | ✅ 通过后推翻：WebView 无法带 X-DC-Pass 头、配对后落桌面页、两令牌过重 |
| P2 | `/pair` 支持 `next=/m/`（同源校验，防开放重定向） | pro | ✅ 4 测试绿，已同步真实 clone |
| P3 | Flutter 壳改版：公网优先（https+手机口令）/局域网折叠；`/m/?pass=` 与 `/pair?...&next=/m/`；自动重连 2/4/8s×3 + 状态指示 | flash | ✅ analyze/test 26 绿，APK 重建成功 |
| P4 | 中继改版：三凭据+cookie 会话（`?pass=` 302 剥除）、全请求 Host 重写（DSH 零旗标）、心跳 30s、/healthz、Docker+Caddy 一键部署 | flash | ✅ vet/build/test(-race) 全绿，docker build/compose config 通过；pro 已审鉴权代码 |
| P5 | 单口令远程全链路 e2e（真实 dsh web 零旗标） | pro | ✅ 全过（302+Set-Cookie、cookie 会话、WS 101/401） |

最终形态：**手机只连公网入口（手机口令唯一凭证）；Mac 端 dsh web 零配置 loopback +
local-relay 出站隧道；局域网直连为可选的调试模式。**

顺序约束：B 与 A 同改 packages/bundle/web-app，串行防冲突；C、D 与 A 无文件交集，并行。
I 阶段不动正在运行的 dsh web（重装包后由 user 自行重启生效）。

## 5. 交付物与验收

- A：单测（guard/pair/常量时间比较）+ 集成测试；README 补 `--web-token` 用法。
- C：flutter analyze/test 全绿；`flutter build apk --debug` 成功；config 存储测试移植。
- D：`go build ./...` + `go test ./...` 全绿（含 upgrade 透传测试）；`DEPLOY.md`
  （架构图/systemd/nginx TLS/安全说明，对齐 CLOUD-RELAY.md 风格）。
- B：新包/新 app `pnpm build` 绿 + 类型检查；`/m` 注入 `__DSH_BOOT__` 的单测；
  手机视口下：会话列表→会话详情（流式消息+工具卡）→审批/提问卡→模型切换 全链可用。
- I：`pnpm build` 全绿 → `git diff` patch 导出（本工作区无 .git，用 diff -ru 或
  `pnpm pack`）→ user 在真实 clone 应用 → 重建 + `npm i -g` → 重启 `dsh web
  --host 0.0.0.0 --web-token <口令>` → 手机装 APK 端到端验证（局域网 + 公网各一轮）。

## 6. 已知风险

- 公网路径的 WebSocket 经隧道三层包装（App WebView → HTTPS → 隧道 WS → 本地 WS），
  延迟与断线重连需实测；隧道协议加心跳是候选增强。
- 局域网 HTTP 下浏览器安全上下文缺失：Service Worker/PWA 安装受限（iOS 加主屏仍可用）；
  TLS（自签或反代）列为二期。
- 口令出现在配对 URL 中会进浏览历史/日志：v1 以"用户知情 + 302 剥除"缓解，
  一次性配对令牌（用后即焚）列为二期。
- Flutter WebView 在 Android 上对 WebSocket 的支持依赖系统 WebView 版本，需实测兜底。
