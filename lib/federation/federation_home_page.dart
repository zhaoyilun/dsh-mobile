// dsh-federation — 联邦主页：加入联邦（首屏唯一动作）、连接状态、设备在线列表、入口
// 首屏：{根地址, 配对码, 设备名} → JoinService（PAIRING-SPEC §5）；
// 已加入：目标 dsh 卡（会话/文件入口）+ 设备列表（在线状态/ping）+ 连接设置。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme.dart';
import '../widgets/dsh_brand_mark.dart';
import 'device_identity.dart';
import 'federation_state.dart';
import 'files_page.dart';
import 'join_service.dart';
import 'local_settings.dart';
import 'native_bridge.dart';
import 'pairings.dart';
import 'mqtt_connection.dart';
import 'session_list_page.dart';

class FederationHomePage extends StatefulWidget {
  const FederationHomePage({super.key});

  @override
  State<FederationHomePage> createState() => _FederationHomePageState();
}

class _FederationHomePageState extends State<FederationHomePage> with WidgetsBindingObserver {

  // 加入表单（首屏三字段：根地址 + 配对码 + 设备名）
  final _rootCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  late final _nameCtrl = TextEditingController(text: _defaultDeviceName());
  bool _joining = false;
  String? _joinError;

  /// 3-Tab IA 的当前页：0 会话 / 1 文件 / 2 设置（2026-09-06 裁决）。
  int _tab = 0;

  /// 设备名默认值：「我的 + 平台名」。defaultTargetPlatform 而非 dart:io
  /// Platform，保证 Web 端也能编译运行。
  static String _defaultDeviceName() {
    if (kIsWeb) return '我的浏览器';
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => '我的 Android',
      TargetPlatform.iOS => '我的 iPhone',
      TargetPlatform.macOS => '我的 Mac',
      TargetPlatform.windows => '我的 Windows',
      TargetPlatform.linux => '我的 Linux',
      _ => '我的 ${defaultTargetPlatform.name}',
    };
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 本地偏好（通知/字号）启动即载入（KV 持久化）
    unawaited(LocalSettings.load());
    // Android 13+ 通知权限：启动时问一次（拒绝后原生侧不再重复弹窗）。
    unawaited(NativeBridge.requestNotificationPermission());
    FederationState.instance.addListener(_onState);
    // 冷启动接线（PAIRING-SPEC §5 现状缺口修复）：恢复身份/连接设置/joinedDsh → 连 MQTT → 拉 pairings。
    unawaited(FederationState.instance.init());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    FederationState.instance.removeListener(_onState);
    _rootCtrl.dispose();
    _codeCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  /// 前后台切换驱动保活服务：退后台时启动前台服务（进程不被当缓存回收，
  /// SSE/MQTT 存活期间通知照发），回前台即停，避免常驻后台通知。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        unawaited(NativeBridge.startKeepAlive());
      case AppLifecycleState.resumed:
        unawaited(NativeBridge.stopKeepAlive());
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  void _onState() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final state = FederationState.instance;
    final identity = state.identity;
    return Scaffold(
      backgroundColor: Ui.bg,
      body: SafeArea(child: identity == null ? _joinCard() : _main(state, identity)),
    );
  }

  /// 首屏唯一动作（PAIRING-SPEC §5）：根地址 + 配对码 + 设备名 → join。
  Widget _joinCard() {
    InputDecoration fieldDeco(String label, String hint) {
      return InputDecoration(
        labelText: label,
        hintText: hint,
        labelStyle: TextStyle(color: Ui.inkSecondary, fontSize: 13),
        hintStyle: TextStyle(color: Ui.inkMuted, fontSize: 14),
        filled: true,
        fillColor: Ui.bgSubtle,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Ui.accent, width: 1.4),
        ),
        contentPadding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      );
    }

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Center(child: DshBrandMark(size: 64)),
              const SizedBox(height: 18),
              Text('连接你的 dsh', textAlign: TextAlign.center, style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: Ui.ink)),
              const SizedBox(height: 6),
              Text(
                '在 dsh 桌面「设置 → 联邦」生成配对码，把手机接入同一台 dsh',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, height: 1.4, color: Ui.inkSecondary),
              ),
              const SizedBox(height: 26),
              Container(
                padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
                decoration: BoxDecoration(
                  color: Ui.surface,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: Ui.separator),
                  boxShadow: const [
                    BoxShadow(color: Color(0x0A1A1F2B), blurRadius: 18, offset: Offset(0, 6)),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: _rootCtrl,
                      decoration: fieldDeco('地址', 'example.com'),
                      style: TextStyle(fontSize: 15, color: Ui.ink),
                      keyboardType: TextInputType.url,
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: _codeCtrl,
                      decoration: fieldDeco('配对码', 'XXXX-XXXX'),
                      style: TextStyle(fontSize: 15, color: Ui.ink, letterSpacing: 2),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: _nameCtrl,
                      decoration: fieldDeco('设备名', ''),
                      style: TextStyle(fontSize: 15, color: Ui.ink),
                    ),
                    const SizedBox(height: 22),
                    SizedBox(
                      height: 48,
                      child: FilledButton(
                        onPressed: _joining ? null : _join,
                        style: FilledButton.styleFrom(
                          backgroundColor: Ui.accent,
                          foregroundColor: Ui.accentOn,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                        child: _joining
                            ? SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Ui.accentOn))
                            : const Text('加入', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                      ),
                    ),
                  ],
                ),
              ),
              if (_joinError != null) ...[
                SizedBox(height: 14),
                SelectableText(_joinError!, style: TextStyle(color: Ui.danger, fontSize: 13)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _join() async {
    final root = _rootCtrl.text.trim();
    final code = _codeCtrl.text.trim();
    final name = _nameCtrl.text.trim();
    if (root.isEmpty || code.isEmpty || name.isEmpty) {
      setState(() => _joinError = '根地址、配对码、设备名都要填');
      return;
    }
    setState(() {
      _joining = true;
      _joinError = null;
    });
    try {
      final result = await JoinService(rootAddress: root).join(code: code, name: name);
      final state = FederationState.instance;
      // endpoints 落盘（registryUrl/brokerUrl）+ joinedDsh 快照进内存（磁盘已由 JoinService 写）
      await state.saveConnectionSettings(broker: result.brokerUrl, registry: result.registryUrl);
      state.joinedDsh = result.dsh;
      await state.adoptIdentity(result.identity); // 连 MQTT；连接成功后自动拉 pairings
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) setState(() => _joinError = '$e');
    } finally {
      if (mounted) setState(() => _joining = false);
    }
  }

  Widget _main(FederationState state, DeviceIdentity identity) {
    // 3-Tab IA（2026-09-06 裁决）：会话 / 文件 / 设置；「主页」降级为设置 Tab。
    // 配对前的加入页入口不变；配对后首屏直达会话。
    return Scaffold(
      backgroundColor: Ui.bg,
      body: IndexedStack(
        index: _tab,
        children: const [
          SessionListPage(),
          FilesPage(),
          _SettingsTabBody(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        backgroundColor: Ui.surface,
        indicatorColor: Ui.bubbleUser,
        height: 64,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        destinations: [
          _dest(Icons.chat_bubble_outline, Icons.chat_bubble, '会话'),
          _dest(Icons.folder_outlined, Icons.folder, '文件'),
          _dest(Icons.settings_outlined, Icons.settings, '设置'),
        ],
      ),
      // 供设置页内联的（状态/连接/设备/退出）——由 _SettingsTabBody 消费
    );
  }

  NavigationDestination _dest(IconData icon, IconData active, String label) {
    return NavigationDestination(
      icon: Icon(icon, color: Ui.inkMuted),
      selectedIcon: Icon(active, color: Ui.accent),
      label: label,
    );
  }
}

/// 3-Tab IA 的「设置」页：本机身份/连接状态 + 联邦连接设置 + 可连接设备 + 退出联邦。
class _SettingsTabBody extends StatefulWidget {
  const _SettingsTabBody();

  @override
  State<_SettingsTabBody> createState() => _SettingsTabBodyState();
}

class _SettingsTabBodyState extends State<_SettingsTabBody> {
  FederationState get _state => FederationState.instance;

  @override
  void initState() {
    super.initState();
    _state.addListener(_onState);
  }

  @override
  void dispose() {
    _state.removeListener(_onState);
    super.dispose();
  }

  void _onState() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final identity = _state.identity;
    final connected = _state.phase == FederationPhase.connected;
    final statusText = switch (_state.phase) {
      FederationPhase.connected => '已连接',
      FederationPhase.connecting || FederationPhase.reconnecting => '连接中…',
      FederationPhase.error => '连接出错',
      _ => '未连接',
    };
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 12, 6),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_state.joinedDsh?.name ?? 'DSH', maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: Ui.ink)),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Container(
                          width: 8, height: 8,
                          decoration: BoxDecoration(
                            color: connected ? Ui.success : Ui.inkMuted,
                            shape: BoxShape.circle,
                          ),
                        ),
                        SizedBox(width: 6),
                        Text('$statusText · ${identity?.name ?? ''}', style: TextStyle(fontSize: 13, color: Ui.inkMuted)),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        // 偏好（本地真设置：持久化到本机）
        Padding(
          padding: EdgeInsets.fromLTRB(20, 14, 20, 4),
          child: Text('偏好', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Ui.inkMuted)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
          child: Container(
            decoration: BoxDecoration(
              color: Ui.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Ui.separator),
            ),
            child: Column(
              children: [
                SwitchListTile(
                  value: LocalSettings.notify,
                  onChanged: (v) async {
                    await LocalSettings.saveNotify(v);
                    if (mounted) setState(() {});
                  },
                  activeColor: Ui.accent,
                  title: Text('系统通知', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Ui.ink)),
                  subtitle: Text('审批 / 提问 / 任务失败 / 回复完成', style: TextStyle(fontSize: 12, color: Ui.inkMuted)),
                ),
                const Divider(height: 1, indent: 14, endIndent: 14),
                ListTile(
                  title: Text('外观', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Ui.ink)),
                  subtitle: Text('浅色 / 深色 / 跟随系统', style: TextStyle(fontSize: 12, color: Ui.inkMuted)),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final (v, label) in [('light', '浅'), ('dark', '深'), ('system', '跟随')])
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 2),
                          child: ChoiceChip(
                            label: Text(label, style: const TextStyle(fontSize: 11)),
                            selected: LocalSettings.themeMode == v,
                            onSelected: (_) async {
                              await LocalSettings.saveThemeMode(v);
                              if (mounted) setState(() {});
                            },
                          ),
                        ),
                    ],
                  ),
                ),
                const Divider(height: 1, indent: 14, endIndent: 14),
                ListTile(
                  title: Text('消息字号', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Ui.ink)),
                  subtitle: Text('聊天消息与代码块的显示大小', style: TextStyle(fontSize: 12, color: Ui.inkMuted)),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final f in const [13.0, 15.0, 17.0])
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 2),
                          child: ChoiceChip(
                            label: Text(f == 15 ? '标准' : (f == 13 ? '小' : '大'), style: const TextStyle(fontSize: 11)),
                            selected: LocalSettings.fontSize == f,
                            onSelected: (_) async {
                              await LocalSettings.saveFontSize(f);
                              if (mounted) setState(() {});
                            },
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        // 主机设置（镜像 3080「设置」页的 通用/模型/插件 三分区；联邦能力在下方）
        Padding(
          padding: EdgeInsets.fromLTRB(20, 14, 20, 8),
          child: Text('主机设置', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Ui.inkMuted)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
          child: Column(
            children: [
              _settingCard(Icons.tune_outlined, '通用', '本机身份 / 连接信息', () => _showSelfInfo()),
              const SizedBox(height: 8),
              _settingCard(Icons.smart_toy_outlined, '模型', '真选择：供应商 / 模型（应用到会话与默认）', () => _pickModel()),
              const SizedBox(height: 8),
              _settingCard(Icons.extension_outlined, '插件清单', '移动端可用能力一览', () => _showCapabilities()),
            ],
          ),
        ),
        const SizedBox(height: 20),
        // 联邦连接设置（broker/registry 高级项）
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => editConnection(context),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: Ui.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Ui.separator),
              ),
              child: Row(
                children: [
                  Icon(Icons.dns_outlined, size: 20, color: Ui.accent),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text('联邦连接设置', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Ui.ink)),
                  ),
                  Icon(Icons.chevron_right, size: 20, color: Ui.inkMuted),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 20),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 12, 8),
          child: Row(
            children: [
              Expanded(
                child: Text('可连接的设备', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Ui.inkMuted)),
              ),
              TextButton.icon(
                onPressed: _addDsh,
                icon: Icon(Icons.add_link, size: 16, color: Ui.accent),
                label: Text('添加 dsh', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Ui.accent)),
              ),
            ],
          ),
        ),
        if (_state.pairings.isEmpty)
          Padding(
            padding: EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: Text('暂无其他配对的 dsh', style: TextStyle(fontSize: 14, color: Ui.inkMuted)),
          )
        else ...[
          for (final pr in _state.pairings) _dshTile(pr),
        ],
        const SizedBox(height: 16),
        Center(
          child: TextButton(
            onPressed: () async {
              final confirm = await showDialog<bool>(
                context: context,
                builder: (c) => AlertDialog(
                  backgroundColor: Ui.bg,
                  title: Text('退出联邦', style: TextStyle(color: Ui.ink)),
                  content: Text('清除本机设备身份与密钥？之后需重新配对。', style: TextStyle(color: Ui.inkSecondary)),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(c, false), child: Text('取消', style: TextStyle(color: Ui.inkSecondary))),
                    TextButton(onPressed: () => Navigator.pop(c, true), child: Text('清除', style: TextStyle(color: Ui.danger))),
                  ],
                ),
              );
              if (confirm == true) {
                await _state.clearIdentity();
              }
            },
            child: Text('退出联邦', style: TextStyle(color: Ui.inkMuted, fontSize: 13)),
          ),
        ),
      ],
        ),
      ),
    );
  }

  /// 配对边瓦片：app 只关心「可连的 dsh」。
  Widget _dshTile(Pairing pr) {
    final view = FederationState.instance.view;
    final online = view.byId(pr.dsh.deviceId)?.online ?? false;
    final hasAccess = pr.access != null;
    final isCurrent = FederationState.instance.joinedDsh?.deviceId == pr.dsh.deviceId;
    return InkWell(
      onTap: isCurrent ? null : () => FederationState.instance.selectJoinedDsh(pr.dsh),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
        child: Row(
          children: [
            Icon(Icons.computer_outlined, size: 22, color: online ? Ui.ink : Ui.inkMuted),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${pr.dsh.name}${isCurrent ? ' · 当前' : ''}',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Ui.ink)),
                  const SizedBox(height: 2),
                  Text(
                    'dsh 节点 · ${online ? "在线" : "离线"}${hasAccess ? "" : " · 凭证待上传"}',
                    style: TextStyle(fontSize: 13, color: Ui.inkMuted),
                  ),
                ],
              ),
            ),
            if (!isCurrent)
              Icon(Icons.chevron_right, size: 20, color: Ui.inkMuted),
          ],
        ),
      ),
    );
  }

  /// 追加配对新 dsh（配对码；与首屏 join 同一契约）。成功后切换为新目标。
  Future<void> _addDsh() async {
    final rootCtrl = TextEditingController(text: _state.registryBaseUrl);
    final codeCtrl = TextEditingController();
    final nameCtrl = TextEditingController(text: '我的设备');
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: Ui.bg,
        title: Text('添加 dsh', style: TextStyle(color: Ui.ink)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: rootCtrl,
              decoration: InputDecoration(labelText: '地址', hintText: 'example.com', labelStyle: TextStyle(color: Ui.inkSecondary)),
              style: TextStyle(fontSize: 14, color: Ui.ink),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: codeCtrl,
              decoration: InputDecoration(labelText: '配对码', hintText: 'XXXX-XXXX', labelStyle: TextStyle(color: Ui.inkSecondary)),
              style: TextStyle(fontSize: 14, color: Ui.ink, letterSpacing: 2),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: nameCtrl,
              decoration: InputDecoration(labelText: '设备名', labelStyle: TextStyle(color: Ui.inkSecondary)),
              style: TextStyle(fontSize: 14, color: Ui.ink),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text('取消', style: TextStyle(color: Ui.inkSecondary))),
          TextButton(onPressed: () => Navigator.pop(c, true), child: Text('加入', style: TextStyle(color: Ui.accent, fontWeight: FontWeight.w600))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final root = rootCtrl.text.trim();
    final code = codeCtrl.text.trim();
    final name = nameCtrl.text.trim();
    if (root.isEmpty || code.isEmpty || name.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('地址、配对码、设备名都要填')));
      }
      return;
    }
    try {
      final result = await JoinService(rootAddress: root).join(code: code, name: name);
      final state = FederationState.instance;
      await state.saveConnectionSettings(broker: result.brokerUrl, registry: result.registryUrl);
      state.joinedDsh = result.dsh;
      await state.adoptIdentity(result.identity);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已加入 ${result.dsh.name}，身份 ${result.identity.deviceId}')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('添加失败: $e'), backgroundColor: Ui.danger));
      }
    }
  }

  /// 主机设置入口卡（镜像 3080 设置页分区样式）。
  Widget _settingCard(IconData icon, String title, String subtitle, VoidCallback onTap) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: Ui.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Ui.separator),
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: Ui.accent),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Ui.ink)),
                  SizedBox(height: 2),
                  Text(subtitle, style: TextStyle(fontSize: 12, color: Ui.inkMuted)),
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 20, color: Ui.inkMuted),
          ],
        ),
      ),
    );
  }

  void _hostSettingInfo(String title, String body) {
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: Ui.bg,
        title: Text(title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Ui.ink)),
        content: Text(body, style: TextStyle(fontSize: 13, height: 1.5, color: Ui.inkSecondary)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: Text('知道了', style: TextStyle(color: Ui.accent))),
        ],
      ),
    );
  }

  /// 通用：本机身份与连接信息（本地数据，随时可看）。
  void _showSelfInfo() {
    final st = _state;
    _hostSettingInfo('本机信息',
        '设备名：${st.identity?.name ?? '-'}\n身份：${st.identity?.deviceId ?? '-'}\n'
        '类型：app · 能力：${(st.identity?.caps ?? const []).join(', ')}\n\n'
        '当前 dsh：${st.joinedDsh?.name ?? '-'}（${st.joinedDsh?.deviceId ?? '-'}）\n'
        'registry：${st.registryBaseUrl}\nbroker：${st.brokerUrl}');
  }

  /// 模型：真设置——选择器读取 host 目录（llm.providers/llm.models）并写入会话/默认模型。
  Future<void> _pickModel() async {
    try {
      final api = FederationState.instance.hostApi();
      if (api == null) throw StateError('未选择目标 dsh');
      final res = await api.rpc('llm.providers', {}, timeout: const Duration(seconds: 10));
      final providers = (res['providers'] as List? ?? const []).map((e) => (e as Map).cast<String, dynamic>()).toList();
      if (providers.isEmpty) throw StateError('模型列表为空');
      if (!mounted) return;
      final providerId = await showModalBottomSheet<String>(
        context: context,
        backgroundColor: Ui.bg,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
        builder: (c) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(20, 18, 20, 8),
                child: Text('选择模型供应商', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: Ui.ink)),
              ),
              for (final p in providers)
                ListTile(
                  leading: Icon(Icons.dns_outlined, size: 20, color: Ui.accent),
                  title: Text((p['name'] ?? p['id'] ?? '?').toString(), style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Ui.ink)),
                  subtitle: Text((p['id'] ?? '').toString(), style: TextStyle(fontSize: 12, color: Ui.inkMuted)),
                  onTap: () => Navigator.pop(c, p['id']?.toString()),
                ),
            ],
          ),
        ),
      );
      if (providerId == null || !mounted) return;
      if (!mounted) return;
      final modelsRes = await api.rpc('llm.models', {'provider': providerId}, timeout: const Duration(seconds: 10));
      final models = (modelsRes['models'] as List? ?? const []).map((e) => (e as Map).cast<String, dynamic>()).toList();
      if (models.isEmpty) throw StateError('该供应商无可用模型');
      if (!mounted) return;
      final modelId = await showModalBottomSheet<String>(
        context: context,
        backgroundColor: Ui.bg,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
        builder: (c) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
                child: Text('选择模型 · $providerId', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: Ui.ink)),
              ),
              for (final m in models)
                ListTile(
                  leading: Icon(Icons.smart_toy_outlined, size: 20, color: Ui.accent),
                  title: Text((m['name'] ?? m['id'] ?? '?').toString(), style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Ui.ink)),
                  subtitle: Text((m['id'] ?? '').toString(), style: TextStyle(fontSize: 12, color: Ui.inkMuted)),
                  onTap: () => Navigator.pop(c, m['id']?.toString()),
                ),
            ],
          ),
        ),
      );
      if (modelId == null || !mounted) return;
      // 应用到最新会话（selectModel 同时保存默认）
      final list = await api.rpc('session.list', {}, timeout: const Duration(seconds: 10));
      final items = (list['items'] as List? ?? const []);
      if (items.isEmpty) throw StateError('暂无会话');
      final sid = ((items.first as Map)['sessionId'] as String?) ?? '';
      if (sid.isEmpty) throw StateError('会话 id 异常');
      await api.rpc('session.selectModel', {
        'sessionId': sid,
        'provider': providerId,
        'model': modelId,
      }, timeout: const Duration(seconds: 15));
      if (mounted) {
        _hostSettingInfo('模型设置', '已选择\nprovider：$providerId\nmodel：$modelId\n\n已应用到最新会话并保存为默认。');
      }
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString();
      if (msg.contains('404')) {
        _hostSettingInfo('模型设置', '读取失败：宿主 dsh 尚未开放模型接口（apiproxy-compat 更新并重启后可用）。');
      } else {
        _hostSettingInfo('模型设置', '失败：${msg.length > 120 ? msg.substring(0, 120) : msg}');
      }
    }
  }

  /// 插件清单：移动端实际能力（与桌面插件清单对照的移动侧视图）。
  void _showCapabilities() {
    _hostSettingInfo('移动端能力',
        '会话：实时消息（SSE 增量 + 本地缓存）\n'
        '发送：文本 / 图片；Enter 发送、Ctrl/Shift+Enter 换行\n'
        '审批：工具审批在会话内响应（允许一次/拒绝）\n'
        '提问：Agent 提问在会话内选择/输入回答\n'
        '文件：跨设备浏览与下载（sha256 校验）\n'
        '群聊：多角色视图\n'
        '联邦：一机多 dsh 切换 / 配对码新增\n\n'
        '桌面 dsh 侧完整插件清单见 3080「设置 → 插件」。');
  }

  Future<void> editConnection(BuildContext context) async {    final state = FederationState.instance;
    final brokerCtrl = TextEditingController(text: state.brokerUrl);
    final registryCtrl = TextEditingController(text: state.registryBaseUrl);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('联邦连接设置'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('云连接为默认；本地联调时改为 127.0.0.1', style: TextStyle(fontSize: 11, color: DshTokens.inkSecondary)),
            const SizedBox(height: 10),
            TextField(controller: brokerCtrl, decoration: const InputDecoration(labelText: 'brokerUrl', border: OutlineInputBorder()), style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
            const SizedBox(height: 10),
            TextField(controller: registryCtrl, decoration: const InputDecoration(labelText: 'registryUrl', border: OutlineInputBorder()), style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('保存')),
        ],
      ),
    );
    if (ok == true) {
      await state.saveConnectionSettings(broker: brokerCtrl.text.trim(), registry: registryCtrl.text.trim());
    }
  }
}
