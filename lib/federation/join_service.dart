// dsh-federation — 配对加入服务（PAIRING-SPEC §2 POST /v1/pairing/join + §5 首屏唯一动作）
// 用户层三样：根地址 + 配对码 + 设备名。密钥对本机生成，公钥随 join 上传；
// 成功后身份（IdentityStore）+ 根地址/broker/joinedDsh 快照（secure storage）全部落盘。
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'http_client_factory.dart' if (dart.library.html) 'http_client_factory_web.dart';
import 'kv_store.dart';
import 'device_identity.dart';
import 'registry_view.dart';

/// join 成功产物：app 身份 + 配对到的 dsh + registry 下发的 endpoints。
class JoinResult {
  JoinResult({required this.identity, required this.dsh, required this.registryUrl, required this.brokerUrl});

  final DeviceIdentity identity;
  final DeviceInfo dsh;
  final String registryUrl;
  final String brokerUrl;
}

class JoinService {
  JoinService({required this.rootAddress});

  /// 用户输入的根地址（如 example.com 或完整 https://dsh-api.example.com）。
  final String rootAddress;

  static const _kRootAddr = 'federation.rootAddr';
  static const _kJoinedDshId = 'federation.joinedDshId';
  static const _kJoinedDshName = 'federation.joinedDshName';
  // registryUrl / brokerUrl 由 FederationState.saveConnectionSettings 统一管理，
  // 这里只补根地址与 joinedDsh 快照两块。

  /// Web 端同源提示（部署形态：静态站与 API 同源，registry 挂 /reg 路径）。
  static String _webOriginHint() {
    return 'http://127.0.0.1:8123'; // 与 tool/web_origin_proxy.mjs 的默认端口一致
  }

  /// 根地址 → registry api 基址派生规则（PAIRING-SPEC §5）：
  /// - 无 scheme（裸域名）→ 补 `https://dsh-api.` 前缀（example.com → https://dsh-api.example.com）；
  /// - 有 scheme 且 host 以 `dsh-api.` 开头 → 原样使用；
  /// - 有 scheme、host 不带 `dsh-api.` 且无路径 → 裸域名同样派生前缀（http://example.com → https://dsh-api.example.com）；
  /// - 有路径（完整 api 地址，如 https://dsh-api.example.com/v1 或自建反代）→ 原样使用；
  /// - IP / localhost（本地联调，派生无意义）→ 原样使用。
  static String deriveApiBaseUrl(String input) {
    final s = input.trim().replaceAll(RegExp(r'/+$'), ''); // 去首尾空白与尾部斜杠
    if (s.isEmpty) throw const FormatException('根地址为空');
    final uri = Uri.tryParse(s);
    final hasScheme = uri != null && (uri.scheme == 'https' || uri.scheme == 'http') && uri.host.isNotEmpty;
    if (!hasScheme) {
      return 'https://dsh-api.$s';
    }
    final hasPath = uri.path.isNotEmpty && uri.path != '/';
    if (hasPath) return s; // 完整 api 地址：原样使用
    if (uri.host.startsWith('dsh-api.')) return s;
    final bareDomain = !uri.host.startsWith(RegExp(r'\d')) && uri.host != 'localhost' && !uri.host.contains(':');
    if (bareDomain) return 'https://dsh-api.${uri.host}';
    return s; // IP/localhost：原样使用
  }

  /// 凭配对码加入联邦：生成密钥对 → join →（deviceId+deviceToken 只在响应出现一次）落盘身份。
  Future<JoinResult> join({required String code, required String name}) async {
    final api = deriveApiBaseUrl(rootAddress);
    final keys = await generateIdentityKeys();
    // 注意：必须走工厂 client（Web 上是 XHR 版）——http.post 静态方法在 Web 上
    // 用 fetch 实现，既是 CORS 错误文案混淆源，也有已知的手势副作用。
    final client = createHttpClient();
    late http.Response res;
    try {
      res = await client
          .post(
            Uri.parse('$api/v1/pairing/join'),
            headers: {'content-type': 'application/json'},
            body: jsonEncode({
              'code': code.trim(),
              'devicePubKey': 'ed25519:${keys.pubSpkiB64}',
              'name': name,
            }),
          )
          .timeout(const Duration(seconds: 15));
    } on http.ClientException {
      if (kIsWeb) {
        // 云端已开放 CORS（Caddy 层回显 Origin + credentials），直连即达；
        // 仍失败（网络/代理拦截）才提示改走同源代理入口。
        throw Exception('加入失败：浏览器无法直连 $api（网络或跨域受限）。\n'
            '可改用同源代理入口，例如 ${_webOriginHint()}/reg');
      }
      rethrow;
    } finally {
      client.close();
    }
    if (res.statusCode == 401) throw Exception('配对码无效或已过期（401）');
    if (res.statusCode != 200) throw Exception('加入失败: ${res.statusCode} ${utf8.decode(res.bodyBytes)}');

    final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final deviceId = j['deviceId'] as String? ?? '';
    final deviceToken = j['deviceToken'] as String? ?? '';
    final dshRaw = j['dsh'] as Map?;
    final endpoints = (j['endpoints'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
    final registryUrl = endpoints['registryUrl'] as String? ?? api;
    final brokerUrl = endpoints['brokerUrl'] as String? ?? '';
    final dsh = DeviceInfo(
      deviceId: dshRaw?['deviceId']?.toString() ?? '',
      name: dshRaw?['name']?.toString() ?? 'dsh',
      kind: 'dsh',
      caps: const [],
    );
    if (deviceId.isEmpty || deviceToken.isEmpty || dsh.deviceId.isEmpty) {
      throw Exception('join 响应缺少 deviceId/deviceToken/dsh');
    }

    // 身份（kind=app，PAIRING-SPEC §2：join 签发 app 身份，caps=["files"]）
    await IdentityStore().save(
      deviceId: deviceId,
      deviceToken: deviceToken,
      name: name,
      kind: 'app',
      caps: const ['files'],
      privKeyPkcs8B64: keys.privPkcs8B64,
    );

    // 根地址 + joinedDsh 快照（broker/registry 由调用方走 FederationState.saveConnectionSettings）
    final st = KvStore();
    await st.write(key: _kRootAddr, value: rootAddress.trim());
    await st.write(key: _kJoinedDshId, value: dsh.deviceId);
    await st.write(key: _kJoinedDshName, value: dsh.name);

    return JoinResult(
      identity: DeviceIdentity(
        deviceId: deviceId,
        deviceToken: deviceToken,
        name: name,
        kind: 'app',
        caps: const ['files'],
        privKeyB64: keys.privPkcs8B64,
      ),
      dsh: dsh,
      registryUrl: registryUrl,
      brokerUrl: brokerUrl,
    );
  }
}
