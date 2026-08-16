import 'package:flutter/material.dart';

/// DSH 移动壳语义 tokens。
///
/// 视觉基调沿用 `reference/dc-mobile`(用户自己的数字公司 App)的
/// Klein Blue + ice-white 体系,让原生壳的配置页/加载页/错误页与
/// WebView 内的 DSH 移动端质感一致,而不是默认 Material 模板观感。
class DshTokens {
  DshTokens._();

  // 品牌色。
  static const Color kleinBlue = Color(0xFF002FA7);
  static const Color kleinBlueDeep = Color(0xFF002080);
  static const Color kleinBlueSoft = Color(0xFFE8EDFB);
  static const Color iceWhite = Color(0xFFF7F9FC);

  // 中性色。
  static const Color surface = Color(0xFFFFFFFF);
  static const Color ink = Color(0xFF1A1F2B);
  static const Color inkSecondary = Color(0xFF5A6472);
  static const Color inkMuted = Color(0xFF8A93A0);
  static const Color divider = Color(0xFFE4E8EE);

  // 语义色(比 Material 默认色更沉稳,接近 dc-mobile 的观感)。
  static const Color success = Color(0xFF1B8A5A);
  static const Color warning = Color(0xFFB8860B);
  static const Color error = Color(0xFFC0392B);
  static const Color info = Color(0xFF3167C4);

  // 间距:0 / 4 / 8 / 12 / 16 / 24 / 32。
  static const double space1 = 4;
  static const double space2 = 8;
  static const double space3 = 12;
  static const double space4 = 16;
  static const double space5 = 24;
  static const double space6 = 32;

  // 圆角。
  static const double radiusS = 6;
  static const double radiusM = 10;
  static const double radiusL = 16;

  // 动效。
  static const Duration motionFast = Duration(milliseconds: 120);
  static const Duration motionNormal = Duration(milliseconds: 200);
  static const Duration motionSlow = Duration(milliseconds: 300);
}

/// 由语义 tokens 生成应用主题,亮色/暗色都可用。
///
/// dc-mobile 只做了亮色;这里补一份同源暗色,让系统深色模式下原生壳
/// 不突兀。WebView 内页面仍由 DSH 移动端自己的主题控制。
ThemeData buildDshTheme({Brightness brightness = Brightness.light}) {
  final isDark = brightness == Brightness.dark;
  final scheme = isDark
      ? ColorScheme.fromSeed(
          seedColor: DshTokens.kleinBlue,
          brightness: Brightness.dark,
          error: DshTokens.error,
        )
      : ColorScheme.fromSeed(
          seedColor: DshTokens.kleinBlue,
          brightness: Brightness.light,
          primary: DshTokens.kleinBlue,
          error: DshTokens.error,
        );
  final scaffoldBackground = isDark
      ? const Color(0xFF101418)
      : DshTokens.iceWhite;
  final appBarBackground = isDark ? const Color(0xFF171A1F) : DshTokens.surface;
  final appBarForeground = isDark ? const Color(0xFFE8EAED) : DshTokens.ink;

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scaffoldBackground,
    appBarTheme: AppBarTheme(
      backgroundColor: appBarBackground,
      foregroundColor: appBarForeground,
      elevation: 0,
      scrolledUnderElevation: 0.5,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: appBarForeground,
        fontSize: 16,
        fontWeight: FontWeight.w600,
      ),
    ),
    dividerTheme: DividerThemeData(
      color: isDark ? const Color(0xFF2A2F36) : DshTokens.divider,
      thickness: 0.5,
      space: 0.5,
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: scheme.primary),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        minimumSize: const Size(48, 48),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DshTokens.radiusM),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DshTokens.radiusM),
        ),
      ),
    ),
    textTheme: TextTheme(
      bodyMedium: TextStyle(
        fontSize: 15,
        color: isDark ? const Color(0xFFE8EAED) : DshTokens.ink,
        height: 1.55,
      ),
      bodySmall: TextStyle(
        fontSize: 13,
        color: isDark ? const Color(0xFFAEB4BD) : DshTokens.inkSecondary,
        height: 1.45,
      ),
    ),
  );
}
