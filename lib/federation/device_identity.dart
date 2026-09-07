// dsh-federation — 设备身份：Ed25519 密钥对 + deviceToken 的 secure storage 存取
// 密钥格式（跨端互操作约定）：
//   - raw 字节：ed25519 公钥 32B / 私钥 seed 32B（cryptography 原生格式）
//   - DER 包装：SPKI(12B 头 + 公钥) / PKCS8(16B 头 + seed)，用于上报 registry 与 device.json
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'kv_store.dart';

import 'package:cryptography/cryptography.dart';

/// 身份材料（全部经 secure storage，不落 SharedPreferences、不进日志）。
class DeviceIdentity {
  DeviceIdentity({
    required this.deviceId,
    required this.deviceToken,
    required this.name,
    required this.kind,
    required this.caps,
    required this.privKeyB64,
  });

  final String deviceId;
  final String deviceToken;
  final String name;
  final String kind;
  final List<String> caps;

  /// pkcs8(DER, base64url) 私钥 —— 只在本机解密后使用。
  final String privKeyB64;

  bool get complete => deviceId.isNotEmpty && deviceToken.isNotEmpty;

  Future<String> pubKeySpki() => pubKeySpkiFromPriv(privKeyB64);
}

/// ED25519 SPKI/PKCS8 DER 头（RFC 8410；跨端与 Node crypto 兼容）。
const List<int> _spkiPrefix = [0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00];
const List<int> _pkcs8Prefix = [0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20];

/// 从 pkcs8(base64url) 派生 SPKI(base64url)：seed → Ed25519 公钥 → SPKI 包装。
Future<String> pubKeySpkiFromPriv(String privKeyPkcs8B64) async {
  final pkcs8 = base64Url.decode(privKeyPkcs8B64);
  if (pkcs8.length != 48) throw ArgumentError('bad pkcs8 length: ${pkcs8.length}');
  final seed = pkcs8.sublist(_pkcs8Prefix.length);
  if (seed.length != 32) throw ArgumentError('bad seed length');
  final ed = Ed25519();
  final kp = await ed.newKeyPairFromSeed(seed);
  final pub = await kp.extractPublicKey();
  if (pub.bytes.length != 32) throw StateError('unexpected public key size');
  return base64Url.encode(Uint8List.fromList([..._spkiPrefix, ...pub.bytes]));
}

class IdentityStore {
  IdentityStore([KvStore? storage]) : _storage = storage ?? const KvStore();

  final KvStore _storage;

  static const _kDeviceId = 'federation.deviceId';
  static const _kDeviceToken = 'federation.deviceToken';
  static const _kName = 'federation.name';
  static const _kKind = 'federation.kind';
  static const _kCaps = 'federation.caps';
  static const _kPrivKey = 'federation.privKey';

  Future<DeviceIdentity?> load() async {
    final deviceId = await _storage.read(key: _kDeviceId);
    final token = await _storage.read(key: _kDeviceToken);
    final priv = await _storage.read(key: _kPrivKey);
    if (deviceId == null || token == null || priv == null) return null;
    return DeviceIdentity(
      deviceId: deviceId,
      deviceToken: token,
      name: await _storage.read(key: _kName) ?? '未命名设备',
      kind: await _storage.read(key: _kKind) ?? 'phone',
      caps: (await _storage.read(key: _kCaps))?.split(',') ?? ['files'],
      privKeyB64: priv,
    );
  }

  Future<void> save({
    required String deviceId,
    required String deviceToken,
    required String name,
    required String kind,
    required List<String> caps,
    required String privKeyPkcs8B64,
  }) async {
    await _storage.write(key: _kDeviceId, value: deviceId);
    await _storage.write(key: _kDeviceToken, value: deviceToken);
    await _storage.write(key: _kName, value: name);
    await _storage.write(key: _kKind, value: kind);
    await _storage.write(key: _kCaps, value: caps.join(','));
    await _storage.write(key: _kPrivKey, value: privKeyPkcs8B64);
  }

  Future<void> clear() async {
    for (final k in [_kDeviceId, _kDeviceToken, _kName, _kKind, _kCaps, _kPrivKey]) {
      await _storage.delete(key: k);
    }
  }

  static bool isHexToken(String s) => RegExp(r'^[A-Za-z0-9_-]{40,}$').hasMatch(s);
}

/// 密钥对生成结果：priv = pkcs8 DER(base64url)；pub = spki DER(base64url)。
class GeneratedKeys {
  GeneratedKeys({required this.privPkcs8B64, required this.pubSpkiB64, required this.privRaw, required this.pubRaw});

  final String privPkcs8B64;
  final String pubSpkiB64;
  final Uint8List privRaw; // 32B seed
  final Uint8List pubRaw; // 32B raw public key
}

Future<GeneratedKeys> generateIdentityKeys() async {
  final ed = Ed25519();
  final kp = await ed.newKeyPair();
  final privRaw = await kp.extractPrivateKeyBytes();
  final pub = await kp.extractPublicKey();
  final pubRaw = pub.bytes;
  if (privRaw.length != 32 || pubRaw.length != 32) throw StateError('unexpected key sizes');
  final pkcs8 = Uint8List.fromList([..._pkcs8Prefix, ...privRaw]);
  final spki = Uint8List.fromList([..._spkiPrefix, ...pubRaw]);
  return GeneratedKeys(
    privPkcs8B64: base64Url.encode(pkcs8),
    pubSpkiB64: base64Url.encode(spki),
    privRaw: Uint8List.fromList(privRaw),
    pubRaw: Uint8List.fromList(pubRaw),
  );
}

/// 从 SPKI(base64url) 取 raw 公钥（用于验签）：44B DER → 去 12B 头；32B raw 直接用。
Uint8List pubRawFromSpki(String spkiB64) {
  final der = base64Url.decode(spkiB64);
  if (der.length == 32) return Uint8List.fromList(der);
  if (der.length != 44) throw ArgumentError('bad spki length ${der.length}');
  return Uint8List.fromList(der.sublist(12));
}

Future<Uint8List> ed25519Sign(Uint8List privSeed, List<int> message) async {
  final ed = Ed25519();
  final keyPair = await ed.newKeyPairFromSeed(privSeed);
  final signature = await ed.sign(message, keyPair: keyPair);
  return Uint8List.fromList(signature.bytes);
}

Future<bool> ed25519Verify(Uint8List pubRaw, List<int> message, Uint8List signature) async {
  final ed = Ed25519();
  final publicKey = SimplePublicKey(pubRaw, type: KeyPairType.ed25519);
  return ed.verify(message, signature: Signature(signature, publicKey: publicKey));
}

String randomCorrId() {
  final rand = Random.secure();
  final bytes = List<int>.generate(16, (_) => rand.nextInt(256));
  return 'corr_${base64Url.encode(bytes).replaceAll('=', '')}';
}
