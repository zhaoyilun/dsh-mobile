import 'dart:async';

import 'package:flutter/material.dart';

import 'config_store.dart';
import 'pages/home_page.dart';
import 'pages/setup_page.dart';
import 'system_notifications.dart';
import 'theme.dart';
import 'widgets/dsh_brand_mark.dart';

/// DSH 移动端 · Flutter 原生壳。
///
/// 本工程只做原生壳:配置页 + WebView 内嵌 DSH 移动 Web 端。
/// 不在 Flutter 里重写任何 DSH 业务/API 层——WebView 里跑的就是完整客户端,
/// 配对用 cookie 会话(见 DESIGN.md §6)。
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  unawaited(SystemNotifications.requestPermission());
  runApp(const DshMobileApp());
}

class DshMobileApp extends StatelessWidget {
  const DshMobileApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DSH',
      debugShowCheckedModeBanner: false,
      theme: buildDshTheme(),
      darkTheme: buildDshTheme(brightness: Brightness.dark),
      themeMode: ThemeMode.system,
      home: const RootPage(),
    );
  }
}

/// 根路由:加载配置 → 有完整配置进 [HomePage],否则进 [SetupPage]。
class RootPage extends StatefulWidget {
  const RootPage({super.key});

  @override
  State<RootPage> createState() => _RootPageState();
}

class _RootPageState extends State<RootPage> {
  final ConfigStore _store = ConfigStore();
  bool _loading = true;
  AppConfig? _config;

  /// 配置保存版本号:每次保存都递增,作为 HomePage 重建 key。
  /// 不把 token 或 token.hashCode 放进 key,避免碰撞导致旧 WebView 复用。
  int _configRevision = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    AppConfig? config;
    try {
      config = await _store.load();
    } catch (_) {
      // 存储插件异常时按未配置处理,回设置页,不带着坏配置启动。
      config = null;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _config = config;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const _LaunchSplash();
    }
    final config = _config;
    if (config == null || !config.isComplete) {
      // 首次启动(或配置被清除):设置页保存后经 onSaved 回调重新加载配置。
      return SetupPage(onSaved: _load);
    }
    return HomePage(
      key: ValueKey(_configRevision),
      config: config,
      onConfigChanged: (newConfig) {
        setState(() {
          _config = newConfig;
          _configRevision += 1;
        });
      },
      onConfigCleared: () {
        // 清除配置:根路由回到首次配置页(SetupPage)。
        setState(() {
          _config = null;
          _configRevision += 1;
        });
      },
    );
  }
}

/// 配置加载阶段的启动页:比默认的裸转圈多一个品牌标识,冷启动观感一致。
class _LaunchSplash extends StatelessWidget {
  const _LaunchSplash();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const DshBrandMark(size: 64),
            const SizedBox(height: DshTokens.space4),
            Text(
              'DSH Mobile',
              style: theme.textTheme.titleLarge?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: DshTokens.space5),
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.4),
            ),
          ],
        ),
      ),
    );
  }
}
