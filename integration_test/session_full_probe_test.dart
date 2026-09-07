// 会话全链数据层探针：身份 → pairings → 凭证 → session.list → 本地库写入 → 读回（真实桌面平台）
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
  test('会话全链（含桌面本地库）', () async {
    final st = const KvStore();
    final deviceId = await st.read(key: 'federation.deviceId');
    final deviceToken = await st.read(key: 'federation.deviceToken');
    final dshId = await st.read(key: 'federation.joinedDshId') ?? '';

    final registry = await st.read(key: 'federation.registryUrl') ?? 'https://dsh-api.example.com';
    final res = await http.get(
      Uri.parse('$registry/v1/me/pairings'),
      headers: {'x-dsh-device': deviceId ?? '', 'authorization': 'Bearer $deviceToken'},
    ).timeout(const Duration(seconds: 10));
    final pairings = Pairing.listFromJson(jsonDecode(res.body) as Map<String, dynamic>);
    final access = pairings.first.access!;
    // ignore: avoid_print
    print('F1 pairings: ${pairings.length} 条，publicUrl=${access.publicUrl}');

    // 真实桌面本地库（FFI 工厂）——文件放临时目录避免污染
    final store = StoreService(path: '/tmp/probe-store.db', singleInstance: false);

    // HostSession 走云端路径
    final session = await HostSession.fromAccess(
      dshId: dshId,
      lanUrl: access.lanUrl,
      publicUrl: access.publicUrl,
      credential: access.credential,
    );
    // 直接用 fromAccess 的 session 发 RPC（复用 local_api 私有路径的等价逻辑）
    final r = await http.post(
      Uri.parse('${session.baseUrl}/api/session.list'),
      headers: {'content-type': 'application/json', ...session.headers},
      body: jsonEncode({'type': 'client-request', 'rpcId': 'probeF', 'method': 'session.list', 'payload': <String, dynamic>{}}),
    ).timeout(const Duration(seconds: 15));
    final body = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    final value = (body['result'] as Map<String, dynamic>?)?['value'] as Map<String, dynamic>?;
    final items = (value?['items'] ?? value?['sessions']) as List? ?? [];
    // ignore: avoid_print
    print('F2 session.list: HTTP ${r.statusCode}，会话 ${items.length} 个');

    // 入库 + 读回
    final stored = <StoredSession>[
      for (final it in items)
        if (it is Map)
          StoredSession(
            id: it['sessionId']?.toString() ?? '',
            dshId: dshId,
            title: ((it['projections'] as Map?)?['title'] ?? it['sessionId'])?.toString() ?? '',
            updatedAt: (it['updatedAt'] as num?)?.toInt() ?? 0,
          ),
    ];
    await store.upsertSessions(dshId, stored);
    final readBack = await store.sessions(dshId);
    // ignore: avoid_print
    print('F3 本地库: 写入 ${stored.length} → 读回 ${readBack.length}，最新「${readBack.isEmpty ? '-' : readBack.first.title}」');

    expect(r.statusCode, 200);
    expect(items.length, greaterThan(0));
    expect(readBack.length, stored.length);
    try { File('/tmp/probe-store.db').deleteSync(); } catch (_) {}
  });
}
