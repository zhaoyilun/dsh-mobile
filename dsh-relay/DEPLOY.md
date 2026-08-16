# DEPLOY.md — dsh-relay 公网中继部署指南

`dsh-relay` 是一对 Go 中继程序，让手机端的 DSH 客户端能通过公网访问 Mac 上
loopback 绑定的 DSH（`http://127.0.0.1:3080`）。它由两个进程组成：

- **`dsh-cloud-relay`**：部署在云服务器上的公网入口，接收手机的 HTTP/WebSocket
  请求，通过一条长连接隧道多路复用转发。
- **`dsh-local-relay`**：运行在 Mac 上（与 DSH 同机），保持到云端的隧道连接，
  把隧道里的请求转发给本机 DSH。

隧道是纯转发管道：不落盘、不缓存、不感知业务。手机请求（含 DSH 浏览器客户端
需要的 WebSocket 事件流 `/api/events.mux`、`/api/events.host`）都可以透传。

## 架构

```
                        HTTPS / WSS                      WebSocket 隧道
 ┌────────┐  ?pass=/cookie   ┌───────────────┐  ?token=   ┌────────────────┐
 │ 手机端  │ ───────────────▶ │ dsh-cloud-relay│ ◀────────▶ │ dsh-local-relay │
 │ DSH 客户端│  (X-DC-Pass 备选) │  (云服务器, TLS) │  hello/req/ │    (Mac, 与 DSH 同机)   │
 └────────┘                  └───────────────┘  upgreq/    └────────────────┘
      │                            │            upg-bin/          │
      │                            │            upg-end           │  仅出站连接，
      │                            │                               │  不监听任何端口
      │                            ▼                               ▼
      │                     Caddy 自动 HTTPS               HTTP / WebSocket loopback
      │                            │                               │
      │                            └──────────────▶  http://127.0.0.1:3080 (DSH)
```

数据路径：**手机 →(wss, 手机口令三形态)→ cloud-relay →(wss 隧道, `?token=`)→
local-relay →(HTTP/WS loopback, Host 重写)→ 127.0.0.1:3080 DSH**。反向同样
成立：DSH 的响应、SSE 流、WebSocket 帧沿原路回到手机。

## 隧道协议（摘要）

普通请求（沿用参考实现，语义不变，只增不改）：

| 方向 | 消息 |
|---|---|
| local → cloud | `{"type":"hello","token":"<tunnel-token>"}` |
| cloud → local | `{"type":"ok"}` |
| cloud → local | `{"type":"req","id":N,"request":"<base64 原始请求 dump>"}` |
| local → cloud | `{"type":"head","id":N,"status":200,"header":{...}}` |
| local → cloud | `{"type":"chunk","id":N,"data":"<base64>"}`（任意多条） |
| local → cloud | `{"type":"end","id":N}` 或 `{"type":"error","id":N}` |

WebSocket 升级透传（DSH 事件流专用）：

| 方向 | 消息 |
|---|---|
| cloud → local | `{"type":"upgreq","id":N,"request":"<base64 原始请求 dump>"}` |
| local → cloud | `{"type":"upg-ok","id":N}`（本地 DSH 回了 101） |
| 双向 | `{"type":"upg-bin","id":N,"data":"<base64 帧载荷>","binary":true\|false}` |
| 双向 | `{"type":"upg-end","id":N}`（关闭对端） |

手机侧在收到 `upg-ok` 后才完成 WebSocket 升级；若本地 DSH 对升级请求回了普通
HTTP 响应（401/403/重定向等），local-relay 退化为普通 `head/chunk/end` 路径，
手机 WebSocket 客户端会收到一个普通 HTTP 错误。

隧道心跳（F3）：local-relay 每 `--ping-interval`（默认 30s）发一个 WS ping 帧，
3 倍间隔内收不到 pong（或任何消息）即判定隧道死亡，自动走指数退避重连
（1s、2s、4s … 上限 30s）。cloud-relay 无需额外逻辑：gorilla 对 ping 自动回
pong，读循环不受干扰。这同时防 NAT/反代空闲断链与死隧道悬挂。

## 先决条件

- Go 1.26（构建；Docker 部署则不需要本机 Go）。
- 云服务器：一个域名 + 能开 80/443 端口。推荐 Docker Compose + Caddy 自动
  HTTPS（见下）；也可以直接运行 + systemd + nginx/Caddy 反代（备选）。
- Mac：能访问 `http://127.0.0.1:3080` 上的 DSH。

## 单口令模型与信任边界

**远程路径的唯一鉴权 = 手机口令**（cloud-relay 的 `--phone-pass`）。手机口令
以三种形态之一提交，全部常量时间比较（`crypto/subtle`）：

1. 头 `X-DC-Pass: <pass>`（程序化客户端）；
2. 查询参数 `?pass=<pass>`（移动 WebView 首次导航——WebView 无法给导航请求
   自定义头，只能带查询串）；
3. cookie `dsh_relay_pass`（首次成功后在浏览器里建立的会话）。

首次成功（头或查询参数）时 cloud-relay 下发 `Set-Cookie: dsh_relay_pass=<pass>;
HttpOnly; SameSite=Lax; Path=/`；查询参数成功还会 **302 到同路径剥掉 `?pass=`**
（口令离开地址栏，重定向目标只由原请求路径推导，无开放重定向）。失败一律
**401 + 固定 1s 延迟**（防爆破，对齐 DSH `/pair` 行为）。WebSocket 升级请求
**不重定向**：升级前直接校验 cookie（或 `?pass=` 兜底），合法才 101，会话
cookie 随 101 响应下发。

**DSH 侧保持零配置 loopback 绑定**：local-relay 对所有隧道请求（普通 HTTP 与
WS 升级一致）做 Host 重写——`req.Host = 127.0.0.1:3080`，并删除 `Origin`、
`Sec-Fetch-*` 浏览器安全头——DSH 因此把所有隧道流量视为本机客户端，远程路径
**不再需要 `--trusted-host` 或 `--web-token`**。信任边界：local-relay 是用户
本机上的可信进程（它把 loopback 内容经隧道送出去）；手机口令与隧道令牌是两个
独立凭证，泄漏其一不会暴露另一个。

## 生成两个独立凭证

```sh
openssl rand -hex 24   # 隧道令牌 tunnel-token（local 连 cloud 用）
openssl rand -hex 24   # 手机口令 phone-pass（手机访问 cloud 用）
```

## 云端部署（dsh-cloud-relay）

### 方式一：Docker Compose + Caddy 自动 HTTPS（推荐，见 README「5 分钟部署」）

仓库已带 `Dockerfile`、`docker-compose.yml`、`Caddyfile`、`.env.example`：

```sh
cp .env.example .env            # 填 DOMAIN / TUNNEL_TOKEN / PHONE_PASS
docker compose up -d --build
curl -s https://<DOMAIN>/healthz   # -> ok
```

- `cloud-relay` 容器只把 `127.0.0.1:8090` 发布到宿主机 loopback；`Caddyfile`
  用 `{$DOMAIN}` 占位（Caddy 从环境变量 `DOMAIN` 读取），`reverse_proxy
  127.0.0.1:8090`，WebSocket 升级自动透传，TLS 证书自动申请/续期。
- `GET /healthz` 无需鉴权，只返回 `ok`，供监控/负载均衡探活。

### 方式二：直接运行（或 systemd 托管）

```sh
./dsh-cloud-relay --listen 127.0.0.1:8090 \
  --tunnel-token "$TUNNEL_TOKEN" \
  --phone-pass "$PHONE_PASS"
```

带 TLS 直出（可选，证书直接给 cloud-relay）：

```sh
./dsh-cloud-relay --listen :443 \
  --tls-cert /etc/letsencrypt/live/relay.example.com/fullchain.pem \
  --tls-key  /etc/letsencrypt/live/relay.example.com/privkey.pem \
  --tunnel-token "$TUNNEL_TOKEN" \
  --phone-pass "$PHONE_PASS"
```

### systemd 示例（`/etc/systemd/system/dsh-cloud-relay.service`）

```ini
[Unit]
Description=dsh-cloud-relay (DSH public relay)
After=network-online.target
Wants=network-online.target

[Service]
User=relay
Group=relay
ExecStart=/opt/dsh-relay/dsh-cloud-relay --listen 127.0.0.1:8090 \
  --tunnel-token ${TUNNEL_TOKEN} \
  --phone-pass ${PHONE_PASS}
EnvironmentFile=/etc/dsh-relay.env
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

`/etc/dsh-relay.env`：

```
TUNNEL_TOKEN=<openssl rand -hex 24 输出>
PHONE_PASS=<openssl rand -hex 24 输出>
```

启动：`sudo systemctl daemon-reload && sudo systemctl enable --now dsh-cloud-relay`。

### nginx TLS 反代示例

```nginx
server {
    listen 443 ssl http2;
    server_name relay.example.com;

    ssl_certificate     /etc/letsencrypt/live/relay.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/relay.example.com/privkey.pem;

    # 普通 HTTP 请求与 WebSocket 升级（/tunnel、/api/events.mux 等都走这里）
    location / {
        proxy_pass http://127.0.0.1:8090;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        # WebSocket 升级透传必需
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
```

### Caddy TLS 反代（不用 Docker 时）

```
{$DOMAIN} {
    reverse_proxy 127.0.0.1:8090
}
```

`{$DOMAIN}` 由 Caddy 从环境变量 `DOMAIN` 替换（或直接写死域名）。Caddy 自动
申请/续期证书，且对 WebSocket 升级自动透传，无需额外配置。

## Mac 本地运行（dsh-local-relay）

```sh
./dsh-local-relay \
  --cloud wss://relay.example.com/tunnel?token=$TUNNEL_TOKEN \
  --local http://127.0.0.1:3080 \
  --ping-interval 30s
```

- `--local` 默认就是 `http://127.0.0.1:3080`，可省略；`--ping-interval` 默认
  30s（0 关闭心跳）。
- 进程常驻：隧道断开后自动指数退避重连（1s、2s、4s … 上限 30s），心跳超时
  同样走该重连循环，无需守护。
- 局域网/开发机演示可用明文 `ws://`；公网请务必用 `wss://`。

手机端 DSH 客户端把服务器地址填成 `https://relay.example.com/...`，口令填
**手机口令**（与 cloud-relay 的 `--phone-pass` 一致）：App 首次加载
`/m/?pass=<口令>`，cloud-relay 校验后 Set-Cookie 并 302 到 `/m/`，此后全站
同源 cookie 会话。

## 安全说明

- **两个独立凭证**：`--tunnel-token` 只给 local-relay（经 URL `?token=` 传入，
  握手时 constant-time 校验）；`--phone-pass` 只给手机（头/`?pass=`/cookie 三
  形态，constant-time 校验）。泄漏其一不会暴露另一个；请分别保管、定期轮换。
- **单口令模型**：远程路径唯一鉴权 = 手机口令；DSH 侧保持零配置 loopback
  绑定，所有隧道流量经 Host 重写按本机请求放行，不再需要
  `--trusted-host`/`--web-token`。信任边界是 local-relay 本身（用户本机可信
  进程）。
- **cookie 会话**：首次成功下发 `dsh_relay_pass`（HttpOnly、SameSite=Lax、
  Path=/），`?pass=` 场景 302 剥查询串让口令离开地址栏；失败统一 401 + 1s
  延迟防爆破；无开放重定向。
- **隧道只转发不落盘**：所有请求/响应/帧只在内存中流转，不写日志正文、不缓存。
- **local 只出站不监听**：`dsh-local-relay` 不监听任何端口，只主动连接云端，
  因此即使 Mac 位于 NAT/内网也能打通，且不向局域网暴露任何服务。
- **心跳保活**：WS ping 每 `--ping-interval` 一次，pong 超时（3 倍间隔）即判定
  隧道死亡并重连，防 NAT/反代空闲断链。
- **凭证比较均为 constant-time**（`crypto/subtle`），避免时序侧信道。
- 换手机口令无需重启 cloud-relay：下次请求即生效；改隧道令牌需重启
  local-relay。

## 限制与二期规划

- **明文 HTTP 风险**：若 cloud-relay 不带 TLS（直连 `http://`/`ws://`），手机
  口令与业务数据明文暴露。公网部署必须 TLS（wss/https，Caddy/nginx 反代或
  `--tls-cert/--tls-key` 直出）。
- **WebSocket 帧类型已保留**：upg 透传在 `upg-bin` 消息里携带 `binary` 标记，
  text/binary 帧到对端仍保持原类型(2026-08-16 修复);握手响应头仍不转发
  (`Sec-WebSocket-Protocol`/本地 `Set-Cookie` 等不会回传手机)。
- **背压策略**：隧道读端对每个 upg 会话用带缓冲队列；极端背压下的超限帧会被
  丢弃并记日志，事件流客户端应具备重连机制兜底。
- **手机口令为静态长效**：一次性手机令牌/吊销列表列为二期；当前面向
  个人/可信手机。
- 单隧道模型：cloud-relay 同一时刻只接受一条 local 隧道（第二个连接被拒绝），
  适合单 Mac + 单用户；多机/多用户需另行设计。
