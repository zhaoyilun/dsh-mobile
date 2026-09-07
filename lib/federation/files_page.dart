// dsh-federation — 文件页（Phase 3 P1）：跨设备浏览 + 传输（原生命名空间 files.* RPC）
// 数据面：files.claim 取件单 → 数据面 URL 下载；上传 = 本机临时数据面 + files.ingest（未实现）。
// 下载/保存的落盘方式按平台条件实现（IO 流式写文件 / Web 走浏览器下载），见 file_transfer.dart。
import 'dart:async';

import 'package:flutter/material.dart';

import '../theme.dart';
import 'file_transfer.dart' if (dart.library.html) 'file_transfer_web.dart';
import 'federation_state.dart';
import 'registry_view.dart';
import 'rpc_client.dart';
import 'session_list_page.dart' show Ui;

class _FileEntry {
  _FileEntry({required this.name, required this.isDir, required this.size, required this.path});
  final String name;
  final bool isDir;
  final int size;
  final String path;
}

class FilesPage extends StatefulWidget {
  const FilesPage({super.key});

  @override
  State<FilesPage> createState() => _FilesPageState();
}

class _FilesPageState extends State<FilesPage> {
  String? _targetDeviceId;
  String _cwd = '~';
  List<_FileEntry> _entries = [];
  bool _loading = false;
  String? _error;
  String? _activity;

  String get _basePath => _cwd == '~' ? '~' : _cwd;

  Future<FederationRpcClient> _rpc() async {
    final rpc = FederationState.instance.rpc;
    if (rpc == null) throw StateError('RPC 未就绪（联邦未连接）');
    return rpc;
  }

  Future<void> _refresh() async {
    final rpc = await _rpc();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await rpc.call(_targetDeviceId!, 'files.list', {'path': _basePath});
      if (!result.ok) {
        setState(() {
          _loading = false;
          _error = '${result.code}: ${result.message}';
        });
        return;
      }
      final entries = (result.value?['entries'] as List? ?? const [])
          .map((e) {
            final m = (e as Map).cast<String, dynamic>();
            return _FileEntry(
              name: m['name']?.toString() ?? '?',
              isDir: m['type'] == 'dir',
              size: (m['size'] as num?)?.toInt() ?? 0,
              path: _cwd == '~' ? '~/${m['name']}' : '$_cwd/${m['name']}',
            );
          })
          .toList();
      setState(() {
        _entries = entries;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _download(_FileEntry f) async {
    // 先选保存目标（用户取消就不浪费 claim），再取件、按数据面候选顺序下载。
    // IO：对话框选路径 + 流式落盘；Web：浏览器自己问保存位置（Blob 下载）。
    final dest = await chooseSavePath(context, f.name);
    if (dest == null || dest.trim().isEmpty) return;
    setState(() => _activity = 'claiming ${f.name}…');
    try {
      final rpc = await _rpc();
      final claim = await rpc.call(_targetDeviceId!, 'files.claim', {'path': f.path});
      if (!claim.ok) throw Exception('${claim.code}: ${claim.message}');
      final result = claim.value as Map<String, dynamic>;
      final expected = result['sha256']?.toString();
      // transports 里 lan 优先，其余（如公网中继）按声明顺序回退。
      final transports = (result['transports'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
      final ordered = <Map>[
        if (transports['lan'] is Map) transports['lan'] as Map,
        for (final e in transports.entries)
          if (e.key != 'lan' && e.value is Map) e.value as Map,
      ];
      if (ordered.isEmpty) throw Exception('取件单无可用数据面地址');

      Object? lastError;
      for (final t in ordered) {
        final url = t['url']?.toString();
        if (url == null || url.isEmpty) continue;
        try {
          if (mounted) setState(() => _activity = '下载 ${f.name}…');
          final done = await downloadTo(
            url,
            fileName: f.name,
            savePath: dest,
            expectedSha256: (expected != null && expected.isNotEmpty) ? expected : null,
            onProgress: (n) {
              if (mounted) setState(() => _activity = '下载 ${f.name}… ${_fmtSize(n)}');
            },
          );
          setState(() => _activity = '✓ 已保存 ${f.name} → $dest (${_fmtSize(done.bytes)})');
          return;
        } catch (e) {
          lastError = e; // 单个数据面失败不致命：换下一个候选地址
        }
      }
      throw Exception('数据面拉取失败: $lastError');
    } catch (e) {
      setState(() => _activity = null);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('下载失败: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    // 设备源双轨：配对边（有凭证）为准，在线状态叠加 registry 视图。
    // MQTT 视图断供（浏览器 WSS 被剪断等）时页面不至于空白无声。
    final state = FederationState.instance;
    final paired = state.pairings.where((p) => p.access != null).toList();
    final viewDevices = state.view.devices.where((d) => d.hasFiles).toList();
    final devices = [
      ...paired.map((p) => p.dsh),
      ...viewDevices.where((d) => !paired.any((p) => p.dsh.deviceId == d.deviceId)),
    ];
    return Scaffold(
      backgroundColor: Ui.bg,
      appBar: AppBar(
        title: Text(_targetDeviceId == null ? '文件网关' : (_cwd == '~' ? '$_targetDeviceId 根目录' : _targetDeviceId!)),
        backgroundColor: Ui.bg,
        foregroundColor: Ui.ink,
        surfaceTintColor: Ui.bg,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: null,
        actions: [
          IconButton(icon: Icon(Icons.refresh, color: Ui.inkMuted), onPressed: _targetDeviceId == null ? null : _refresh),
        ],
      ),
      body: _targetDeviceId == null ? _pickDevice(devices) : _browser(),
      floatingActionButton: _targetDeviceId == null
          ? null
          : FloatingActionButton.extended(
              backgroundColor: Ui.accent,
              foregroundColor: Ui.accentOn,
              onPressed: () => _goUp(),
              icon: const Icon(Icons.arrow_upward),
              label: const Text('上一级'),
            ),
    );
  }

  void _goUp() {
    if (_cwd == '~') return;
    final trimmed = _cwd.replaceFirst(RegExp(r'/[^/]+$'), '');
    setState(() => _cwd = trimmed.isEmpty ? '~' : trimmed);
    _refresh();
  }

  Widget _pickDevice(List<DeviceInfo> devices) {
    final rpcReady = FederationState.instance.rpc != null;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Padding(
          padding: const EdgeInsets.all(4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('选择要浏览/传输文件的设备（跨设备文件走原生命名空间）', style: TextStyle(fontSize: 12, color: DshTokens.inkSecondary)),
              if (!rpcReady) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: DshTokens.kleinBlueSoft,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.cloud_off_outlined, size: 15, color: DshTokens.kleinBlue),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text('文件功能需要 MQTT 实时链路，当前未连接（检查网络/代理后刷新）',
                            style: TextStyle(fontSize: 12, color: DshTokens.inkSecondary)),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
        if (devices.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: Column(
                children: [
                  const Icon(Icons.folder_open_outlined, color: DshTokens.inkMuted, size: 40),
                  const SizedBox(height: 12),
                  Text('暂无可用文件设备', style: const TextStyle(fontSize: 14, color: DshTokens.inkMuted)),
                  const SizedBox(height: 8),
                  TextButton(onPressed: () => FederationState.instance.connect(), child: const Text('重试连接', style: TextStyle(color: DshTokens.kleinBlue, fontSize: 14))),
                ],
              ),
            ),
          ),
        for (final d in devices)
          Card(
            color: Colors.white,
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              leading: Icon(d.online ? Icons.storage : Icons.storage_outlined, color: d.online ? DshTokens.kleinBlue : DshTokens.inkMuted),
              title: Text(d.name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: DshTokens.ink)),
              subtitle: Text('${d.deviceId} · ${d.online ? '在线' : '离线'}', style: const TextStyle(fontSize: 12, color: DshTokens.inkSecondary)),
              onTap: d.online
                  ? () {
                      setState(() => _targetDeviceId = d.deviceId);
                      _refresh();
                    }
                  : null,
            ),
          ),
      ],
    );
  }

  Widget _browser() {
    if (_loading) return const Center(child: CircularProgressIndicator(color: DshTokens.kleinBlue));
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, color: DshTokens.error, size: 44),
              const SizedBox(height: 8),
              Text(_error!, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12, color: DshTokens.inkSecondary)),
              const SizedBox(height: 12),
              TextButton(onPressed: _refresh, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    if (_activity != null) {
      return Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        const CircularProgressIndicator(color: DshTokens.kleinBlue),
        const SizedBox(height: 12),
        Text(_activity!, style: const TextStyle(fontSize: 12, color: DshTokens.inkSecondary)),
      ]));
    }
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text('路径: $_basePath', style: const TextStyle(fontSize: 11, fontFamily: 'monospace', color: DshTokens.inkMuted)),
        const SizedBox(height: 6),
        for (final f in _entries)
          Card(
            color: Colors.white,
            margin: const EdgeInsets.only(bottom: 6),
            child: ListTile(
              leading: Icon(f.isDir ? Icons.folder : Icons.insert_drive_file_outlined, color: f.isDir ? DshTokens.warning : DshTokens.kleinBlue),
              title: Text(f.name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: DshTokens.ink)),
              subtitle: Text(f.isDir ? '目录' : _fmtSize(f.size), style: const TextStyle(fontSize: 11, color: DshTokens.inkSecondary)),
              onTap: f.isDir
                  ? () {
                      setState(() => _cwd = f.path);
                      _refresh();
                    }
                  : () => _download(f),
            ),
          ),
        if (_entries.isEmpty && !_loading)
          const Padding(padding: EdgeInsets.all(24), child: Text('（空目录）', style: TextStyle(color: DshTokens.inkMuted))),
      ],
    );
  }

  String _fmtSize(int n) {
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    if (n < 1024 * 1024 * 1024) return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
    return '${(n / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }
}
