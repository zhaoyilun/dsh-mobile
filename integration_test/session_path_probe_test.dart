// 会话路径探针：用 app 真实存储（KvStore 文件）复现 fromAccess → rpc 全路径，打印每步状态码/头部。
// 不走 UI；跑法：flutter test integration_test/session_path_probe_test.dart -d macos
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:http/http.dart' as http;
import 'package:dsh_mobile/federation/kv_store.dart';
import 'package:dsh_mobile/federation/pairings.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  test('session 路径探针', () async {
    const st = KvStore();
    final deviceId = await st.read(key: 'federation.deviceId');
    final deviceToken = await st.read(key: 'federation.deviceToken');
    final dshId = await st.read(key: 'federation.joinedDshId');
    // ignore: avoid_print
    print('P1 身份: $deviceId → dsh: $dshId');

    // 拉 pairings（与 FederationState.refreshPairings 同构）
    final registry = await st.read(key: 'federation.registryUrl') ?? 'https://dsh-api.example.com';
    final res = await http.get(
      Uri.parse('$registry/v1/me/pairings'),
      headers: {'x-dsh-device': deviceId ?? '', 'authorization': 'Bearer $deviceToken'},
    ).timeout(const Duration(seconds: 10));
    // ignore: avoid_print
    print('P2 me/pairings: HTTP ${res.statusCode}');
    final body = res.body;
    final pairings = body.contains('"pairings"')
        ? Pairing.listFromJson(jsonDecode(body) as Map<String, dynamic>)
        : const <Pairing>[];
    final access = pairings.isNotEmpty ? pairings.first.access : null;
    // ignore: avoid_print
    print('P3 access: lanUrl=${access?.lanUrl} publicUrl=${access?.publicUrl}');

    if (access == null) return;
    // 模拟 _exchange（禁重定向 + x-dc-pass）
    var cred = access.credential.trim();
    String? relayPass;
    if (cred.startsWith('{')) {
      final j = jsonDecode(cred) as Map<String, dynamic>;
      cred = (j['tokenUrl'] as String?) ?? '';
      relayPass = j['relayPass'] as String?;
    }
    final ex = await http.Client().send(http.Request('GET', Uri.parse(cred))
          ..followRedirects = false
          ..headers['x-dc-pass'] = relayPass ?? '')
        .timeout(const Duration(seconds: 10));
    final exRes = await http.Response.fromStream(ex);
    // ignore: avoid_print
    print('P4 exchange: HTTP ${exRes.statusCode} set-cookie=${(exRes.headers["set-cookie"] ?? "无").split(";").first}');
    final sc = exRes.headers['set-cookie'] ?? '';
    if (!sc.contains('dsh-auth')) {
      // ignore: avoid_print
      print('P4_FAIL 无 auth cookie: ${exRes.body.substring(0, exRes.body.length > 120 ? 120 : exRes.body.length)}');
      return;
    }
    final authCookie = sc
        .split(RegExp(r',\s*(?=[\w-]+=)'))
        .map((c) => c.split(';').first.trim())
        .firstWhere((c) => c.startsWith('dsh-auth'), orElse: () => '');
    // ignore: avoid_print
    print('P4.5 挑选: relay=${sc.split(';').first.split('=').first} auth=${authCookie.split('=').first}');
    final cookie = authCookie;
    // 模拟 _post
    for (final m in ['session.list']) {
      final r2 = await http.post(
        Uri.parse('${access.publicUrl}/api/$m'),
        headers: {
          'content-type': 'application/json',
          'cookie': cookie,
          if (relayPass != null) 'x-dc-pass': relayPass,
        },
        body: '{"type":"client-request","rpcId":"probe1","method":"$m","payload":{}}',
      ).timeout(const Duration(seconds: 10));
      // ignore: avoid_print
      print('P5 $m: HTTP ${r2.statusCode} body=${r2.body.length > 100 ? r2.body.substring(0, 100) : r2.body}');
    }
  });
}

