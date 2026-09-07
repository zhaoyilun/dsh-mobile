# DSH 移动端（dsh-mobile）

DSH（DeepSeek Harness）手机端，**Flutter 联邦原生客户端**。
旧的「WebView 壳 + 移动 Web」链路（配对口令页、`/m` 内嵌页、DshShell JS bridge）
已随 Phase 2.5 退役，现在所有能力走 dsh-federation 协议。

## 平台支持

| 平台 | 状态 | 说明 |
|---|---|---|
| Android | ✅ 完整 | 通知 / 前台保活 / Keystore 凭据 |
| macOS | ✅ 完整 | 联调主力；凭据与本地库在 `~/Library/Application Support/dsh_mobile/`（0600） |
| iOS | ✅ 基本功能 | 无通知桥（未接原生侧） |
| Web | ✅ 测试用 | `flutter run -d chrome`；本地库为内存版（刷新即失），MQTT 仅 ws/wss |
| Windows / Linux | ✅ 未实测 | 脚手架已就位（sqflite FFI + 文件 KV），需在对应平台自行编译验证 |

平台差异全部通过条件实现隔离（`*_web.dart` / `*_io.dart` / 工厂文件），业务代码
不感知平台：

- **本地历史库**：`store/local_store_sqflite.dart`（IO 系）↔ `store/local_store_memory.dart`（Web）；
- **KV 凭据存储**：`kv_file_io.dart`（桌面 0600 文件）↔ `kv_file_web.dart`（恒走 secure storage）；
- **MQTT 客户端**：`mqtt_client_factory.dart`（MqttServerClient，TCP/WSS）↔
  `mqtt_client_factory_web.dart`（MqttBrowserClient，仅 WSS）；
- **文件下载**：`file_transfer.dart`（流式落盘 + 增量哈希）↔ `file_transfer_web.dart`（Blob 触发浏览器下载）。

### Web 端联调注意

- 浏览器同源策略：registry / host API 的响应需带 CORS 头（自建反代时注意
  `Access-Control-Allow-Origin` 与 credentials）；WebSocket（wss）不受 CORS 限制；
- 数据面文件下载是整包进内存，只适合中小文件；
- Web 的凭据存 flutter_secure_storage 的 Web 实现（强度有限），不要在公用浏览器配对。

## 架构

```
App（本工程，Flutter）
 ├─ 设备身份     Ed25519 密钥对本机生成；私钥/设备令牌只存安全存储
 │               （Android Keystore / 桌面 0600 kv.json），不上报、不进日志
 ├─ 控制面 MQTT  wss 连 broker（默认 wss://dsh-mqtt.example.com/mqtt）
 │               presence（LWT 离线广播）· registry 订阅 · RPC 请求/应答（Ed25519 签名验签）
 ├─ 会话数据面   host API（HTTPS）——配对凭证换签名 cookie，SSE 流式收增量
 └─ 本地历史     sqflite：sessions/messages 两表，(session_id, seq) 唯一索引幂等合并，
                 离线打开也有历史；每会话保留最近 2000 条
```

配对链路：dsh 桌面「设置 → 联邦」生成配对码 → App 填「根地址 + 配对码 + 设备名」
→ `POST /v1/pairing/join`（公钥随 join 上传）→ registry 签发 deviceId/deviceToken
→ 之后按边下发 host 访问凭证（pairings 刷新是凭证新鲜度的唯一同步机制）。

## 功能

- **会话**：本地库优先渲染 → `session.history` 去重合并 → SSE 增量流式；
  发送即回显（负 seq 临时行，确认后清除）；支持单聊/群聊双视图；可发图片；
  流式兼容真实 host 的 `assistant/chunk`（text-delta）与兼容层 `assistant/text` 两种增量；
- **审批/提问**：工具的 `approval/requested` 与 `question/requested` 在会话页内直接
  应答（允许一次/拒绝、选项或自由输入，走 host `/api/respond`），不必跳回桌面；
  流式回复期间上滑看历史不会被新消息抢走滚动位置（右下角浮钮回到底部）；
- **SSE 兜底**：90s 空闲看门狗 + SSE 正常时 30s 慢速对账、断开时 5s 轮询；
- **MQTT 重连**：断线由 mqtt_client 自动重连；初连失败按 2/4/8/16/32/60s 指数退避重试；
- **系统通知（Android）**：工具审批、agent 提问、任务失败总是通知；回复完成仅
  App 不在前台时通知；点击通知回到 App；
- **后台保活（Android）**：退后台启动低优先级前台服务，回前台即停；
- **文件**：浏览配对设备目录，下载走取件单（sha256 全程校验，lan/公网数据面
  按序回退，流式落盘不吃内存）；
- **多 dsh**：一机多台配对，会话列表页顶栏可切换目标。

## 构建与安装（Android）

环境：Flutter 3.32+、Android SDK（platform 35 / build-tools 35）、
NDK 27.0.12077973（gradle 已固定）、JDK 17。

```bash
flutter build apk --debug
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

正式分发请创建 release keystore 并按 `android/key.properties.example` 填写
`android/key.properties`，再执行：

```bash
flutter build apk --release
```

Release 构建不会回退到 debug key；缺少 key.properties 时会直接报错。

macOS 端（联调用）：`flutter run -d macos`。

Web 端（本地快速测试）：`flutter run -d chrome`（默认连云端 registry/broker；
本地联调在「设置」卡片改回 127.0.0.1）。

## 测试

```bash
flutter analyze
flutter test            # 单测：签名验签/幂等合并/解析器/派生规则（live 测试自动跳过）
flutter test integration_test/xxx.dart -d <device>   # 真机探针：走真实云端与模型
```

## 已知限制

- **通知覆盖面**：SSE 只在「打开某个会话」时建立，未打开的会话不产生通知
  （架构性边界；后续可做全局事件通道）；
- **划掉 App = 断线**：从最近任务划掉或强制停止后，SSE/MQTT/前台服务一起结束；
- **图片上传**：base64 塞进 JSON RPC（超时放宽到 60s），协议级分片/直传是待办；
- **文件上传未实现**：`files.ingest`（本机临时数据面）在页面上还没有入口；
- **暗色主题未迁移**：页面直接引用浅色 token，themeMode 固定 light；
- **registry 快照未验签**：reply 验签的公钥来自 MQTT retained 快照，完整性依赖
  broker ACL（见 `lib/federation/registry_view.dart` 头注释）。

## 相关文档

- 协议与部署链路：仓库根 `README.md`、`dsh-federation/DESIGN.md`、`PAIRING-SPEC.md`；
- 历史性能审计（针对已退役的 WebView/移动 Web 栈）：`../dsh-mobile-perf-audit-20260830.md`。
