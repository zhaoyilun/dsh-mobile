// dsh-federation — 文件传输（Web 实现）：整包拉取 + Blob 触发浏览器下载
// 浏览器没有文件系统写权限，下载体验交给 <a download>；SHA-256 在触发下载前校验。
// 注意：受同源策略限制，数据面地址需允许跨域（本地联调时通常同机无此问题）。
// dart:html 只在本文件（经条件导入仅 Web 编译）出现，属条件实现的正当用法。
// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

/// Web 上由浏览器决定保存位置，直接返回文件名表示「继续」。
Future<String?> chooseSavePath(BuildContext context, String name) async => name;

Future<String> defaultSaveDir() async => '';

/// 整包下载到内存 → 校验 → 触发浏览器下载。
/// 内存受限，仅适合测试用途的中等大小文件；大文件请用原生客户端。
Future<({String sha256, int bytes})> downloadTo(
  String url, {
  required String fileName,
  required String? savePath, // Web 忽略：由浏览器保存对话框决定
  String? expectedSha256,
  void Function(int downloaded)? onProgress,
}) async {
  final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 120));
  if (res.statusCode != 200) throw Exception('数据面 http ${res.statusCode}');
  final Uint8List bytes = res.bodyBytes;
  onProgress?.call(bytes.length);
  final digest = await Sha256().hash(bytes);
  final hex = digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  if (expectedSha256 != null && expectedSha256.isNotEmpty && hex != expectedSha256) {
    throw Exception('sha256 校验失败: $hex');
  }
  final blob = html.Blob([bytes]);
  final objectUrl = html.Url.createObjectUrlFromBlob(blob);
  html.AnchorElement(href: objectUrl)
    ..download = fileName
    ..click();
  html.Url.revokeObjectUrl(objectUrl);
  return (sha256: hex, bytes: bytes.length);
}
