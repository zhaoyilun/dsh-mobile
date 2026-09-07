// dsh-federation — 全局状态单例：身份 + MQTT + registry 视图 + 配对边 + RPC 生命周期
// 冷启动接线（PAIRING-SPEC §5）：init() 恢复身份/连接设置/joinedDsh 快照 → 连 MQTT → 拉 pairings。
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'kv_store.dart';
import 'device_identity.dart';
import 'http_client_factory.dart' if (dart.library.html) 'http_client_factory_web.dart';
import 'local_api.dart';
import 'mqtt_connection.dart';
import 'pairings.dart';
import 'registry_view.dart';
import 'rpc_client.dart';

class FederationState extends ChangeNotifier {
  FederationState._();
  static final FederationState instance = FederationState._();

  static const _kBrokerUrl = 'federation.brokerUrl';
  static const _kRegistryUrl = 'federation.registryUrl';
  static const _kJoinedDshId = 'federation.joinedDshId';
  static const _kJoinedDshName = 'federation.joinedDshName';

  DeviceIdentity? identity;
  FederationMqtt? mqtt;
  FederationRpcClient? rpc;
  final FederationView view = FederationView();

  FederationPhase phase = FederationPhase.idle;
  String? phaseMessage;

  // P1-1：连接目标可配置。Phase 2.5 起默认云端（装机即用）；本地联调在设置卡片改回 127.0.0.1。
  String registryBaseUrl = 'https://dsh-api.example.com';
  String brokerUrl = 'wss://dsh-mqtt.example.com/mqtt';

  /// 配对边（GET /v1/me/pairings，含目标 dsh 的访问凭证）。
  List<Pairing> pairings = [];

  /// 当前操作目标 dsh（join 时的快照恢复 + 列表页顶栏可切换）。
  DeviceInfo? joinedDsh;

  DateTime? _lastPairingsRefresh;

  /// 初连失败的指数退避重连（2/4/8/16/32/60s 封顶）。
  /// mqtt_client 的 autoReconnect 只覆盖「连上之后断线」；弱网冷启动、
  /// 飞行模式恢复等初连失败场景由这里兜底。连上即清零，手动 connect 也重置。
  Timer? _reconnectTimer;
  int _connectAttempts = 0;
  static const List<int> _reconnectDelays = [2, 4, 8, 16, 32, 60];

  /// 冷启动接线：恢复连接设置/身份/joinedDsh 快照 → 连接 MQTT（连接成功后自动拉 pairings）。
  /// 在首页 initState 调用（main 里 runApp 前亦可，这里选不阻塞首帧的安全时机）。
  Future<void> init() async {
    await loadConnectionSettings();
    identity = await IdentityStore().load();
    notifyListeners();
    if (identity == null || !identity!.complete) return;
    await connect();
  }

  Future<void> loadConnectionSettings() async {
    final st = KvStore();
    final broker = await st.read(key: _kBrokerUrl);
    final registry = await st.read(key: _kRegistryUrl);
    if (broker != null && broker.isNotEmpty) brokerUrl = broker;
    if (registry != null && registry.isNotEmpty) registryBaseUrl = registry;
    // joinedDsh 快照（join 时写入；pairings 刷新后会校正 name/在线状态）
    final dshId = await st.read(key: _kJoinedDshId);
    final dshName = await st.read(key: _kJoinedDshName);
    if (dshId != null && dshId.isNotEmpty) {
      joinedDsh = DeviceInfo(deviceId: dshId, name: dshName ?? 'dsh', kind: 'dsh', caps: const []);
    }
  }

  Future<void> saveConnectionSettings({String? broker, String? registry}) async {
    final st = KvStore();
    if (broker != null && broker.isNotEmpty) {
      brokerUrl = broker;
      await st.write(key: _kBrokerUrl, value: broker);
    }
    if (registry != null && registry.isNotEmpty) {
      registryBaseUrl = registry;
      await st.write(key: _kRegistryUrl, value: registry);
    }
    notifyListeners();
  }

  /// 切换操作目标 dsh（列表页顶栏入口）；持久化快照，冷启动恢复。
  Future<void> selectJoinedDsh(DeviceInfo dsh) async {
    joinedDsh = dsh;
    final st = KvStore();
    await st.write(key: _kJoinedDshId, value: dsh.deviceId);
    await st.write(key: _kJoinedDshName, value: dsh.name);
    notifyListeners();
  }

  /// 拉取配对边（设备令牌认证）：凭证新鲜度的唯一同步机制（PAIRING-SPEC §3）。
  /// 连接成功后自动调用；配对的 dsh presence 重新上线时也会触发（带 5s 节流）。
  Future<void> refreshPairings() async {
    final id = identity;
    if (id == null || !id.complete) return;
    try {
      // 走工厂 client（Web 上 XHR 版）：http.get 静态方法在 Web 是 fetch 实现，
      // 既有 CORS 错误文案混淆，也有已知的手势副作用（见 xhr_client.dart）。
      final client = createHttpClient();
      late http.Response res;
      try {
        res = await client
            .get(
              Uri.parse('$registryBaseUrl/v1/me/pairings'),
              headers: {
                'x-dsh-device': id.deviceId,
                'authorization': 'Bearer ${id.deviceToken}',
              },
            )
            .timeout(const Duration(seconds: 10));
      } finally {
        client.close();
      }
      if (res.statusCode != 200) throw Exception('http ${res.statusCode}');
      final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      pairings = Pairing.listFromJson(j);
      // 校正 joinedDsh：名称以 registry 为准；边被吊销（不在列表）则清空目标。
      final current = joinedDsh;
      if (current != null) {
        final match = pairings.where((p) => p.dsh.deviceId == current.deviceId).toList();
        if (match.isEmpty) {
          joinedDsh = null;
          final st = KvStore();
          await st.delete(key: _kJoinedDshId);
          await st.delete(key: _kJoinedDshName);
        } else if (match.first.dsh.name != current.name) {
          await selectJoinedDsh(match.first.dsh);
        }
      }
      _lastPairingsRefresh = DateTime.now();
      notifyListeners();
    } catch (e) {
      debugPrint('[federation] refreshPairings 失败: $e');
    }
  }

  /// 目标 dsh 的最新访问凭证（无则需先刷新 pairings）。
  PairingAccess? accessFor(String dshId) {
    for (final p in pairings) {
      if (p.dsh.deviceId == dshId) return p.access;
    }
    return null;
  }

  /// 当前 joinedDsh 的 host API 入口（会话/聊天页共用）。
  HostSessionService? hostApi() {
    final dsh = joinedDsh;
    if (dsh == null) return null;
    return HostSessionService(dshId: dsh.deviceId, access: accessFor(dsh.deviceId));
  }

  Future<void> connect() async {
    final id = identity;
    if (id == null) return;
    _reconnectTimer?.cancel();
    await disconnect();
    mqtt = FederationMqtt(
      brokerUrl: brokerUrl,
      deviceId: id.deviceId,
      deviceToken: id.deviceToken,
      name: id.name,
      kind: id.kind,
      caps: id.caps,
    );
    mqtt!.states.listen((s) {
      phase = s.phase;
      phaseMessage = s.message;
      notifyListeners();
      // FederationMqtt.connect 内部吞掉连接异常只发 error 状态（外层 try/catch
      // 捕不到），初连失败的自动重试必须挂在这里。
      if (s.phase == FederationPhase.error) {
        _scheduleReconnect();
      } else if (s.phase == FederationPhase.connected) {
        _connectAttempts = 0;
        _reconnectTimer?.cancel();
      }
    });
    if (mqtt != null) {
      rpc = FederationRpcClient(
        mqtt: mqtt!,
        identity: id,
        // P0-5：reply 验签所需的对方公钥（registry 缓存）
        pubKeyOf: (deviceId) => view.byId(deviceId)?.pubKey ?? '',
      )..start();
      mqtt!.messages.listen((entry) {
        if (entry.key == 'dsh/registry/') {
          view.applyRegistry(entry.value); // value 已是解析后的 Map（勿再 toString+jsonDecode）
        } else if (entry.key.startsWith('dsh/')) {
          final parts = entry.key.split('/');
          if (parts.length >= 3 && parts[2] == 'presence') {
            view.applyPresence(entry.key, entry.value);
            _onPresence(parts[1], entry.value);
          }
        }
      });
    }
    try {
      await mqtt!.connect();
    } catch (e) {
      phase = FederationPhase.error;
      phaseMessage = e.toString();
    }
    // 凭证刷新与 MQTT 解耦：无论连接成败都拉一次（配对边/凭证由 registry 决定；
    // MQTT 不可达（如浏览器 WSS 被代理剪断）时凭证照样要能刷新，否则列表页「无配对凭证」）。
    unawaited(refreshPairings());
    notifyListeners();
  }

  /// 配对的 dsh 重新上线 → 重拉 pairings（凭证可能已刷新；PAIRING-SPEC §3 唯一同步机制）。
  void _onPresence(String deviceId, dynamic raw) {
    final online = raw is Map && raw['online'] == true;
    if (!online) return;
    final isPaired = pairings.any((p) => p.dsh.deviceId == deviceId) || joinedDsh?.deviceId == deviceId;
    if (!isPaired) return;
    final last = _lastPairingsRefresh;
    if (last != null && DateTime.now().difference(last) < const Duration(seconds: 5)) return; // 节流
    unawaited(refreshPairings());
  }

  void _scheduleReconnect() {
    if (identity == null) return; // 已退出联邦：不再重试
    _reconnectTimer?.cancel();
    final seconds = _reconnectDelays[_connectAttempts < _reconnectDelays.length
        ? _connectAttempts
        : _reconnectDelays.length - 1];
    _connectAttempts++;
    debugPrint('[federation] 连接失败，${seconds}s 后第 $_connectAttempts 次重连');
    _reconnectTimer = Timer(Duration(seconds: seconds), () {
      if (identity != null) unawaited(connect());
    });
  }

  Future<void> disconnect() async {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await mqtt?.disconnect();
    mqtt = null;
    rpc?.dispose();
    rpc = null;
    phase = FederationPhase.closed;
    notifyListeners();
  }

  Future<void> adoptIdentity(DeviceIdentity id) async {
    identity = id;
    notifyListeners();
    await connect();
  }

  Future<void> clearIdentity() async {
    await IdentityStore().clear();
    await disconnect();
    identity = null;
    joinedDsh = null;
    pairings = const [];
    final st = KvStore();
    await st.delete(key: _kJoinedDshId);
    await st.delete(key: _kJoinedDshName);
    notifyListeners();
  }
}
