// dsh-federation — mock-host 集成测试（需先启动 scripts/mock-host.mjs，默认 127.0.0.1:3088）
// 验证：HostSession rpc 信封 → session.list/history → SSE 帧流（subscribed + 事件增量）。
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;


Future<bool> _mockUp() async {
  try {
    // 用真实契约探测（POST session.list）：3088 被无关服务占用时应答非 200 → 视为 mock 未运行。
    final res = await http.post(
      Uri.parse('http://127.0.0.1:3088/api/session.list'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({'type': 'client-request', 'rpcId': 'probe', 'method': 'session.list', 'payload': <String, dynamic>{}}),
    );
    return res.statusCode == 200;
  } catch (_) {
    return false;
  }
}

void main() {
  test('mock-host 集成：rpc + SSE（mock 未启动时自动跳过）', () async {
    if (!await _mockUp()) {
      markTestSkipped('mock-host not running on 127.0.0.1:3088 — skip live test');
      return;
    }
    // mock-host 无认证：直接用裸 http 模拟 HostSession（与 local_api 同协议）
    final base = 'http://127.0.0.1:3088';

    // 1) session.list
    final listRes = await http.post(
      Uri.parse('$base/api/session.list'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({'type': 'client-request', 'rpcId': 't1', 'method': 'session.list', 'payload': <String, dynamic>{}}),
    );
    expect(listRes.statusCode, 200);
    final listBody = jsonDecode(listRes.body) as Map<String, dynamic>;
    expect((listBody['result']['value']['sessions'] as List).length, greaterThanOrEqualTo(1));

    // 2) session.prompt → SSE 帧监督：收 assistant/text 增量
    final streamDone = Completer<bool>();
    final sseFuture = () async {
      final client = http.Client();
      final req = http.Request('GET', Uri.parse('$base/api/events.mux'));
      final res = await client.send(req);
      final gotText = <String>[];
      var buffer = '';
      final lines = res.stream.transform(utf8.decoder);
      await for (final chunk in lines) {
        buffer += chunk;
        int boundary;
        while ((boundary = buffer.indexOf('\n\n')) != -1) {
          final block = buffer.substring(0, boundary);
          buffer = buffer.substring(boundary + 2);
          final data = block.split('\n').where((l) => l.startsWith('data: ')).map((l) => l.substring(6)).join();
          if (data.isEmpty) continue;
          final full = jsonDecode(data) as Map<String, dynamic>;
          final payload = full['payload'] as Map<String, dynamic>?;
          if (payload == null) continue;
          if (payload['type'] == 'session/subscribed') {
            expect(payload['lastSeq'], 100);
          }
          if (payload['type'] == 'session/event') {
            final ev = payload['event'] as Map<String, dynamic>;
            if (ev['type'] == 'assistant/text') {
              gotText.add(((ev['data'] as Map)['text'] as String));
              if (gotText.length >= 3) {
                streamDone.complete(true);
                return;
              }
            }
          }
        }
      }
    }();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final promptRes = await http.post(
      Uri.parse('$base/api/session.prompt'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({
        'type': 'client-request',
        'rpcId': 't2',
        'method': 'session.prompt',
        'payload': {'sessionId': 's1', 'mode': 'queue', 'content': [{'type': 'text', 'text': '测试流式'}]},
      }),
    );
    expect(promptRes.statusCode, 200);
    await sseFuture.timeout(const Duration(seconds: 10), onTimeout: () {
      fail('SSE 未在 10s 内收到 3 段 assistant/text 增量');
    });
    expect(streamDone.isCompleted, true);
  });
}
