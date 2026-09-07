// dsh-federation — 键值存储统一抽象
// 桌面（macOS/Linux/Windows）：~/Library/Application Support/dsh_mobile/kv.json（0600，原子写）。
//   为什么不用钥匙串：传统登录钥匙串每次新 app 首次访问都弹系统授权框（用户拒绝即 -128 全灭），
//   数据保护钥匙串又需要正式签名的 keychain 授权（ad-hoc 不可用）——个人设备单用户场景，
//   0600 文件的风险（同用户进程可读）可接受，换取零弹窗。
// 移动（Android/iOS/Web）：flutter_secure_storage（Android Keystore / WebCrypto）。
// 文件后端在 kv_file_io.dart（条件导入），Web 编译不携带 dart:io。
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'kv_file_io.dart' if (dart.library.html) 'kv_file_web.dart';

class KvStore {
  const KvStore();

  bool get _useFile => kvUseFileBackend;

  static Map<String, String>? _cache;

  /// 桌面端文件保存串行队列：并发 write/delete 会同时打开同一个 .tmp
  /// 再 rename，内容可能交错损坏。每次落盘追加到队列尾并返回自己的 Future。
  static Future<void> _saveQueue = Future<void>.value();

  Map<String, String> _loadFile() => _cache ??= kvLoadFileSync();

  Future<String?> read({required String key}) async {
    if (!_useFile) {
      return const FlutterSecureStorage().read(key: key);
    }
    return _loadFile()[key];
  }

  Future<void> write({required String key, required String value}) async {
    if (!_useFile) {
      await const FlutterSecureStorage().write(key: key, value: value);
      return;
    }
    _loadFile()[key] = value;
    await _enqueueSave();
  }

  Future<void> delete({required String key}) async {
    if (!_useFile) {
      await const FlutterSecureStorage().delete(key: key);
      return;
    }
    _loadFile().remove(key);
    await _enqueueSave();
  }

  /// 把一次落盘追加到串行队列；返回的 Future 只反映自己的那次保存，
  /// 前面排队的保存若失败不拖累后续（链吞错误、当前调用方照常收到异常）。
  Future<void> _enqueueSave() {
    final task = _saveQueue.then((_) => kvSaveFileSync(_loadFile()));
    _saveQueue = task.then((_) {}, onError: (_) {});
    return task;
  }
}
