# dsh-mobile-server-plugin

把 `deepseek-harness/apps/mobile/dist` 挂载到运行中 DSH Web 服务的 `/m` 前缀，
桌面端 `/` 完全不动。插件体积很小，可通过 profile patch 热插入到 `dsh web`，
不需要重启 DSH 本体。

## 必需环境变量

`mobile-static` 不猜测任何机器路径，启动前必须显式指定移动前端构建产物：

```bash
export DSH_MOBILE_DIST_INDEX=/absolute/path/deepseek-harness/apps/mobile/dist/index.html
```

`dist/` 由以下命令生成：

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
```

启动方式（环境变量 + patch 同时生效）：

```bash
DSH_MOBILE_DIST_INDEX=/absolute/path/deepseek-harness/apps/mobile/dist/index.html dsh web
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
