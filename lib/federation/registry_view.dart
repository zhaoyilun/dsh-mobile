// dsh-federation — registry 视图：retained 全量解析 + 设备模型 + 在线状态合并
// 信任根说明：retained 快照本身未验签（协议待办），设备公钥（pubKeyOf，供 RPC
// reply 验签）从这里取——完整性目前依赖 broker ACL 限制 dsh/registry/# 只能由
// registry 服务发布；若 ACL 配置放宽，伪造快照即可冒充任意设备应答。
import 'dart:convert';

import 'package:flutter/foundation.dart';

class DeviceInfo {
  DeviceInfo({
    required this.deviceId,
    required this.name,
    required this.kind,
    required this.caps,
    this.pubKey,
    this.online = false,
    this.onlineTs,
  });

  final String deviceId;
  final String name;
  final String kind;
  final List<String> caps;
  final String? pubKey;
  bool online;
  int? onlineTs;

  bool get hasFiles => caps.contains('files');
  bool get hasAgent => caps.contains('agent');

  factory DeviceInfo.fromRegistry(Map<String, dynamic> json) => DeviceInfo(
        deviceId: json['deviceId'] as String? ?? '',
        name: json['name'] as String? ?? '?',
        kind: json['kind'] as String? ?? 'device',
        caps: (json['caps'] as List?)?.map((e) => e.toString()).toList() ?? const [],
        pubKey: json['pubKey'] as String?,
      );
}

class RegistrySnapshot {
  RegistrySnapshot({required this.seq, required this.generatedAt, required this.devices});

  final int seq;
  final int generatedAt;
  final List<DeviceInfo> devices;

  factory RegistrySnapshot.fromJson(Map<String, dynamic> json) => RegistrySnapshot(
        seq: json['seq'] as int? ?? 0,
        generatedAt: json['generatedAt'] as int? ?? 0,
        devices: (json['devices'] as List?)
                ?.map((e) => DeviceInfo.fromRegistry((e as Map).cast<String, dynamic>()))
                .toList() ??
            const [],
      );
}

/// 合并 registry（设备清单）与 presence（在线状态）的视图容器。
class FederationView extends ChangeNotifier {
  FederationView();

  final List<DeviceInfo> _devices = [];
  final Map<String, int> _presenceTs = {};
  bool _loaded = false;

  bool get loaded => _loaded;
  int get seq => _seq;
  int _seq = 0;

  List<DeviceInfo> get devices => List.unmodifiable(_devices);

  void applyRegistry(dynamic raw) {
    try {
      final map = raw is Map<String, dynamic> ? raw : (jsonDecode(raw.toString()) as Map<String, dynamic>);
      // 兼容两种形态：直接的全量对象，或 mqtt 信封 {type,payload}
      final body = (map['payload'] as Map?)?.cast<String, dynamic>() ?? map;
      final snap = RegistrySnapshot.fromJson(body);
      _seq = snap.seq;
      _devices
        ..clear()
        ..addAll(snap.devices);
      for (final d in _devices) {
        final ts = _presenceTs[d.deviceId];
        if (ts != null) {
          d.online = true;
          d.onlineTs = ts;
        }
      }
      _loaded = true;
      notifyListeners();
    } catch (_) {}
  }

  void applyPresence(String topic, dynamic raw) {
    final id = topic.split('/')[1];
    if (id.isEmpty) return;
    try {
      final j = raw is Map<String, dynamic> ? raw : (jsonDecode(raw.toString()) as Map<String, dynamic>);
      final online = j['online'] == true;
      final ts = j['ts'] as int?;
      if (online) {
        _presenceTs[id] = ts ?? DateTime.now().millisecondsSinceEpoch;
      } else {
        _presenceTs.remove(id);
      }
      for (final d in _devices) {
        if (d.deviceId == id) {
          d.online = online;
          d.onlineTs = ts ?? d.onlineTs;
        }
      }
      notifyListeners();
    } catch (_) {}
  }

  DeviceInfo? byId(String deviceId) {
    for (final d in _devices) {
      if (d.deviceId == deviceId) return d;
    }
    return null;
  }
}
