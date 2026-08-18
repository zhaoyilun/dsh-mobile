# VPS 安装提示词（交给服务器上的 pi 执行）

> 用法：把本文件内容整段发给 VPS 上的 pi。前提：`~/dsh-relay-vps.tar.gz` 已传到服务器，
> 且新子域名（建议 `dsh.<你的域名>`）的 A 记录已指向本机公网 IP。

---

你在我的 VPS 上部署 dsh-cloud-relay（DSH 手机的公网入口，Go 单二进制，WebSocket 隧道中继），
并卸载旧的 digital-company cloud-relay。安装包在 `~/dsh-relay-vps.tar.gz`（含源码、Dockerfile、
docker-compose.yml、Caddyfile、以及 `dist/linux-amd64/` 和 `dist/linux-arm64/` 预编译二进制，静态链接无依赖）。

按以下步骤执行，每步先探测再做，不要假设：

## 1. 环境探测（先输出结果再继续）

```sh
uname -m                                    # x86_64 → dist/linux-amd64；aarch64 → dist/linux-arm64
command -v docker && docker compose version # Docker 是否可用
command -v nginx && nginx -v                # nginx 是否在用
ss -tlnp | grep -E ':(80|443)\b'            # 80/443 被谁占用
systemctl list-units --type=service --all | grep -iE 'relay|digital|dc-'
ls /opt/
```

## 2. 卸载旧版 digital-company cloud-relay

- 找到旧 systemd 服务（名字可能是 `digital-company-relay`、`cloud-relay` 或类似）：`systemctl stop` 并 `systemctl disable`，删除 unit 文件，`systemctl daemon-reload`。
- 删除旧二进制目录（如 `/opt/dc/`）。
- **只删 dc.<你的域名> 那一个 nginx site**（`/etc/nginx/sites-enabled/` 与 `sites-available/` 里对应配置），其他站点一律不动；`nginx -t` 通过后 `systemctl reload nginx`。
- 输出删除清单（服务名、文件路径）供我确认。若没找到旧版，明确说“未发现旧版”。

## 3. 生成凭证（两个独立令牌，打印给我）

```sh
TUNNEL_TOKEN=$(openssl rand -hex 24)   # 给 Mac 上的 dsh-local-relay
PHONE_PASS=$(openssl rand -hex 16)     # 给手机 App（唯一凭证，牢记）
echo "TUNNEL_TOKEN=$TUNNEL_TOKEN"; echo "PHONE_PASS=$PHONE_PASS"
```

## 4. 部署 dsh-cloud-relay（按探测结果二选一）

### 路线 A：服务器已有 nginx 在管 80/443（优先走这条，不引入新端口冲突）

```sh
sudo mkdir -p /opt/dsh-relay && tar -xzf ~/dsh-relay-vps.tar.gz -C /tmp
sudo cp /tmp/dsh-relay/dist/linux-<按 arch 选>/dsh-cloud-relay /opt/dsh-relay/
```

systemd unit `/etc/systemd/system/dsh-cloud-relay.service`：

```ini
[Unit]
Description=dsh cloud relay (DSH mobile entry)
After=network.target

[Service]
ExecStart=/opt/dsh-relay/dsh-cloud-relay --listen 127.0.0.1:8090 --tunnel-token <TUNNEL_TOKEN> --phone-pass <PHONE_PASS>
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
```

nginx site（`/etc/nginx/sites-available/dsh-relay`，软链到 sites-enabled；域名用 dsh.<你的域名>）：

```nginx
server {
    listen 443 ssl;
    server_name dsh.<你的域名>;
    ssl_certificate     /etc/letsencrypt/live/dsh.<你的域名>/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/dsh.<你的域名>/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:8090;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;      # WebSocket 升级（/tunnel 与手机事件流都要）
        proxy_set_header Connection "upgrade";
        proxy_buffering off;                          # 流式响应不缓冲
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        client_max_body_size 64m;
    }
}
server {
    listen 80;
    server_name dsh.<你的域名>;
    location / { return 301 https://$host$request_uri; }
}
```

- 证书：若 certbot 在，先 `certbot --nginx -d dsh.<你的域名>`（或按现有证书流程）；
  DNS 没生效就停下告诉我，不要自签。
- `nginx -t && systemctl reload nginx`；`systemctl enable --now dsh-cloud-relay`。

### 路线 B：80/443 空闲且 Docker 可用（Docker Compose + Caddy 自动 HTTPS）

```sh
sudo mkdir -p /opt/dsh-relay && tar -xzf ~/dsh-relay-vps.tar.gz -C /opt/dsh-relay --strip-components=1
cd /opt/dsh-relay
cat > .env <<EOF
DOMAIN=dsh.<你的域名>
TUNNEL_TOKEN=<TUNNEL_TOKEN>
PHONE_PASS=<PHONE_PASS>
EOF
docker compose up -d --build
```

（compose 内 caddy 自动申请/续期 Let's Encrypt 证书，80/443 由 caddy 持有，cloud-relay 只监听 127.0.0.1:8090。）

### 两条路线都不满足时：报告探测结果并停下来问我，不要自作主张换方案。

## 5. 验收（全部通过才算完成）

```sh
curl -s http://127.0.0.1:8090/healthz        # 期望: ok
curl -s https://dsh.<你的域名>/healthz         # 期望: ok（验证 TLS + 反代）
curl -s -o /dev/null -w '%{http_code}\n' https://dsh.<你的域名>/   # 期望: 401（无凭证，正确）
```

## 6. 收尾输出（打印给我）

1. 旧版删除清单；
2. TUNNEL_TOKEN 与 PHONE_PASS；
3. Mac 端命令（我会在 Mac 上跑）：
   `dsh-local-relay --cloud wss://dsh.<你的域名>/tunnel?token=<TUNNEL_TOKEN> --local http://127.0.0.1:3080`
4. 手机 App 配置：服务器 `https://dsh.<你的域名>`，手机口令 `PHONE_PASS`。

## 红线

- 不动与 digital-company relay 无关的任何服务/站点/端口；
- 两个令牌只打印一次给我，不写入任何日志或文档；
- DNS 未生效、证书申请失败、端口被未知进程占用 → 停下报告，不要绕过。
