// dsh-federation — MQTT 连接封装（mqtt_client 10.x）：LWT/presence/重连/订阅
// 客户端实例由 mqtt_client_factory 条件创建：IO 走 MqttServerClient（TCP/WebSocket），
// Web 走 MqttBrowserClient（仅 WebSocket）。
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:typed_data/typed_data.dart' as td;

import 'mqtt_client_factory.dart' if (dart.library.html) 'mqtt_client_factory_web.dart';

enum FederationPhase { idle, connecting, connected, reconnecting, error, closed }

class FederationPhaseState {
  const FederationPhaseState(this.phase, [this.message]);
  final FederationPhase phase;
  final String? message;
}

class BrokerUri {
  BrokerUri(this.raw) {
    final u = Uri.parse(raw);
    useWebSocket = u.scheme == 'wss' || u.scheme == 'ws';
    secure = (u.scheme == 'wss' || u.scheme == 'mqtts' || u.scheme == 'ssl');
    host = u.host;
    path = u.path.isEmpty ? '/mqtt' : u.path;
    port = u.hasPort
        ? u.port
        : (useWebSocket ? (secure ? 443 : 8083) : (secure ? 8883 : 1883));
  }

  final String raw;
  late final bool useWebSocket;
  late final bool secure;
  late final String host;
  late final String path;
  late final int port;

  @override
  String toString() => raw;
}

class FederationMqtt {
  FederationMqtt({
    required this.brokerUrl,
    required this.deviceId,
    required this.deviceToken,
    required this.name,
    required this.kind,
    required this.caps,
    this.clientIdOverride,
  });

  final String brokerUrl;
  final String deviceId;
  final String deviceToken;
  final String name;
  final String kind;
  final List<String> caps;

  /// 可选：MqttClient-ID 覆盖（测试/多实例共用凭据时加后缀区分；
  /// 身份认证与 ACL 以 username=deviceId 为准 —— dev mosquitto ACL 用 %u）
  final String? clientIdOverride;

  MqttClient? _client;
  final StreamController<FederationPhaseState> _state = StreamController.broadcast();
  final StreamController<MapEntry<String, dynamic>> _messages = StreamController.broadcast();

  String get presenceTopic => 'dsh/$deviceId/presence';
  Stream<FederationPhaseState> get states => _state.stream;
  Stream<MapEntry<String, dynamic>> get messages => _messages.stream;

  Future<void> connect() async {
    final uri = BrokerUri(brokerUrl);
    // websocket 模式下 mqtt_client 要求 server 为完整 ws/wss URI（scheme 携带 TLS 与路径）；
    // TCP 模式则必须是裸 host（浏览器端只支持 websocket 模式）。
    final server = uri.useWebSocket ? uri.raw : uri.host;
    final MqttClient client;
    try {
      client = createMqttClient(
        server: server,
        clientId: clientIdOverride ?? deviceId,
        port: uri.port,
        useWebSocket: uri.useWebSocket,
      );
    } catch (e) {
      // 典型：浏览器端配了非 WebSocket 的 broker 地址
      _state.add(FederationPhaseState(FederationPhase.error, e.toString()));
      return;
    }
    client.logging(on: false);
    client.keepAlivePeriod = 30;
    client.connectTimeoutPeriod = 10000;
    client.autoReconnect = true;
    client.resubscribeOnAutoReconnect = true;
    client.onAutoReconnect = () => _state.add(const FederationPhaseState(FederationPhase.reconnecting));
    client.onAutoReconnected = () => _state.add(const FederationPhaseState(FederationPhase.connected));

    // LWT + 认证：一次性配置连接消息（will 异常断线由 broker 代发 offline）
    final willPayload = jsonEncode({
      'deviceId': deviceId,
      'online': false,
      'ts': DateTime.now().millisecondsSinceEpoch,
      'reason': 'lwt',
    });
    client.connectionMessage = MqttConnectMessage()
        .withClientIdentifier(deviceId)
        .authenticateAs(deviceId, deviceToken)
        .withWillTopic(presenceTopic)
        .withWillMessage(willPayload)
        .withWillQos(MqttQos.atLeastOnce)
        .withWillRetain()
        .startClean();

    _client = client;
    // 注意：updates 监听必须放在 connect() 成功**之后**——mqtt_client 的 updates getter
    // 依赖 subscriptionsManager（connect 时才创建），连接前 listen 会静默落空（实测断链根因）。
    _state.add(const FederationPhaseState(FederationPhase.connecting));
    try {
      // 连接超时防护：mqtt_client（尤其 Web 的 BrowserClient）对不可达 broker
      // 可能挂起不返回，会卡死 init 链（后续 pairings 拉取全被阻塞）。
      await client.connect().timeout(
        const Duration(seconds: 12),
        onTimeout: () => throw TimeoutException('mqtt connect 12s 超时（broker 不可达？）'),
      );
      final status = client.connectionStatus;
      if (status == null || status.state != MqttConnectionState.connected) {
        _state.add(FederationPhaseState(FederationPhase.error, status?.state.toString()));
        return;
      }
    } catch (e) {
      _state.add(FederationPhaseState(FederationPhase.error, e.toString()));
      return;
    }

    client.updates?.listen((List<MqttReceivedMessage<MqttMessage>> msgs) {
      for (final m in msgs) {
        final topic = m.topic;
        final text = utf8.decode((m.payload as MqttPublishMessage).payload.message);
        try {
          _messages.add(MapEntry(topic, jsonDecode(text)));
        } catch (_) {
          _messages.add(MapEntry(topic, text));
        }
      }
    });

    _state.add(const FederationPhaseState(FederationPhase.connected));

    await publishJson(
      presenceTopic,
      {
        'deviceId': deviceId,
        'online': true,
        'ts': DateTime.now().millisecondsSinceEpoch,
        'name': name,
        'kind': kind,
        'caps': caps,
        'info': {'platform': 'flutter'},
      },
      retain: true,
    );
    // registry 订阅（retained 全量 + token 表）+ RPC 应答/在线状态
    // 注意：客户端自身命名空间（dsh/<deviceId>/#）的订阅不在这里——presence 自读、
    // 自身请求等由 federation_state 按 topic 前缀处理；RPC reply/ack 必须在连接时就订阅，
    // 否则 rpc_client 永远等不到答复（P0-1 修复）。
    await subscribe('dsh/registry/#');
    await subscribe('dsh/+/api/+/reply/#');
    await subscribe('dsh/+/api/+/ack/#');
    await subscribe('dsh/+/presence');
  }

  Future<void> subscribe(String topicFilter) async {
    final client = _client;
    if (client == null) return;
    try {
      // mqtt_client 的 subscribe 同步发起订阅（返回 Subscription?），无需 await
      client.subscribe(topicFilter, MqttQos.atLeastOnce);
    } catch (e) {
      // 订阅失败会让 registry/RPC 应答悄悄丢失，必须留痕。
      debugPrint('[federation] subscribe 失败 $topicFilter: $e');
    }
  }

  Future<void> publishJson(String topic, Map<String, dynamic> payload, {bool retain = false, int qos = 1}) async {
    final data = td.Uint8Buffer()..addAll(utf8.encode(jsonEncode(payload)));
    try {
      _client?.publishMessage(topic, MqttQos.values[qos.clamp(0, 2)], data, retain: retain);
    } catch (e) {
      // 发布失败时调用方（如 RPC）只能等超时，这里留痕帮助定位。
      debugPrint('[federation] publish 失败 $topic: $e');
      rethrow;
    }
  }

  Future<void> publishRaw(String topic, List<int> payload, {bool retain = false, int qos = 1}) async {
    final data = td.Uint8Buffer()..addAll(payload);
    try {
      _client?.publishMessage(topic, MqttQos.values[qos.clamp(0, 2)], data, retain: retain);
    } catch (e) {
      debugPrint('[federation] publishRaw 失败 $topic: $e');
      rethrow;
    }
  }

  Future<void> disconnect() async {
    try {
      await publishJson(
        presenceTopic,
        {
          'deviceId': deviceId,
          'online': false,
          'ts': DateTime.now().millisecondsSinceEpoch,
          'reason': 'graceful',
        },
        retain: true,
      );
    } catch (_) {}
    try {
      _client?.disconnect();
    } catch (_) {}
    _state.add(const FederationPhaseState(FederationPhase.closed));
  }
}
