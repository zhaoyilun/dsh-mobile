// dsh-federation — KvStore 桌面文件后端（dart:io，仅 IO 平台编译）
// 路径与持久化逻辑：~/Library/Application Support/dsh_mobile/kv.json（0600，原子写）。
import 'dart:convert';
import 'dart:io';

/// 是否使用文件后端：桌面平台（macOS/Linux/Windows）。
bool get kvUseFileBackend => Platform.isMacOS || Platform.isLinux || Platform.isWindows;

File? _file;

File _fileSync() {
  final cached = _file;
  if (cached != null) return cached;
  final dir = Platform.environment['DSH_KV_DIR'] ??
      '${Platform.environment['HOME'] ?? '.'}/Library/Application Support/dsh_mobile';
  Directory(dir).createSync(recursive: true);
  final f = File('$dir/kv.json');
  _file = f;
  return f;
}

/// 读全量 kv（文件不存在/损坏时返回空表）。
Map<String, String> kvLoadFileSync() {
  try {
    final text = _fileSync().readAsStringSync();
    final raw = jsonDecode(text);
    return raw is Map<String, dynamic>
        ? raw.map((k, v) => MapEntry(k, v.toString()))
        : <String, String>{};
  } catch (_) {
    return <String, String>{};
  }
}

/// 原子落盘：tmp 写入 → rename → chmod 600（rename 不改变权限，写时就位）。
Future<void> kvSaveFileSync(Map<String, String> cache) async {
  final f = _fileSync();
  final tmp = File('${f.path}.tmp');
  await tmp.writeAsString(jsonEncode(cache), flush: true);
  await tmp.rename(f.path);
  try {
    Process.runSync('chmod', ['600', f.path]);
  } catch (_) {}
}
