import 'dart:async' show unawaited;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'federation/federation_home_page.dart';
import 'federation/federation_state.dart';
import 'federation/local_settings.dart';
import 'federation/session_chat_page.dart';
import 'federation/session_list_page.dart' show Ui;
import 'theme.dart';

/// DSH 移动端 · 联邦原生客户端。
///
/// 旧的 WebView 远程访问链路（/m 壳 + 配对口令页）已随 Phase 2.5 退役，
/// 现在全部能力走 dsh-federation：持久设备身份 + MQTT 控制面 + 原生会话/文件页。
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // E2E 直开调试入口：flutter build web --dart-define=E2E_OPEN_SESSION=<sessionId>
  // 首页直接进入指定会话聊天页（绕过列表点击，验证 history 渲染链路）。
  const openSession = String.fromEnvironment('E2E_OPEN_SESSION');
  if (openSession.isNotEmpty) {
    // 直开模式没有主页，这里补上冷启动接线（身份恢复/MQTT/pairings）。
    FederationState.instance.init();
  }
  runApp(DshMobileApp(home: openSession.isEmpty
      ? const FederationHomePage()
      : SessionChatPage(sessionId: openSession, title: 'E2E直开会话')));
}

class DshMobileApp extends StatefulWidget {
  const DshMobileApp({super.key, required this.home});

  final Widget home;

  @override
  State<DshMobileApp> createState() => _DshMobileAppState();
}

class _DshMobileAppState extends State<DshMobileApp> {
  ThemeMode _mode = ThemeMode.system;

  @override
  void initState() {
    super.initState();
    // 主题偏好载入 + 实时监听（设置页切换立即生效）
    unawaited(LocalSettings.loadThemeMode().then((_) => _syncFromSettings()));
    LocalSettings.themeModeNotifier.addListener(_syncFromSettings);
  }

  @override
  void dispose() {
    LocalSettings.themeModeNotifier.removeListener(_syncFromSettings);
    super.dispose();
  }

  void _syncFromSettings() {
    final m = LocalSettings.themeMode;
    final next = switch (m) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    // Ui 全局调色板同步到当前实际亮度（system=跟随系统）
    final brightness =
        next == ThemeMode.dark ? Brightness.dark : (next == ThemeMode.light ? Brightness.light : ui.PlatformDispatcher.instance.platformBrightness);
    Ui.applyFor(brightness);
    if (mounted && next != _mode) {
      setState(() => _mode = next);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DSH',
      debugShowCheckedModeBanner: false,
      theme: buildDshTheme(),
      darkTheme: buildDshTheme(brightness: Brightness.dark),
      themeMode: _mode,
      home: widget.home,
    );
  }
}
