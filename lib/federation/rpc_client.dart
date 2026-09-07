// dsh-federation — RPC 客户端：correlation 协议（DESIGN §6）
// call(targetDeviceId, method, params)：签名 → request → 等 reply（corrId 关联）；
// ack 受理后进入 INFLIGHT；无 ack 超时重试 1 次（注意：重试会生成新 corrId，
// 若目标端按 corrId 幂等去重，非幂等方法可能被重复执行——retry 只用于
// E_TIMEOUT/E_OFFLINE/E_BUSY 这类可安全重发的场景）；流式结果由 events 关联处理。
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../federation/device_identity.dart';

class RpcResult {
  RpcResult({required this.ok, this.value, this.code, this.message});
  final bool ok;
  final dynamic value;
  final String? code;
  final String? message;

  @override
  String toString() => ok ? 'RpcResult.ok($value)' : 'RpcResult.error($code: $message)';
}

class FederationRpcClient {
  FederationRpcClient({required this.mqtt, required this.identity, this.pubKeyOf});

  final dynamic mqtt; // FederationMqtt（duck typing 以规避循环依赖）
  final DeviceIdentity identity;

  /// 根据目标设备 ID 返回其 SPKI 公钥（来自 registry 缓存）；返回 null 表示未知设备 → 拒收
  final String? Function(String deviceId)? pubKeyOf;

  final Map<String, Completer<RpcResult>> _pending = {};
  StreamSubscription? _sub;

  static const defaultTimeout = Duration(seconds: 30);

  void start() {
    _sub = (mqtt.messages as Stream<MapEntry<String, dynamic>>).listen((entry) async {
      final topic = entry.key;
      final payload = entry.value;
      final m = RegExp(r'^dsh/[\w-]+/api/[\w.]+/(ack|reply)/(\S+)$').firstMatch(topic);
      if (m == null) return;
      final corrId = m.group(2)!;
      final data = payload is Map<String, dynamic> ? payload : <String, dynamic>{};
      final completer = _pending[corrId];
      if (completer == null || completer.isCompleted) return;
      if (m.group(1) == 'reply') {
        // P0-5：reply 必须验签（DESIGN §9.2）——canonical 与 Node replySig 同构
        final sigVerified = await _verifyReplySignature(data);
        if (!sigVerified) {
          completer.complete(RpcResult(ok: false, code: 'E_UNAUTHORIZED', message: 'reply signature rejected'));
          _pending.remove(corrId);
          return;
        }
        final ok = data['ok'] == true;
        completer.complete(RpcResult(
          ok: ok,
          value: ok ? data['result'] : null,
          code: ok ? null : (data['error']?['code'] as String? ?? 'E_UNKNOWN'),
          message: ok ? null : (data['error']?['message'] as String?),
        ));
        _pending.remove(corrId);
      }
      // ack：标记已受理（保持等待 reply；超时由发起方兜底）
    });
  }

  Future<bool> _verifyReplySignature(Map<String, dynamic> reply) async {
    try {
      final frm = reply['frm']?.toString() ?? '';
      if (frm.isEmpty) return false;
      final spki = pubKeyOf?.call(frm);
      if (spki == null || spki.isEmpty) return false;
      final sig = reply['sig']?.toString() ?? '';
      final text = '${reply['v']}|${reply['id']}|$frm|${reply['ts']}|${reply['ok']}|${jsonEncode(reply['result'] ?? reply['error'])}';
      return ed25519Verify(pubRawFromSpki(spki), utf8.encode(text), _decodeSigBytes(sig));
    } catch (_) {
      return false;
    }
  }

  Uint8List _decodeSigBytes(String sig) {
    if (!sig.startsWith('ed25519:')) return Uint8List(0);
    final b64 = sig.substring(8);
    try {
      return base64Url.decode(base64Url.normalize(b64));
    } catch (_) {
      return Uint8List(0);
    }
  }

  void dispose() {
    _sub?.cancel();
    for (final c in _pending.values) {
      if (!c.isCompleted) c.complete(RpcResult(ok: false, code: 'E_ABORTED', message: 'client disposed'));
    }
    _pending.clear();
  }

  Future<RpcResult> call(
    String targetDeviceId,
    String method,
    Map<String, dynamic> params, {
    Duration timeout = defaultTimeout,
    bool retry = false,
  }) async {
    final corrId = randomCorrId();
    final now = DateTime.now().millisecondsSinceEpoch;
    final request = <String, dynamic>{
      'v': 1,
      'id': corrId,
      'method': method,
      'frm': identity.deviceId,
      'ts': now,
      'ttl': timeout.inMilliseconds,
      'params': params,
    };
    // 签名：canonical(v|id|method|frm|ts|ttl|params)
    final privRaw = _privSeed();
    final textToSign = '1|$corrId|$method|${identity.deviceId}|$now|${timeout.inMilliseconds}|${_canonical(params)}';
    request['sig'] = 'ed25519:${base64Url.encode(await ed25519Sign(privRaw, utf8.encode(textToSign)))}';

    final completer = Completer<RpcResult>();
    _pending[corrId] = completer;
    await mqtt.publishJson('dsh/$targetDeviceId/api/$method/request', request);

    try {
      final result = await completer.future.timeout(timeout + const Duration(seconds: 5));
      if (!result.ok && retry && _isRetryable(result.code)) {
        _pending.remove(corrId);
        return call(targetDeviceId, method, params, timeout: timeout, retry: false);
      }
      return result;
    } on TimeoutException {
      _pending.remove(corrId);
      if (retry && _isRetryable(null)) {
        return call(targetDeviceId, method, params, timeout: timeout, retry: false);
      }
      return RpcResult(ok: false, code: 'E_TIMEOUT', message: 'reply timeout for $method');
    }
  }

  Uint8List _privSeed() {
    final pkcs8 = base64Url.decode(identity.privKeyB64);
    return pkcs8.sublist(pkcs8.length - 32);
  }

  String _canonical(Map<String, dynamic>? params) {
    if (params == null || params.isEmpty) return '{}';
    final keys = params.keys.toList()..sort();
    final out = <String, dynamic>{};
    for (final k in keys) {
      out[k] = params[k];
    }
    return jsonEncode(out);
  }

  bool _isRetryable(String? code) => const {'E_TIMEOUT', 'E_OFFLINE', 'E_BUSY'}.contains(code);
}
