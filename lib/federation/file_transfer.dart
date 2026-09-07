// dsh-federation — 文件传输（IO 实现）：流式下载到文件 + 增量 SHA-256
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 保存目标选择（对话框，可改路径）。返回 null = 用户取消。
/// 移动端默认应用文档目录（/tmp 在 Android/iOS 沙箱内不存在），桌面默认 /tmp。
Future<String?> chooseSavePath(BuildContext context, String name) async {
  final defaultDir = await defaultSaveDir();
  if (!context.mounted) return null;
  final controller = TextEditingController(text: p.join(defaultDir, name));
  final r = await showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('保存到本机路径'),
      content: TextField(controller: controller, style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('取消')),
        TextButton(onPressed: () => Navigator.pop(c, controller.text), child: const Text('保存')),
      ],
    ),
  );
  return r;
}

Future<String> defaultSaveDir() async {
  if (Platform.isAndroid || Platform.isIOS) {
    final dir = await getApplicationDocumentsDirectory();
    return dir.path;
  }
  return '/tmp';
}

/// 流式下载：边落盘边算增量 SHA-256（内存占用 ≈ 单个 chunk，大文件不 OOM）。
/// [expectedSha256] 非空时校验，不匹配则删除已写文件并抛错。
Future<({String sha256, int bytes})> downloadTo(
  String url, {
  required String fileName,
  required String? savePath,
  String? expectedSha256,
  void Function(int downloaded)? onProgress,
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  final hashSink = Sha256().newHashSink();
  try {
    final req = await client.getUrl(Uri.parse(url));
    final res = await req.close();
    if (res.statusCode != 200) throw Exception('数据面 http ${res.statusCode}');
    final out = File(savePath!).openWrite();
    var bytes = 0;
    try {
      await for (final chunk in res) {
        hashSink.add(chunk);
        bytes += chunk.length;
        out.add(chunk);
        onProgress?.call(bytes);
      }
      await out.flush();
      await out.close();
    } catch (e) {
      await out.close().catchError((_) {});
      await File(savePath).delete().catchError((_) => File(savePath));
      rethrow;
    }
    hashSink.close();
    final digest = await hashSink.hash();
    final hex = digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    if (expectedSha256 != null && expectedSha256.isNotEmpty && hex != expectedSha256) {
      await File(savePath).delete().catchError((_) => File(savePath));
      throw Exception('sha256 校验失败: $hex');
    }
    return (sha256: hex, bytes: bytes);
  } finally {
    client.close(force: true);
  }
}
