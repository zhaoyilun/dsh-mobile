import 'dart:convert';

import 'package:flutter/services.dart';

/// Android 系统通知桥:移动 Web 端把「审批/提问/任务完成」事件通过
/// `DshNotify` JavaScript channel 发给原生壳,原生壳再调用系统通知栏。
class SystemNotifications {
  static const MethodChannel _channel = MethodChannel(
    'dev.zhaoyilun.dsh_mobile/notifications',
  );

  /// Android 13+ 首次启动时请求通知权限(低版本直接返回)。
  static Future<void> requestPermission() async {
    try {
      await _channel.invokeMethod<void>('requestPermission');
    } on PlatformException {
      // 权限弹窗失败不阻塞 App 启动。
    } on MissingPluginException {
      // 非 Android 平台或调试环境没有该通道。
    }
  }

  /// 显示一条系统通知;`sessionId` 仅用于点击通知回到 App。
  static Future<void> show({
    required String title,
    required String body,
    String? sessionId,
  }) async {
    try {
      await _channel.invokeMethod<void>('show', {
        'title': title,
        'body': body,
        if (sessionId != null) 'sessionId': sessionId,
      });
    } on PlatformException {
      // 系统通知不可用时静默失败;不影响主流程。
    } on MissingPluginException {
      // 非 Android 平台或调试环境没有该通道。
    }
  }

  /// 解析 WebView 发来的 JSON 并展示。
  static Future<void> showFromWeb(String payload) async {
    try {
      final data = jsonDecode(payload);
      if (data is! Map<String, dynamic>) {
        return;
      }
      final title = data['title'];
      final body = data['body'];
      if (title is! String || body is! String) {
        return;
      }
      final sessionId = data['sessionId'];
      await show(
        title: title,
        body: body,
        sessionId: sessionId is String ? sessionId : null,
      );
    } on FormatException {
      // Web 端消息损坏时忽略。
    }
  }
}
