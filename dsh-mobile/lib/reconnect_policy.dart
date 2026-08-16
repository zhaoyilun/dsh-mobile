import 'package:webview_flutter/webview_flutter.dart';

/// WebView 错误分级:哪些资源错误算「网络级断联」。
///
/// 主文档只有命中这些类型才触发页面级自动重连;资源型失败
/// (图片/预取/4xx 子请求)与取消型失败交给页面内 SPA 自愈。
/// `unknown(-1)` 是 Android 的错误兜底码,切后台回前台时常被补发,
/// 必须排除,避免唤醒即误判断联。
bool isNetworkLevelError(WebResourceError error) {
  final type = error.errorType;
  return type == WebResourceErrorType.connect ||
      type == WebResourceErrorType.hostLookup ||
      type == WebResourceErrorType.io ||
      type == WebResourceErrorType.timeout ||
      (type == WebResourceErrorType.unknown && error.errorCode != -1);
}
