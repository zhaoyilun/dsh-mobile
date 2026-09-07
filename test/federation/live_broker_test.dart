// dsh-federation — 真实 broker 集成测试（mosquitto 在 127.0.0.1:1883 且本机已配对时自动执行）
// 验证 P0-1 修复的实际效果：FederationMqtt 对真实 broker 连接 + 订阅 reply/ack/presence 后，
// messages 流能真实收到 registry retained / presence（订阅生效的实战证明）。
// 依赖：~/Library/LaunchAgents 之外的本机 dev 服务（mosquitto + ~/.dsh/federation/device.json）
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/federation/mqtt_connection.dart';

Future<bool> _brokerUp() async {
  try {
    final socket = await Socket.connect('127.0.0.1', 1883, timeout: const Duration(seconds: 2));
    socket.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

Future<Map<String, dynamic>?> _device() async {
  final file = File('${Platform.environment['HOME']}/.dsh/federation/device.json');
  if (!file.existsSync()) return null;
  try {
    return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
}

void main() {
  test('真实 broker：连接 + registry/presence 订阅生效（mosquitto 离线时自动跳过）', () async {
    if (!await _brokerUp()) {
      markTestSkipped('mosquitto not reachable on 127.0.0.1:1883 — skip live broker test');
      return;
    }
    final dev = await _device();
    if (dev == null) {
      markTestSkipped('no ~/.dsh/federation/device.json — run scripts/pair-device.mjs first');
      return;
    }

    final mqtt = FederationMqtt(
      brokerUrl: 'mqtt://127.0.0.1:1883',
      deviceId: dev['deviceId'] as String,
      deviceToken: dev['deviceToken'] as String,
      name: 'flutter-test',
      kind: 'desktop',
      caps: const ['files'],
      clientIdOverride: 'live-test', // 用后缀避免与本机 bridge 的 clientId 冲突（ACL 按 %u=username 授权）
    );

    final connected = Completer<void>();
    final gotRegistry = Completer<dynamic>();
    final gotPresence = Completer<dynamic>();
    final sub = mqtt.messages.listen((entry) {
      if (entry.key == 'dsh/registry/' && !gotRegistry.isCompleted) gotRegistry.complete(entry.value);
      if (entry.key.endsWith('/presence') && !gotPresence.isCompleted) gotPresence.complete(entry.value);
    });
    mqtt.states.listen((s) {
      if (s.phase == FederationPhase.connected && !connected.isCompleted) connected.complete();
    });

    await mqtt.connect();
    await connected.future.timeout(const Duration(seconds: 10));

    // P0-1 修复证明：连接后（含 reply/ack/presence 订阅）应能收到 registry retained 与 presence
    final reg = await gotRegistry.future.timeout(const Duration(seconds: 8), onTimeout: () {
      throw StateError('未收到 dsh/registry/（订阅链路不通 —— P0-1 回归）');
    });
    expect((reg as Map)['devices'], isA<List>(), reason: 'registry retained 应含 devices');

    final pres = await gotPresence.future.timeout(const Duration(seconds: 8), onTimeout: () {
      throw StateError('未收到 presence（presence 订阅不通）');
    });
    expect(pres, isA<Map>());

    await mqtt.disconnect();
    await sub.cancel();
  }, timeout: const Timeout(Duration(seconds: 40)));
}
