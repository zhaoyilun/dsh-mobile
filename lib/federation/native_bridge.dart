// dsh-federation — 原生能力桥：系统通知 + 前台保活（仅 Android）。
// 原生实现在 MainActivity.kt 的 MethodChannel
// `dev.yourname.dsh_mobile/notifications`（show/requestPermission/startKeepAlive/stopKeepAlive）。
// 其余平台（桌面/Web/iOS）没有注册该 channel，调用要么跳过要么抛
// MissingPluginException——统一吞掉，调用方不需要感知平台差异。
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class NativeBridge {
  NativeBridge._();

  static const _channel = MethodChannel('dev.yourname.dsh_mobile/notifications');

  /// 原生 channel 只在 Android 注册（MainActivity.kt）；其余平台调用无意义。
  /// 用 defaultTargetPlatform 而非 dart:io Platform，保证 Web 编译通过。
  static bool get _supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// 启动时请求一次通知权限（Android 13+ 运行时权限；原生侧只首次弹窗）。
  static Future<void> requestNotificationPermission() async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<bool>('requestPermission');
    } catch (_) {}
  }

  /// 发一条系统通知；点击回到 App。title/body 为空时原生侧静默忽略。
  static Future<void> notify(String title, String body, {String? sessionId}) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<bool>('show', {
        'title': title,
        'body': body,
        if (sessionId != null) 'sessionId': sessionId,
      });
    } catch (_) {}
  }

  /// 启动前台保活服务（App 退后台时调用，防止进程被当作缓存回收）。
  static Future<void> startKeepAlive() async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<bool>('startKeepAlive');
    } catch (_) {}
  }

  static Future<void> stopKeepAlive() async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<bool>('stopKeepAlive');
    } catch (_) {}
  }
}
