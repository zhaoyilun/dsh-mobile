// dsh-federation — 移动端本地偏好（真设置：KvStore 持久化 + 内存缓存同步）。
// 与 host 设置无关的纯客户端项：系统通知开关、消息字号。
import 'package:flutter/foundation.dart' show ValueNotifier;

import 'kv_store.dart';

class LocalSettings {
  LocalSettings._();

  /// 系统通知（审批/提问/任务失败/回复完成）开关；默认开。
  static bool notify = true;

  /// 消息字号（13 / 15 / 17）；默认 15。
  static double fontSize = 15;

  static const _kNotify = 'settings.notify';
  static const _kFontSize = 'settings.fontSize';

  static Future<void> load() async {
    final st = const KvStore();
    final n = await st.read(key: _kNotify);
    if (n != null) notify = n != '0';
    final f = await st.read(key: _kFontSize);
    if (f != null) {
      final v = double.tryParse(f);
      if (v != null && (v == 13 || v == 15 || v == 17)) fontSize = v;
    }
  }

  static Future<void> saveNotify(bool on) async {
    notify = on;
    await const KvStore().write(key: _kNotify, value: on ? '1' : '0');
  }

  static Future<void> saveFontSize(double v) async {
    fontSize = v;
    await const KvStore().write(key: _kFontSize, value: v.toString());
  }

  /// 外观：light / dark / system（默认 system）。notifier 供 MaterialApp 实时响应。
  static String themeMode = 'system';
  static final ValueNotifier<String> themeModeNotifier = ValueNotifier('system');
  static const _kThemeMode = 'settings.themeMode';

  static Future<void> loadThemeMode() async {
    final st = const KvStore();
    final v = await st.read(key: _kThemeMode);
    if (v != null && {'light', 'dark', 'system'}.contains(v)) {
      themeMode = v;
      themeModeNotifier.value = v;
    }
  }

  static Future<void> saveThemeMode(String mode) async {
    themeMode = mode;
    themeModeNotifier.value = mode;
    await const KvStore().write(key: _kThemeMode, value: mode);
  }
}
