# DSH 移动端（dsh-mobile）

DSH（DeepSeek Harness）手机端 = **Flutter 原生壳 + WebView 内嵌 DSH 移动 Web 端**。
本工程只实现原生壳：配置页、WebView、自动重连与配置安全存储，不重写任何 DSH
业务/API 层。

**定位：公网服务器优先。** 手机通过「公网域名 + 手机口令」接入自己 VPS 上的
cloud-relay，再经 local-relay 隧道回到 Mac/工作站上的 DSH；局域网直连保留为
次要模式。

## 功能

- 首次配置页：公网/局域网双卡片，默认「公网服务器（推荐）」，局域网折叠；
- 公网模式：仅接受 `https://<域名>` + 手机口令，配对加载
  `<server>/m/?pass=<phone-pass>`，服务端校验后 Set-Cookie（HttpOnly）并
  302 到 `/m/` 剥掉口令参数；
- 局域网模式：`http(s)://<ip>:<port>` + 配对令牌，加载
  `<server>/pair?token=<token>&next=/m/`；
- 主页无多余 AppBar，WebView 全屏并做 SafeArea 避让系统状态栏；首次加载显示
  品牌遮罩，自动重连 2s/4s/8s、最多 3 次，重试耗尽进入错误页；
- 导航白名单：只放行与配置服务器同源的顶层导航，外链/未知域一律阻止；
- 设置入口在移动 Web 的设置页，通过 `DshShell` JS bridge 唤起原生设置；
- 凭据由 flutter_secure_storage（Android Keystore）加密存储，绝不写入日志；
- Android 允许系统截图/录屏（不设置 FLAG_SECURE）。

移动 Web 侧体验（位于 `../deepseek-harness`）：

- 会话抽屉按工作区分组，组可折叠；每组默认预览 5 行，「显示全部」后整组
  展开，由抽屉唯一滚动容器统一滚动，避免嵌套滚动冲突；
- 抽屉改由**屏幕中间 25%–75% 区域右滑**拉出，屏幕左缘留给 Android 系统
  返回手势；
- 任务完成、失败与审批/提问通过 **Android 系统通知栏**通知：移动 Web 走
  `DshNotify` JS bridge，Flutter 壳转调原生 NotificationChannel；App 进程
  存活期间（前台或后台）均可收到，点击通知回到 App；
- 输入框 Enter 只换行不发送；右下角发送按钮始终是发送，运行中单独显示停止
  按钮；
- 计划/目标入口移入「设置」，设置页包含服务器、工作区、会话信息。

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

## 测试

```bash
flutter analyze
flutter test
```

## 相关文档

- 完整部署链路：仓库根 `README.md` 与 `dsh-relay/DEPLOY.md`；
- 移动 Web 静态挂载：`dsh-mobile-server-plugin/README.md`。
