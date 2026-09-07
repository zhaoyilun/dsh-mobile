// dsh-federation — 配对边模型（PAIRING-SPEC §2 GET /v1/me/pairings 的 app 视角）
// 凭证按边分发：access 只出现在 app 视角且仅为其配对的 dsh；dsh 重新上线后需重拉刷新。
import 'registry_view.dart';

/// 一条「app 可操作 dsh」边的访问凭证（由 registry 按边下发）。
class PairingAccess {
  PairingAccess({this.lanUrl, required this.publicUrl, required this.credential});

  /// 局域网直连地址（如 http://192.168.3.40:3080），可空。
  final String? lanUrl;

  /// 公网可达地址（如 https://dsh.example.com）。
  final String publicUrl;

  /// 访问凭证：可直接拼接使用的值（tokenUrl 形如 `https://dsh.example.com/?token=xxx`，
  /// 或 `token=value` 形式），app 侧统一走 HostSession 的「GET 凭证（禁重定向）→ Set-Cookie」流程。
  final String credential;

  factory PairingAccess.fromJson(Map<String, dynamic> json) => PairingAccess(
        lanUrl: json['lanUrl'] as String?,
        publicUrl: json['publicUrl'] as String? ?? '',
        credential: json['credential'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        if (lanUrl != null) 'lanUrl': lanUrl,
        'publicUrl': publicUrl,
        'credential': credential,
      };
}

/// 一条配对边：目标 dsh + 其最新访问凭证。
class Pairing {
  Pairing({required this.id, required this.dsh, this.access});

  final String id;
  final DeviceInfo dsh;
  final PairingAccess? access;

  /// 解析 `{pairings:[{id, dsh:{deviceId,name,onlineHint}, access:{...}}]}`（app 视角）。
  static List<Pairing> listFromJson(Map<String, dynamic> body) {
    final raw = body['pairings'];
    if (raw is! List) return const [];
    return [
      for (final e in raw)
        if (e is Map)
          Pairing(
            id: e['id']?.toString() ?? '',
            dsh: DeviceInfo(
              deviceId: (e['dsh'] as Map?)?['deviceId']?.toString() ?? '',
              name: (e['dsh'] as Map?)?['name']?.toString() ?? 'dsh',
              kind: 'dsh',
              caps: const [],
            ),
            access: e['access'] is Map
                ? PairingAccess.fromJson((e['access'] as Map).cast<String, dynamic>())
                : null,
          ),
    ];
  }
}
