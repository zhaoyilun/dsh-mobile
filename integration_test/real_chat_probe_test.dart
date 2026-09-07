// 真实对话探针：新建会话 → 发消息 → SSE 收流式回复 → 入库（真实身份/云端路径/真实模型）
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:http/http.dart' as http;
import 'package:dsh_mobile/federation/kv_store.dart';
import 'package:dsh_mobile/federation/local_api.dart';
import 'package:dsh_mobile/federation/pairings.dart';
import 'package:dsh_mobile/federation/store/local_store.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  test('真实对话：create → prompt → SSE 流式回复', () async {
    final st = const KvStore();
    final deviceId = await st.read(key: 'federation.deviceId');
    final deviceToken = await st.read(key: 'federation.deviceToken');
    final dshId = await st.read(key: 'federation.joinedDshId') ?? '';

    final registry = await st.read(key: 'federation.registryUrl') ?? 'https://dsh-api.example.com';
    final res = await http.get(
      Uri.parse('$registry/v1/me/pairings'),
      headers: {'x-dsh-device': deviceId ?? '', 'authorization': 'Bearer $deviceToken'},
    ).timeout(const Duration(seconds: 10));
    final access = Pairing.listFromJson(jsonDecode(res.body) as Map<String, dynamic>).first.access!;
    final svc = HostSessionService(dshId: dshId, access: access);

    // 1) 新建会话
    final created = await svc.rpc('session.create', {});
    final sid = created['sessionId'] as String;
    // ignore: avoid_print
    print('D1 新会话: $sid');

    // 2) 先开 SSE（订阅到达前建立）
    final session = await HostSession.fromAccess(
      dshId: dshId, lanUrl: access.lanUrl, publicUrl: access.publicUrl, credential: access.credential);
    final frames = <Map<String, dynamic>>[];
    final subDone = Completer<void>();
    final gotText = Completer<void>();
      unawaited(() async {
      final client = http.Client();
      try {
        final req = http.Request('GET', Uri.parse('${session.baseUrl}/api/events.mux'))
          ..headers.addAll(session.headers);
        final streamed = await client.send(req).timeout(const Duration(seconds: 10));
        // ignore: avoid_print
        print('D2 SSE 已连接: HTTP ${streamed.statusCode}');
        final buf = StringBuffer();
        await for (final chunk in streamed.stream.transform(const Utf8Decoder(allowMalformed: true))) {
          buf.write(chunk);
          int idx;
          while ((idx = buf.toString().indexOf('\n\n')) >= 0) {
            final raw = buf.toString().substring(0, idx);
            buf.clear();
            final rest = raw;
            for (final line in rest.split('\n')) {
              if (line.startsWith('data: ')) {
                final payload = line.substring(6).trim();
                if (payload.isEmpty) continue;
                try {
                  final full = jsonDecode(payload);
                  if (full is Map && full['payload'] is Map) {
                    final f = (full['payload'] as Map).cast<String, dynamic>();
                    frames.add(f);
                    if (f['type'] == 'session/subscribed' && f['sessionId'] == sid && !subDone.isCompleted) {
                      subDone.complete();
                      // ignore: avoid_print
                      print('D3 已订阅新会话');
                    }
                    if (f['type'] == 'session/event' &&
                        f['sessionId'] == sid &&
                        (f['event'] as Map?)?['type'] == 'assistant/text' &&
                        !gotText.isCompleted) {
                      gotText.complete();
                    }
                  }
                } catch (_) {}
              }
            }
          }
        }
      } catch (_) {}
    }());

    // 3) 发消息（真实模型）
    final promptRes = await svc.rpc('session.prompt', {
      'sessionId': sid,
      'mode': 'queue',
      'content': [
        {'type': 'text', 'text': '请只回答两个字：收到'}
      ],
    });
    // ignore: avoid_print
    print('D4 prompt 已受理: ${promptRes['accepted']}');

    // 4) 等流式回复（最长 60s）
    await gotText.future.timeout(const Duration(seconds: 60), onTimeout: () {});
    final sid0 = sid;
    final assistantTexts = frames
        .where((f) => f['type'] == 'session/event' && f['sessionId'] == sid0)
        .map((f) => (f['event'] as Map)['type'] as String)
        .toList();
    // ignore: avoid_print
    print('D5 事件流: ${assistantTexts.take(20).toList()} 共 ${assistantTexts.length} 帧');

    // 5) 拉最终历史验证 + 入库
    final h = await svc.rpc('session.history', {'sessionId': sid, 'maxMessages': 20});
    final msgs = historyEntriesToMessages((h['events'] as List? ?? []), sessionId: sid, dshId: dshId);
    final store = StoreService(path: '/tmp/real-chat.db', singleInstance: false);
    await store.upsertMessages(dshId, sid, msgs);
    final back = await store.messages(sid);
    final userMsg = msgs.where((m) => m.role == 'user').length;
    final aiMsg = msgs.where((m) => m.role == 'assistant').length;
    // ignore: avoid_print
    print('D6 历史: user=$userMsg assistant=$aiMsg；入库读回 ${back.length} 条');

    expect(sid, isNotEmpty);
    expect(userMsg, greaterThan(0), reason: '应有用户消息');
    expect(aiMsg, greaterThan(0), reason: '应有助手回复');
    expect(back.length, msgs.length);
    try { File('/tmp/real-chat.db').deleteSync(); } catch (_) {}
  }, timeout: const Timeout(Duration(seconds: 150)));
}
