// 聊天数据流探针：复现 chat 页 loadLocal → loadRemote → 归一化 → extractText 全链（真实身份/平台）
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
  test('聊天数据流探针', () async {
    final st = const KvStore();
    final deviceId = await st.read(key: 'federation.deviceId');
    final deviceToken = await st.read(key: 'federation.deviceToken');
    final dshId = await st.read(key: 'federation.joinedDshId') ?? '';

    // 1) 本地库已有消息？（app 之前打开过聊天页的话应有）
    final store = StoreService(path: '/tmp/chat-probe.db', singleInstance: false);
    final local = await store.messages('session-285f2eb2-3668-431e-84e9-556f093832cf');
    // ignore: avoid_print
    print('C1 本地库消息: ${local.length} 条（新库应为 0）');

    // 2) 走 app 真实 rpc 链路
    final registry = await st.read(key: 'federation.registryUrl') ?? 'https://dsh-api.example.com';
    final res = await http.get(
      Uri.parse('$registry/v1/me/pairings'),
      headers: {'x-dsh-device': deviceId ?? '', 'authorization': 'Bearer $deviceToken'},
    ).timeout(const Duration(seconds: 10));
    final access = Pairing.listFromJson(jsonDecode(res.body) as Map<String, dynamic>).first.access!;
    await HostSession.fromAccess(
      dshId: dshId, lanUrl: access.lanUrl, publicUrl: access.publicUrl, credential: access.credential);
    // ignore: unused_local_variable
    final svc = HostSessionService(dshId: dshId, access: access);
    final value = await svc.rpc('session.history', {'sessionId': 'session-285f2eb2-3668-431e-84e9-556f093832cf', 'maxMessages': 50});
    // ignore: avoid_print
    print('C2 history keys: ${value.keys.toList()}，events=${(value["events"] as List?)?.length}');

    // 3) 归一化 + 提取（chat 页同款逻辑）
    final raw = value['events'] as List? ?? [];
    final msgs = historyEntriesToMessages(raw, sessionId: 's', dshId: dshId);
    // ignore: avoid_print
    print('C3 归一化消息: ${msgs.length} 条，角色分布: ${<String, int>{}..addAll({for (final m in msgs) m.role: (msgs.where((x) => x.role == m.role).length)})}');
    int shown = 0;
    for (final m in msgs) {
      final content = jsonDecode(m.contentJson) as Map<String, dynamic>;
      final message = content['message'] as Map<String, dynamic>? ?? {};
      final c = message['content'];
      if (c is String) { shown++; continue; }
      if (c is List && c.any((p) => p is Map && (p['text'] is String))) { shown++; }
    }
    // ignore: avoid_print
    print('C4 extractText 可出文本的消息: $shown/${msgs.length}');
    try { File('/tmp/chat-probe.db').deleteSync(); } catch (_) {}
  });
}
