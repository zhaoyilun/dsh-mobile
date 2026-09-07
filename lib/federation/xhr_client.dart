// dsh-federation — Web 专用 XHR 版 http Client（仅浏览器编译）。
// 为什么不用 http 包的 BrowserClient：其 1.x 的 fetch 实现在完成请求后会破坏
// Flutter Web 的手势派发（E2E 实测：任何一次 fetch 成功后，路由 push 过的页面
// 全部点击失效；换成 XHR 后完全正常——见 e2e_minimal.dart 轮 9-11 对照）。
// XHR 支持 withCredentials，浏览器托管 cookie 的方案不受影响；流式响应（SSE）
// 通过 onprogress 的 responseText 增量实现。
// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:typed_data';

import 'package:http/http.dart' as http;

class XhrClient extends http.BaseClient {
  XhrClient({this.withCredentials = true});

  final bool withCredentials;

  /// 浏览器禁由 JS 设置的请求头（Fetch/XHR 规范）：设置会触发
  /// "Refused to set unsafe header" 控制台报错（每次请求刷屏）。发送前剔除；
  /// cookie 在 Web 上由浏览器按 withCredentials 自动管理，本就不该手动带。
  static const _forbiddenHeaders = {
    'cookie', 'cookie2', 'host', 'origin', 'referer', 'user-agent',
    'content-length', 'connection', 'date', 'expect', 'te', 'trailer',
    'transfer-encoding', 'upgrade', 'via', 'proxy-', 'sec-',
  };

  bool _isForbidden(String name) {
    final lower = name.toLowerCase();
    return _forbiddenHeaders.any(lower.startsWith);
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final completer = Completer<http.StreamedResponse>();
    final xhr = html.HttpRequest();
    xhr.open(request.method, request.url.toString(), async: true);
    xhr.withCredentials = withCredentials;
    request.headers.forEach((name, value) {
      if (!_isForbidden(name)) xhr.setRequestHeader(name, value);
    });

    final controller = StreamController<List<int>>();
    var consumed = 0;
    var completed = false;

    void pushDelta() {
      // onprogress 期间 responseText 只能读「目前为止的全部」：把新增部分喂给流
      final text = xhr.responseText;
      if (text != null && text.length > consumed) {
        final chunk = text.substring(consumed);
        consumed = text.length;
        controller.add(utf8.encode(chunk));
      }
    }

    void completeSend() {
      if (completed) return;
      completed = true;
      final headers = <String, String>{};
      final raw = xhr.getAllResponseHeaders();
      for (final line in raw.split('\r\n')) {
        if (line.isEmpty) continue;
        final idx = line.indexOf(':');
        if (idx <= 0) continue;
        headers[line.substring(0, idx).trim().toLowerCase()] = line.substring(idx + 1).trim();
      }
      completer.complete(http.StreamedResponse(
        controller.stream,
        xhr.status ?? 0,
        request: request,
        headers: headers,
        contentLength: int.tryParse(headers['content-length'] ?? ''),
        isRedirect: false,
        persistentConnection: false,
      ));
    }

    // SSE/流式响应：send() 必须等「响应头到了」就返回（否则 HostEventsStream
    // 的 await send 会等到流关闭才继续，SSE 永不开读——正文由 onprogress 增量喂流）。
    xhr.onReadyStateChange.listen((_) {
      if (xhr.readyState >= html.HttpRequest.HEADERS_RECEIVED) completeSend();
    });

    xhr.onProgress.listen((_) => pushDelta());

    xhr.onLoad.listen((_) {
      pushDelta();
      completeSend();
      if (!controller.isClosed) controller.close();
    });

    xhr.onError.listen((_) {
      if (!completed) {
        completer.completeError(http.ClientException('XHR failed: ${request.url}', request.url));
      } else {
        // 流已交给调用方（SSE）：错误进流并关闭，让读取方走重连
        if (!controller.isClosed) {
          controller.addError(http.ClientException('XHR stream error: ${request.url}', request.url));
          controller.close();
        }
      }
    });

    request.finalize().toBytes().then((Uint8List body) {
      xhr.send(body.isEmpty ? null : body);
    }).catchError((Object e) {
      if (!completed) completer.completeError(e);
    });

    return completer.future;
  }
}
