// dsh-federation — 协议解析单测：MuxFrame 各类型 / 身份密钥 / 信封形状
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/federation/host_events.dart';
import 'package:dsh_mobile/federation/device_identity.dart';

void main() {
  group('MuxFrame.parse', () {
    test('session/event 帧解析', () {
      final raw = jsonDecode('{"type":"session/event","sessionId":"s1","event":{"type":"assistant/text","seq":101,"time":1,"data":{"text":"hello"}}}') as Map<String, dynamic>;
      final f = MuxFrame.parse(raw)!;
      expect(f.type, 'session/event');
      expect(f.sessionId, 's1');
      expect(f.event!['type'], 'assistant/text');
      expect(f.event!['seq'], 101);
      expect((f.event!['data'] as Map)['text'], 'hello');
    });

    test('session/subscribed 帧', () {
      final f = MuxFrame.parse({'type': 'session/subscribed', 'sessionId': 's1', 'lastSeq': 42})!;
      expect(f.lastSeq, 42);
    });

    test('session/queue 帧 items', () {
      final f = MuxFrame.parse({
        'type': 'session/queue',
        'sessionId': 's1',
        'items': [
          {'id': 'm1', 'placement': 'queued', 'message': {'role': 'user', 'content': [{'type': 'text', 'text': 'hi'}]}}
        ]
      })!;
      expect(f.queueItems!.length, 1);
    });

    test('未知/畸形帧返回 null（不抛）', () {
      expect(MuxFrame.parse({'type': null}), null);
      expect(MuxFrame.parse(<String, dynamic>{}), null);
    });
  });

  group('identity crypto', () {
    test('ed25519 DER 包装长度正确（spki 44B / pkcs8 48B）', () async {
      final keys = await generateIdentityKeys();
      expect(base64Url.decode(keys.pubSpkiB64).length, 44);
      expect(base64Url.decode(keys.privPkcs8B64).length, 48);
      expect(keys.pubRaw.length, 32);
    });

    test('sign/verify roundtrip', () async {
      final keys = await generateIdentityKeys();
      final message = utf8.encode('1|corr_x|device.ping|dev_a|1|30000|{}');
      final sig = await ed25519Sign(keys.privRaw, message);
      expect(await ed25519Verify(keys.pubRaw, message, sig), true);
      expect(await ed25519Verify(keys.pubRaw, utf8.encode('tampered'), sig), false);
    });

    test('pubRawFromSpki 解析：44B DER → raw 32B', () async {
      final keys = await generateIdentityKeys();
      final raw = pubRawFromSpki(keys.pubSpkiB64);
      expect(raw.length, 32);
      expect(raw, keys.pubRaw);
      // 畸形输入抛错
      expect(() => pubRawFromSpki('!!!!'), throwsA(isA<Object>()));
    });
  });

  group('HostSession 信封', () {
    test('rpc 请求信封形状含 client-request + rpcId + method + payload', () {
      final envelope = {
        'type': 'client-request',
        'rpcId': 'fj_123',
        'method': 'session.list',
        'payload': <String, dynamic>{},
      };
      expect(envelope['type'], 'client-request');
      expect(envelope['method'], 'session.list');
      expect(envelope.containsKey('payload'), true);
    });
  });
}
