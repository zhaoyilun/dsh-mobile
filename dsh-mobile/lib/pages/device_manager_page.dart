import 'package:flutter/material.dart';

import '../config_store.dart';
import '../theme.dart';
import 'device_editor_page.dart';

/// 设备管理页:列出本机保存的所有 DSH 设备档案,支持切换、添加、删除。
///
/// 用户可能在 Mac mini、Windows、Linux 等多个设备上跑 DSH,
/// 每台设备对应一条「服务器地址 + 凭据」档案;这里集中管理,
/// 点一下即切换手机当前接入的设备,无需重输口令。
class DeviceManagerPage extends StatefulWidget {
  const DeviceManagerPage({super.key, this.initial});

  /// 当前激活配置(仅用于高亮,切换后由本页返回新配置)。
  final AppConfig? initial;

  @override
  State<DeviceManagerPage> createState() => _DeviceManagerPageState();
}

class _DeviceManagerPageState extends State<DeviceManagerPage> {
  final ConfigStore _store = ConfigStore();
  List<AppConfig> _profiles = [];
  String? _activeId;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final profiles = await _store.loadProfiles();
    final activeId = await _store.activeProfileId();
    if (!mounted) return;
    setState(() {
      _profiles = profiles;
      _activeId = activeId;
      _loading = false;
    });
  }

  Future<void> _switch(AppConfig profile) async {
    try {
      await _store.switchProfile(profile.id!);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('切换失败,请重试')),
      );
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop(profile);
  }

  Future<void> _add() async {
    final created = await Navigator.of(context).push<AppConfig>(
      MaterialPageRoute(builder: (_) => const DeviceEditorPage()),
    );
    if (created == null || !mounted) return;
    // 新设备已设为当前激活;直接携带新配置返回,让主页立即重建。
    final active = await ConfigStore().load();
    if (mounted && active != null) {
      Navigator.of(context).pop(active);
    }
  }

  Future<void> _delete(AppConfig profile) async {
    if (_profiles.length <= 1) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('至少保留一台设备,不能删除最后一台')),
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除「${profile.displayName}」?'),
        content: const Text('将删除该设备的地址与凭据,切换操作不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _store.deleteProfile(profile.id!);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('删除失败,请重试')),
      );
      return;
    }
    if (!mounted) return;
    // 如果删的是当前激活设备,ConfigStore 已自动切换到剩余设备;
    // 这里把切换结果带回设置页,让主页 WebView 立即重建。
    final active = await _store.load();
    if (active != null && active.id != _activeId) {
      if (mounted) Navigator.of(context).pop(active);
      return;
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('设备管理')),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(DshTokens.space4),
                children: [
                  Text(
                    '已保存 ${_profiles.length} 台设备',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: DshTokens.space3),
                  for (final profile in _profiles) ...[
                    _DeviceTile(
                      profile: profile,
                      active: profile.id == _activeId,
                      onTap: () => _switch(profile),
                      onDelete: _profiles.length > 1
                          ? () => _delete(profile)
                          : null,
                    ),
                    const SizedBox(height: DshTokens.space2),
                  ],
                  if (_profiles.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: DshTokens.space6),
                      child: Center(child: Text('还没有设备,点击下方添加')),
                    ),
                  const SizedBox(height: DshTokens.space5),
                  FilledButton.icon(
                    onPressed: _add,
                    icon: const Icon(Icons.add),
                    label: const Text('添加设备'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                  const SizedBox(height: DshTokens.space4),
                  Text(
                    '· 每台设备独立保存服务器地址与凭据,互不覆盖;\n'
                    '· 凭据经 Android Keystore 加密存储,不写日志;\n'
                    '· 点击设备即切换,主页会自动重新加载对应 DSH。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.6,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({
    required this.profile,
    required this.active,
    required this.onTap,
    this.onDelete,
  });

  final AppConfig profile;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: active
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.45)
          : theme.colorScheme.surface,
      borderRadius: BorderRadius.circular(DshTokens.radiusL),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(DshTokens.radiusL),
        child: Container(
          padding: const EdgeInsets.all(DshTokens.space4),
          decoration: BoxDecoration(
            border: Border.all(
              color: active
                  ? theme.colorScheme.primary.withValues(alpha: 0.4)
                  : theme.dividerColor,
            ),
            borderRadius: BorderRadius.circular(DshTokens.radiusL),
          ),
          child: Row(
            children: [
              Icon(
                profile.mode == ConnectionMode.public
                    ? Icons.public
                    : Icons.lan,
                color: active ? theme.colorScheme.primary : DshTokens.inkMuted,
              ),
              const SizedBox(width: DshTokens.space3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            profile.displayName,
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: active
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.onSurface,
                            ),
                          ),
                        ),
                        if (active) ...[
                          const SizedBox(width: DshTokens.space2),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: DshTokens.space2,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primary,
                              borderRadius: BorderRadius.circular(
                                DshTokens.radiusS,
                              ),
                            ),
                            child: Text(
                              '当前',
                              style: TextStyle(
                                color: theme.colorScheme.onPrimary,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${profile.modeLabel} · ${profile.displayOrigin}',
                      style: theme.textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (onDelete != null)
                IconButton(
                  tooltip: '删除设备',
                  onPressed: onDelete,
                  icon: const Icon(Icons.delete_outline),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
