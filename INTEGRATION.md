# INTEGRATION —— DSH Mobile 集成与上线手册

> 面向：user（赵义仑）。所有工件在本工作区 `/Volumes/MySSD/zhaoyilun/dev/dsh_dev/`。
> 源码改动在 `deepseek-harness/`（真实 clone 的开发副本），目标仓库为
> `/Volumes/MySSD/zhaoyilun/dev/deepseek-harness`（干净 master，47f9438）。

## 1. 交付物总览

| 线 | 内容 | 位置 | 验证 |
|---|---|---|---|
| A | 局域网令牌鉴权：`--web-token`/`DSH_WEB_TOKEN`、`/pair` 配对路由、终端二维码；`--host 0.0.0.0` 仅在有令牌时放行 | deepseek-harness 副本（2 个包 + docs） | 28 单测 + 全量 build 绿 |
| B | 移动 Web 壳 `/m`：新包 `packages/client/mobile` + 新 app `apps/mobile`（PWA manifest，无 SW）+ frontend-static path 模式 + web-react 槽机制扩展（rootKey/DeclaredSlotOutlet） | 同上（5 个包/文件组） | 472 相关测试 + 全量 build 绿 |
| C | Flutter 壳 App（配置页 + WebView 配对 + Keystore 存储） | `dsh-mobile/`（APK: `build/app/outputs/flutter-apk/app-debug.apk`） | analyze/test/APK 绿 |
| D | Go 中继（cloud + local，含 WebSocket upgrade 透传） | `dsh-relay/`（`DEPLOY.md` 含云端部署） | go vet/test(-race)/e2e 绿 |

变更文件清单：`integration-files.txt`（19 个修改文件 + 新增文件，含 apps/mobile、
packages/client/mobile、docs/MOBILE-ACCESS.md、web-app 新增 src/tests、两处 tsconfig 与 pnpm-lock）。

## 2. 应用到真实 clone

```sh
# 1) 备份（可选）
cd /Volumes/MySSD/zhaoyilun/dev/deepseek-harness && git stash list && git status --short
# 2) 拷贝变更文件（清单在 dsh_dev/integration-files.txt）
cd /Volumes/MySSD/zhaoyilun/dev/dsh_dev && \
  python3 scripts-apply-files.py   # 或手动按清单 cp 到真实 clone
# 3) 审查 diff
cd /Volumes/MySSD/zhaoyilun/dev/deepseek-harness && git status --short && git diff --stat
```

拷贝时**排除**：`node_modules/`、`lib/`、`dist/`、`*.tsbuildinfo`、`.DS_Store`。
`pnpm-lock.yaml` 必须一起拷（新增包 workspace 依赖）。

## 3. 构建与门禁（在真实 clone 内）

```sh
cd /Volumes/MySSD/zhaoyilun/dev/deepseek-harness
pnpm install
pnpm build          # 全量；build:web 已含 apps/mobile（新增一行，root package.json）
pnpm test           # 单测；CI 覆盖率门（test:coverage）与 doc-sync/hygiene 建议提交前跑
```

> 集成期发现并已修复：root `package.json` 的 `build:web` 原本只构建
> `dsh-web-frontend`，已补 `dsh-mobile-frontend`（本文件清单含 `package.json`）。

## 3.1 冒烟结果（真实 clone，端口 3099，已通过并关闭）

| 检查 | 结果 |
|---|---|
| `--host 0.0.0.0` 带 token 启动 | ✅ 打印 LAN URL + 配对行 + 二维码（17 行半块字符） |
| loopback `GET /` 无凭据 | ✅ 200（桌面豁免） |
| LAN Host 无凭据 `GET /` | ✅ 401 |
| LAN Host + cookie `GET /` | ✅ 200 |
| `/pair?token=` 正确/错误 | ✅ 302+Set-Cookie / 401（1s 延迟） |
| `/m/` 注入 `__DSH_BOOT__`、`/m/assets/*.js`、manifest | ✅ 全 200 |
| LAN WS `/api/events.mux` 无凭据 / 带 cookie / 带 `?token=` | ✅ 拒绝 / 101 / 101 |

**单口令远程全链路（本地模拟：cloud :8091 + local → 3099，真实 dsh web 零旗标）**

| 检查 | 结果 |
|---|---|
| `dsh web` 无 `--web-token`/`--trusted-host` 服务隧道流量 | ✅ |
| `GET /healthz` | ✅ 200 ok |
| 首次导航 `/m/?pass=` | ✅ 302 + Set-Cookie(HttpOnly) + Location `/m/` |
| 带 cookie `/m/`（`__DSH_BOOT__`）与 `/` | ✅ 200 |
| 无凭据 HTTP / WS | ✅ 401 / 401 |
| WS 带中继 cookie / `?pass=` | ✅ 101 / 101 |

**局域网真机联调（Android WebView，2026-08-14 夜）——两个真实缺陷已修复**

| 缺陷 | 现象 | 修复 |
|---|---|---|
| WebView WS 握手不带 cookie | 手机端事件流秒断（close 1006），桌面正常 | 新增一次性升级门票：`GET /ws-ticket`（cookie 鉴权）→ 60s TTL 单次使用 → WS 以 `?ticket=` 握手；fetch 失败降级为无票握手（cookie 客户端不受影响） |
| `mintRpcId` 依赖安全上下文 | 非安全上下文（局域网 HTTP）无 `crypto.randomUUID` → describe 同步崩 → 整代连接 abort | `getRandomValues` 构造 v4 UUID 兜底（apiproxy 层） |

真机最终验收：会话列表渲染、双 WS ✅、`session.list`/`host.describe` 200。
附带确认：`credentials.describe`/`settings.describe` 对非 loopback 客户端 403，是 DSH 原有
权限设计，手机端相应功能优雅降级。

已知非阻塞项（集成期注意）：
- 新 README 无双语配对（README.zh.md/.i18n.yaml）——`pnpm run doc-sync` 会红，需补齐或先跳过；
- THIRD_PARTY_NOTICES.md 未登记 vendored QR 编码器（Nayuki, MIT）——需要补一条；
- 按仓库规范，非平凡变更需 Agent Note（`.agents/notes/`），提交时补。

## 4. 运行（推荐：从 clone 源启动，不碰全局安装）

**公网服务器场景（产品主形态，零配置）**——DSH 只需普通 loopback 启动：

```sh
cd /Volumes/MySSD/zhaoyilun/dev/deepseek-harness
pnpm dsh --profile web            # 默认 127.0.0.1:3080，无需任何旗标
```

Mac 上另跑 `dsh-local-relay`（只出站、不监听），手机永远只连公网入口。
DSH 侧**不需要** `--web-token`/`--trusted-host`——隧道流量经 local-relay 重写
Host 后按 loopback 到达。

**局域网调试模式（可选）**——直接绑网卡需要口令：

```sh
pnpm dsh --profile web --host 0.0.0.0 --web-token <自定口令>
# 终端打印 LAN URL + 配对行 + 二维码（openssl rand -hex 16 生成口令）
```

- 端口冲突：先停掉当前全局 `dsh web`（这会关闭现有 GUI 会话，属预期切换）。
- 桌面浏览器照旧 `http://127.0.0.1:3080`（loopback 豁免鉴权）。
- 可选：全局 npm 包重装（打包发布流程较重，日常用 clone 源启动即可）。

## 5. 手机端到端验收

### 局域网

1. 手机装 APK：`adb install dsh-mobile/build/app/outputs/flutter-apk/app-debug.apk`
   （或拷到手机安装）。
2. App 切到「局域网直连」模式：服务器地址 `http://<Mac的LAN IP>:3080`、
   令牌 = `--web-token` 口令。
3. App 进入 WebView，自动走 `/pair?token=...&next=/m/` → 落在移动壳 `/m`。
4. 验收清单：
   - [ ] 会话列表显示既有会话，当前会话高亮；
   - [ ] 进入会话：消息流完整、发消息后流式回复实时刷新（WebSocket 事件流）；
   - [ ] 工具卡（bash/read 等）可见；
   - [ ] 审批/提问卡可点、决策生效（与桌面同步）；
   - [ ] 模型切换可用；计划/目标页有内容；
   - [ ] 断 Wi-Fi 再恢复：重试页出现，点重试恢复；
   - [ ] 桌面端同时在线：两侧会话状态一致。

### 公网（中继）

1. 云端部署 `dsh-cloud-relay`（一键：`docker compose up -d`，自动 HTTPS，
   见 `dsh-relay/DEPLOY.md`；或 systemd + nginx/Caddy 手装）。
2. Mac 运行 `dsh-local-relay --cloud wss://<域名>/tunnel?token=<隧道令牌> --local http://127.0.0.1:3080`
   （隧道自动心跳保活，断线指数退避重连）。
3. **DSH 零配置**：`pnpm dsh --profile web` 即可，不需要任何旗标。
4. App 默认「公网服务器」模式：服务器地址 `https://<域名>`、手机口令 = phone-pass；
   首次导航 `<域名>/m/?pass=<手机口令>` → 中继设 cookie 并 302 落 `/m/`。
5. 验收：切 4G 后完成一轮"会话列表→发消息→流式回复→批一条审批"；断网再回
   App 自动重连（2s/4s/8s 三次退避，耗尽显示错误页可手动重试）。

## 6. 安全边界（备忘）

- 局域网路径唯一凭证 = `--web-token`（静态口令 + 常量时间比较 + HttpOnly cookie + /pair 1s 失败延迟）；口令出现在配对 URL/二维码，只在可信终端打印。
- 远程路径唯一凭证 = 手机口令（cloud-relay 常量时间比较 + HttpOnly cookie 会话；
  `?pass=` 只在首次导航出现，302 后离开地址栏）；隧道另有独立隧道令牌（hello 握手）。
- 信任边界：local-relay 是用户本机可信进程，把隧道流量重写为 loopback 客户端；
  DSH 保持 loopback 绑定，无 LAN 暴露面。
- 手机口令为静态令牌：泄漏即完整控制，建议定期轮换；`/healthz` 无鉴权仅供监控。
- 明文 HTTP 局域网有窃听风险；TLS（公网 Caddy 自动 HTTPS 已覆盖）、一次性配对
  令牌与限速在二期清单。

## 7. 二期候选

TLS/HTTPS、一次性配对令牌与限速、Service Worker/PWA 安装（需安全上下文）、
Flutter 壳断线自动重连增强、隧道心跳、iOS 平台文件真机验证、
`npm i -g` 打包发布流程、Agent Note 与双语文档补齐。

## 8. 当前运行环境的热更新(2026-08-16,未重启 dsh)

正在运行的 `dsh web` 是旧版全局安装,原本 `/m/` 会落到桌面 index。现场已
通过 profile watcher 热插入 `mobile-static` 插件,把 `/m/*` 交给
`apps/mobile/dist`;同时热替换了全局 `dsh-client-runtime/lib/client.js`
(rootKey 支持)。`/` 桌面端保持不变。插件源码、生效方式、验证结果与回滚
见 `dsh-mobile-server-plugin/README.md`。

移动壳 `MobileFrame` 已接入 `pushState`/`popstate`,Flutter WebView 的
系统返回键会按「抽屉 → 二级页 → WebView 历史 → 退出 App」的顺序处理。

## 9. VPS 公网入口 <你的域名>(2026-08-16 配置完成)

- `dsh-relay` 的 Caddy 已同时服务 `<你的域名>` 与 `dsh.<你的域名>`,cloud-relay
  手机口令已按 user 要求设置;Docker 容器已重建。
- `dsh-local-relay` 已作为 macOS LaunchAgent
  (`~/Library/LaunchAgents/dev.zhaoyilun.dsh-local-relay.plist`) 常驻,
  云端隧道自动重连。
- 修复 upg WebSocket 透传丢失 text/binary 帧类型的问题:协议 `upg-bin`
  增加 `binary` 标记,公网 DSH 事件流不再报 binary frame。
- 公网验收:无凭据 401、`/m/?pass=…` 302 + HttpOnly cookie、cookie 后
  `/m/` 200、双 WS 正常、console error 0。
