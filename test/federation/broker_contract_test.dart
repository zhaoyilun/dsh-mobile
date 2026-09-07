// dsh-federation — broker 契约单测（P0-1/P0-2/P0-5 回归防护）
// 1) FederationView 直接吃解析后的 Map（不再 toString+jsonDecode）
// 2) rpc_client 端到端：fake broker 回发签名 reply → OK；伪造签名 → E_UNAUTHORIZED
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/federation/device_identity.dart';
import 'package:dsh_mobile/federation/registry_view.dart';
import 'package:dsh_mobile/federation/rpc_client.dart';

/// fake broker：rpc_client 以 dynamic 方式访问 messages/publishJson
class _FakeBroker {
  _FakeBroker({required this.published}) {
    messages = _controller.stream;
  }
  final Map<String, Map<String, dynamic>> published;
  final StreamController<MapEntry<String, dynamic>> _controller = StreamController<MapEntry<String, dynamic>>.broadcast();
  late final Stream<MapEntry<String, dynamic>> messages;

  void reply(String topic, Map<String, dynamic> payload) => _controller.add(MapEntry(topic, payload));
  Future<void> close() => _controller.close();

  Future<void> publishJson(String topic, Map<String, dynamic> payload, {bool retain = false, int qos = 1}) async {
    published[topic] = payload;
  }
}

void main() {
  group('FederationView（P0-2 回归）', () {
    test('applyRegistry 接收 Map 并能列出设备', () {
      final view = FederationView();
      view.applyRegistry({
        'schemaVersion': 1,
        'seq': 4,
        'generatedAt': 1,
        'devices': [
          {'deviceId': 'dev_abc', 'name': 'Mac', 'kind': 'desktop', 'caps': ['agent', 'files'], 'pubKey': 'ed25519:x'}
        ],
      });
      expect(view.loaded, true);
      expect(view.devices.length, 1);
      expect(view.devices.first.deviceId, 'dev_abc');
      expect(view.devices.first.hasFiles, true);
    });

    test('applyPresence 接收 Map 并更新在线状态', () {
      final view = FederationView();
      view.applyRegistry({
        'seq': 1,
        'generatedAt': 1,
        'devices': [
          {'deviceId': 'dev_abc', 'name': 'Mac', 'kind': 'desktop', 'caps': [], 'pubKey': 'ed25519:x'}
        ],
      });
      view.applyPresence('dsh/dev_abc/presence', {'deviceId': 'dev_abc', 'online': true, 'ts': 1});
      expect(view.devices.first.online, true);
      view.applyPresence('dsh/dev_abc/presence', {'deviceId': 'dev_abc', 'online': false, 'ts': 2});
      expect(view.devices.first.online, false);
    });
  });

  group('FederationRpcClient（P0-5 回归）', () {
    test('签名 reply 被接受；伪造 reply 被拒', () async {
      final keys = await generateIdentityKeys();
      final targetKeys = await generateIdentityKeys();
      final identity = DeviceIdentity(
        deviceId: 'dev_caller',
        deviceToken: 'test-token-0123456789',
        name: 'caller',
        kind: 'phone',
        caps: const ['files'],
        privKeyB64: keys.privPkcs8B64,
      );

      // fake broker：记录发布消息 + 可回发 reply
      final published = <String, Map<String, dynamic>>{};
      final fakeMqtt = _FakeBroker(published: published);

      final rpc = FederationRpcClient(
        mqtt: fakeMqtt,
        identity: identity,
        pubKeyOf: (id) => id == 'dev_target' ? targetKeys.pubSpkiB64 : '',
      )..start();

      // 发起调用
      final callFuture = rpc.call('dev_target', 'device.ping', {});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final requestTopic = 'dsh/dev_target/api/device.ping/request';
      expect(published.containsKey(requestTopic), true, reason: 'request 必须被发布（P0-1 相关链路）');
      final request = published[requestTopic]!;
      final corrId = request['id'] as String;
      expect(request['sig'], startsWith('ed25519:'), reason: 'request 必须签名');

      // 1) fake broker 用目标私钥签合法 reply
      final replyOk = {
        'v': 1,
        'id': corrId,
        'frm': 'dev_target',
        'ts': DateTime.now().millisecondsSinceEpoch,
        'ok': true,
        'result': {'pong': 1},
      };
      final text = '${replyOk['v']}|${replyOk['id']}|${replyOk['frm']}|${replyOk['ts']}|${replyOk['ok']}|${jsonEncode(replyOk['result'])}';
      replyOk['sig'] = 'ed25519:${base64Url.encode(await ed25519Sign(targetKeys.privRaw, utf8.encode(text)))}';
      fakeMqtt.reply('dsh/dev_target/api/device.ping/reply/$corrId', replyOk);

      final result = await callFuture.timeout(const Duration(seconds: 3));
      expect(result.ok, true, reason: '合法签名 reply 应被接受');
      expect(result.value, {'pong': 1});

      // 2) 伪造 reply（签名用错误密钥）→ 必须拒绝
      final callFuture2 = rpc.call('dev_target', 'device.ping', {});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final request2 = published.entries.last.value;
      final corrId2 = request2['id'] as String;
      final evilKeys = await generateIdentityKeys();
      final replyEvil = {
        'v': 1,
        'id': corrId2,
        'frm': 'dev_target',
        'ts': DateTime.now().millisecondsSinceEpoch,
        'ok': true,
        'result': {'pong': 999},
      };
      final text2 = '${replyEvil['v']}|${replyEvil['id']}|${replyEvil['frm']}|${replyEvil['ts']}|${replyEvil['ok']}|${jsonEncode(replyEvil['result'])}';
      replyEvil['sig'] = 'ed25519:${base64Url.encode(await ed25519Sign(evilKeys.privRaw, utf8.encode(text2)))}';
      fakeMqtt.reply('dsh/dev_target/api/device.ping/reply/$corrId2', replyEvil);

      final result2 = await callFuture2.timeout(const Duration(seconds: 3));
      expect(result2.ok, false);
      expect(result2.code, 'E_UNAUTHORIZED', reason: '伪造签名 reply 必须被拒');

      await fakeMqtt.close();
      rpc.dispose();
    });
  });
}
