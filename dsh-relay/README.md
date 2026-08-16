# dsh-relay

一对 Go 中继程序，把手机端 DSH 客户端的 HTTP/WebSocket 请求经公网隧道送进
Mac 上 loopback 绑定的 DSH（`http://127.0.0.1:3080`）：`dsh-cloud-relay` 是云
端公网入口，`dsh-local-relay` 是 Mac 上的出站隧道端（不监听任何端口）。
支持普通 HTTP 多路复用透传，以及 WebSocket 升级透传（DSH 的 `/api/events.mux`、
`/api/events.host` 事件流）。

远程路径的唯一鉴权是 **手机口令**：cloud-relay 接受 `X-DC-Pass` 头（程序化
客户端）、`?pass=` 查询参数（WebView 首次导航）或 `dsh_relay_pass` cookie
（首次成功后建立）；失败统一 401 + 1s 固定延迟。local-relay 把所有隧道请求的
Host 重写为 `127.0.0.1:3080` 并剥除浏览器安全头，DSH 因此把所有隧道流量视为
loopback——**远程路径不需要 `--trusted-host` 或 `--web-token`**，DSH 保持零
配置 loopback 绑定。

## 构建

```sh
go build ./cmd/dsh-cloud-relay   # 产物: dsh-cloud-relay
go build ./cmd/dsh-local-relay   # 产物: dsh-local-relay
```

## 测试

```sh
go vet ./...
go test ./...        # 含 upgrade 透传端到端测试（真实双进程 + 真实隧道）
```

## 5 分钟部署到 VPS（Docker Compose，推荐）

前提：VPS 已装 Docker + Compose 插件；域名 A 记录指向 VPS 的 IP。

```sh
# 1) 拿到代码（把 dsh-relay/ 整个目录拷到 VPS，或用 git clone）
cd dsh-relay

# 2) 配置 .env：域名 + 两个独立凭证
cp .env.example .env
openssl rand -hex 24   # 隧道令牌 -> 填 TUNNEL_TOKEN
openssl rand -hex 24   # 手机口令   -> 填 PHONE_PASS
#    编辑 .env：DOMAIN=relay.example.com

# 3) 一键启动（Caddy 自动申请/续期 HTTPS，WebSocket 升级自动透传）
docker compose up -d --build

# 4) 健康检查
curl -s https://relay.example.com/healthz   # -> ok

# 5) Mac 上启动本地隧道（进程常驻，断线自动指数退避重连 + 心跳保活）
./dsh-local-relay --cloud wss://relay.example.com/tunnel?token=$TUNNEL_TOKEN

# 6) 手机端：服务器地址填 https://relay.example.com，口令填 PHONE_PASS
#    App 自动加载 /m/?pass=<口令>：cloud-relay 校验后 Set-Cookie（HttpOnly）并
#    302 到 /m/（口令离开地址栏），此后同源请求自动带 cookie 会话。
```

- `cloud-relay` 只发布在宿主机 loopback（127.0.0.1:8090），不直接暴露公网；
  Caddy 负责 80/443 与 TLS。
- 换手机口令：改 `.env` 的 `PHONE_PASS` 后 `docker compose up -d`；换隧道令牌
  需同时重启 Mac 上的 `dsh-local-relay`。
- 不想用 Docker 的手动部署（直接运行 + systemd + 反代）见 [DEPLOY.md](DEPLOY.md)，
  作为备选路径保留。

## 部署与安全说明

见 [DEPLOY.md](DEPLOY.md)：架构图、单口令模型与信任边界、Docker Compose /
systemd / nginx / Caddy 四种部署形态、凭证管理与限制。
