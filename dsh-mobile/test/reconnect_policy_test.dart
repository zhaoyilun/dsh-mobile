import 'package:flutter_test/flutter_test.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:dsh_mobile/reconnect_policy.dart';

void main() {
  WebResourceError err(WebResourceErrorType? type, {int code = 0}) {
    return WebResourceError(
      errorCode: code,
      description: 'x',
      errorType: type,
      isForMainFrame: true,
    );
  }

  test('网络级错误(connect/hostLookup/io/timeout/unknown≠-1)判为断联', () {
    expect(isNetworkLevelError(err(WebResourceErrorType.connect)), isTrue);
    expect(isNetworkLevelError(err(WebResourceErrorType.hostLookup)), isTrue);
    expect(isNetworkLevelError(err(WebResourceErrorType.io)), isTrue);
    expect(isNetworkLevelError(err(WebResourceErrorType.timeout)), isTrue);
    expect(
      isNetworkLevelError(err(WebResourceErrorType.unknown, code: -2)),
      isTrue,
    );
  });

  test('资源型/取消型错误不触发页面级重连', () {
    // unknown(-1) 是 Android WebView 的 ERROR_UNKNOWN 兜底码,历史错误回放
    // 常携带;资源加载失败同理。
    expect(
      isNetworkLevelError(err(WebResourceErrorType.unknown, code: -1)),
      isFalse,
    );
    expect(isNetworkLevelError(err(null)), isFalse);
  });
}
