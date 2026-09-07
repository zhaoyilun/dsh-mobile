// dsh-federation — 进程内图片缓存：发送图片时按 sha256 存字节；
// 历史消息的 attachment 引用（attachmentId=sha256:hex）命中即渲染缩略图。
// 上限 48 条 FIFO（避免长会话撑爆内存）；重启即失（历史图片回退 📷 占位）。
import 'dart:collection';
import 'dart:typed_data';

class ImageCacheStore {
  ImageCacheStore._();
  static final LinkedHashMap<String, Uint8List> _m = LinkedHashMap();

  static void put(String hash, Uint8List bytes) {
    _m.remove(hash);
    _m[hash] = bytes;
    while (_m.length > 48) {
      _m.remove(_m.keys.first);
    }
  }

  static Uint8List? get(String hash) => _m[hash];

  static bool contains(String hash) => _m.containsKey(hash);
}
