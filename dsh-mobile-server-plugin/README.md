# dsh-mobile-server-plugin

把 `deepseek-harness/apps/mobile/dist` 挂载到运行中 DSH Web 服务的 `/m` 前缀，
桌面端 `/` 完全不动。插件体积很小，可通过 profile patch 热插入到 `dsh web`，
不需要重启 DSH 本体。

## 配置移动端 dist 路径

插件优先读取 patch 里的 `config.distIndex`（推荐，冷启动稳定）；也可以退而使用
环境变量 `DSH_MOBILE_DIST_INDEX`。两者都没有时插件保持休眠，`dsh web` 照常启动，
不会拖垮整个 harness。

`dist/` 由以下命令生成（当前源码已对齐 DSH 0.1.1-rc.2，构建产物不再需要
rc.8 时代的后构建补丁）：

```bash
cd deepseek-harness
pnpm install
pnpm --filter @deepseek-ai/dsh-mobile-frontend build
```

## 安装为 profile patch

在 `~/.dsh/profiles/web/cordis.patch.yml` 中插入：

```yaml
- insert:
    - id: mobile-static
      name: /absolute/path/dsh-mobile-server-plugin/index.js
      config:
        revision: 1
        distIndex: /absolute/path/deepseek-harness/apps/mobile/dist/index.html
```

之后普通启动即可，不需要任何临时 shell 环境变量：

```bash
dsh web
```

改动 `index.js` 后把上面的 `revision` +1，profile watcher 会重新加载插件。

## 验证

```bash
# 本地直连
curl -s http://127.0.0.1:3080/m/ | grep 'assets/index-'

# 公网路径（手机口令三形态之一）
curl -s -H 'X-DC-Pass: <PHONE_PASS>' https://relay.example.com/m/ | grep 'assets/index-'
```

## 回滚

- 从 `cordis.patch.yml` 删除 `mobile-static` 的 insert 条目；
- 或把 `revision` 改回旧值并恢复旧 `index.js`。

## 相关部署

- VPS 侧 cloud-relay：`../dsh-relay/DEPLOY.md`；
- 完整数据路径与口令模型：仓库根 `README.md`。
