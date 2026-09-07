// dsh-federation — KvStore Web 后端：无文件系统，恒走 flutter_secure_storage
// （其 Web 实现基于 WebCrypto/localStorage，仅测试用途，安全强度有限）。
const bool kvUseFileBackend = false;

Map<String, String> kvLoadFileSync() => const <String, String>{};

Future<void> kvSaveFileSync(Map<String, String> cache) async {}
