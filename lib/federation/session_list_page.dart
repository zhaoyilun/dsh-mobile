// dsh-federation — 会话列表页（对齐桌面版移动抽屉的分组体验）
// 分组：按工作区（cwd 的 basename）分组，组头可折叠；每组默认预览 5 条，
// 「显示全部 N 条」按需展开（抄桌面旧版 SessionListPage.tsx 的交互）。
// 子智能体会话：置灰 + 「子」标记展示（host 的 subagent.* API 尚未挂载，
// 点开给出说明；host 升级后接 subagent.history 即可读）。
// 数据流不变：本地历史库立即渲染（响应式）→ 后台 rpc session.list 刷新合并。
import 'dart:async';

import 'package:flutter/material.dart';

import 'federation_state.dart';
import 'local_api.dart';
import 'registry_view.dart';
import 'session_chat_page.dart';
import 'store/local_store.dart';

/// 全局视觉常量（Klein Blue 品牌体系，与 theme.dart 的 DshTokens 同源）——供各页共用。
/// 语义字段名保持不变，值统一到 DshTokens：页面不再出现黑/白「两种风格」。
abstract final class Ui {
  // 支持夜间模式：全局可变量，按当前亮度 applyFor() 赋值（main 启动与主题切换时调用）。
  static Color bg = _light.bg;
  static Color bgSubtle = _light.bgSubtle;
  static Color surface = _light.surface;
  static Color bubbleUser = _light.bubbleUser;
  static Color ink = _light.ink;
  static Color inkSecondary = _light.inkSecondary;
  static Color inkMuted = _light.inkMuted;
  static Color accent = _light.accent;
  static Color accentDeep = _light.accentDeep;
  static Color accentOn = _light.accentOn;
  static Color separator = _light.separator;
  static Color danger = _light.danger;
  static Color success = _light.success;

  static const _light = _UiPalette(
    bg: Color(0xFFF7F9FC),
    bgSubtle: Color(0xFFEFF2F8),
    surface: Color(0xFFFFFFFF),
    bubbleUser: Color(0xFFE8EDFB),
    ink: Color(0xFF1A1F2B),
    inkSecondary: Color(0xFF5A6472),
    inkMuted: Color(0xFF8A93A0),
    accent: Color(0xFF3B5BD9),
    accentDeep: Color(0xFF2E44AD),
    accentOn: Color(0xFFFFFFFF),
    separator: Color(0xFFE4E8EE),
    danger: Color(0xFFC0392B),
    success: Color(0xFF1B8A5A),
  );

  static const _dark = _UiPalette(
    bg: Color(0xFF101418),
    bgSubtle: Color(0xFF1E2229),
    surface: Color(0xFF171B21),
    bubbleUser: Color(0xFF232B4A),
    ink: Color(0xFFE8EAED),
    inkSecondary: Color(0xFFA7AEBB),
    inkMuted: Color(0xFF6A7280),
    accent: Color(0xFF5B7CF0),
    accentDeep: Color(0xFF23306E),
    accentOn: Color(0xFFFFFFFF),
    separator: Color(0xFF2A3038),
    danger: Color(0xFFE05B4D),
    success: Color(0xFF2FA97A),
  );

  static void applyFor(Brightness b) {
    final p = b == Brightness.dark ? _dark : _light;
    bg = p.bg;
    bgSubtle = p.bgSubtle;
    surface = p.surface;
    bubbleUser = p.bubbleUser;
    ink = p.ink;
    inkSecondary = p.inkSecondary;
    inkMuted = p.inkMuted;
    accent = p.accent;
    accentDeep = p.accentDeep;
    accentOn = p.accentOn;
    separator = p.separator;
    danger = p.danger;
    success = p.success;
  }
}

class _UiPalette {
  const _UiPalette({
    required this.bg,
    required this.bgSubtle,
    required this.surface,
    required this.bubbleUser,
    required this.ink,
    required this.inkSecondary,
    required this.inkMuted,
    required this.accent,
    required this.accentDeep,
    required this.accentOn,
    required this.separator,
    required this.danger,
    required this.success,
  });
  final Color bg;
  final Color bgSubtle;
  final Color surface;
  final Color bubbleUser;
  final Color ink;
  final Color inkSecondary;
  final Color inkMuted;
  final Color accent;
  final Color accentDeep;
  final Color accentOn;
  final Color separator;
  final Color danger;
  final Color success;
}

/// 每组默认预览条数（与桌面版一致：长组「显示全部」展开）。
const _kPreviewCount = 5;

/// 合并 host `session.list` 条目与本地已登记 cwd。
///
/// host 的 cwd 是「未记录时不返回」（SessionSummary.cwd?: string 契约）。当 host 对该会话
/// 未登记工作区（旧会话 / 旧 host / 会话早于 host 修复创建）时，绝不能用空串覆盖本地已
/// 登记的项目(cwd)——否则新建会话选的指定工作区会被打回「未分组」。仅当 host 给了非空
/// cwd 才采用 host（与「未记录时保留本地」互补；host 与本地一致时天然幂等）。
List<StoredSession> mergeKnownCwd(List<StoredSession> incoming, Map<String, String> knownCwd) {
  return [
    for (final s in incoming)
      if (s.cwd.isEmpty && (knownCwd[s.id]?.isNotEmpty ?? false))
        StoredSession(
          id: s.id,
          dshId: s.dshId,
          title: s.title,
          cwd: knownCwd[s.id]!,
          messageCount: s.messageCount,
          updatedAt: s.updatedAt,
          lastSeq: s.lastSeq,
          parentSessionId: s.parentSessionId,
          blank: s.blank,
        )
      else
        s,
  ];
}

class SessionListPage extends StatefulWidget {
  const SessionListPage({super.key});

  @override
  State<SessionListPage> createState() => _SessionListPageState();
}

class _SessionListPageState extends State<SessionListPage> {
  StreamSubscription? _storeSub;
  List<StoredSession> _sessions = [];
  bool _refreshing = false;
  String? _error;
  String _query = '';
  final TextEditingController _searchCtrl = TextEditingController();

  /// 折叠的组（cwd basename）与展开到全量的组。
  final Set<String> _collapsed = {};
  final Set<String> _expanded = {};

  /// 宽屏双栏：当前在右侧打开的会话。
  String? _activeSessionId;
  String? _activeSessionTitle;

  FederationState get _state => FederationState.instance;

  HostSessionService? get _api => _state.hostApi();

  String get _dshId => _state.joinedDsh?.deviceId ?? '';

  @override
  void initState() {
    super.initState();
    _state.addListener(_onState);
    _storeSub = StoreService.shared.sessionsStream(_dshId).listen((list) {
      if (mounted) setState(() => _sessions = list);
    });
    _refresh();
  }

  @override
  void dispose() {
    _state.removeListener(_onState);
    _storeSub?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onState() {
    if (mounted) setState(() {});
    // 凭证就绪自动恢复：页面打开早于 pairings 拉取时曾报「无配对凭证」，之后
    // registry 异步返回 access——此时自动重试一次（仅针对该错误文本，防循环）。
    if (mounted && _error?.contains('无配对凭证') == true && _api != null) {
      _refresh();
    }
  }

  Future<void> _refresh() async {
    final api = _api;
    if (api == null) return;
    setState(() {
      _refreshing = true;
      _error = null;
    });
    try {
      final res = await api.rpc('session.list', {});
      final list = (res['items'] as List?) ?? (res['sessions'] as List?) ?? [];
      final dshId = _dshId;
      // 合并本地已登记项目 cwd——host 未记录工作区时保留本地，避免指定工作区被打回「未分组」
      // （见 mergeKnownCwd 注释）。
      final knownCwd = {
        for (final s in _sessions)
          if (s.cwd.isNotEmpty) s.id: s.cwd,
      };
      final stored = [
        for (final e in list)
          if (e is Map)
            StoredSession.fromListJson(e.cast<String, dynamic>(), dshId),
      ];
      // 存全部（含 subagent / blank）；展示层负责过滤与分组——host 侧
      // subagent.* API 就绪后无需改数据层即可接上。
      await StoreService.shared.upsertSessions(
        dshId,
        mergeKnownCwd(stored, knownCwd).where((s) => !s.blank).toList(),
      );
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  /// 新建会话选择器（工作区/模型/模式）——之前 create({}) 什么都没法选。
  Future<void> _newSession() async {
    final api = _api;
    if (api == null) return;
    // 本地已知工作区（会话 cwd 去重）；模型经 llm 目录；模式=agent 预设
    final cwds =
        _sessions.map((s) => s.cwd).where((c) => c.isNotEmpty).toSet().toList()
          ..sort();
    String? pickedCwd;
    String? pickedPreset;
    String? pickedProvider;
    String? pickedModel;
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Ui.bg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (c) => StatefulBuilder(
        builder: (c2, setSheet) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(20, 18, 20, 4),
                child: Text(
                  '新建会话',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: Ui.ink,
                  ),
                ),
              ),
              ListTile(
                leading: Icon(
                  Icons.folder_outlined,
                  size: 20,
                  color: Ui.accent,
                ),
                title: Text(
                  '工作区',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Ui.ink,
                  ),
                ),
                subtitle: Text(
                  pickedCwd == null ? '默认（host 配置）' : pickedCwd!,
                  style: TextStyle(fontSize: 12, color: Ui.inkMuted),
                ),
                trailing: Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: Ui.inkMuted,
                ),
                onTap: () async {
                  final sel = await _pickSheetItem<String>(
                    title: '选择工作区',
                    options: [null, ...cwds],
                    label: (v) => v == null ? '默认（host 配置）' : v.split('/').last,
                    selected: pickedCwd,
                  );
                  if (sel != null || cwds.contains(sel)) pickedCwd = sel;
                  setSheet(() {});
                },
              ),
              ListTile(
                leading: Icon(
                  Icons.smart_toy_outlined,
                  size: 20,
                  color: Ui.accent,
                ),
                title: Text(
                  '模型',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Ui.ink,
                  ),
                ),
                subtitle: Text(
                  pickedModel == null ? '默认（跟随桌面）' : '$pickedModel',
                  style: TextStyle(fontSize: 12, color: Ui.inkMuted),
                ),
                trailing: Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: Ui.inkMuted,
                ),
                onTap: () async {
                  try {
                    final pick = await _pickModelSheet();
                    if (pick != null) {
                      pickedProvider = pick.$1;
                      pickedModel = pick.$2;
                      setSheet(() {});
                    }
                  } catch (e) {
                    if (c2.mounted)
                      ScaffoldMessenger.of(
                        c2,
                      ).showSnackBar(SnackBar(content: Text('模型读取失败: $e')));
                  }
                },
              ),
              ListTile(
                leading: Icon(
                  Icons.tune_outlined,
                  size: 20,
                  color: Ui.accent,
                ),
                title: Text(
                  '模式（agent 预设）',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Ui.ink,
                  ),
                ),
                subtitle: Text(
                  pickedPreset ?? '默认',
                  style: TextStyle(fontSize: 12, color: Ui.inkMuted),
                ),
                trailing: Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: Ui.inkMuted,
                ),
                onTap: () async {
                  const presets = ['router-standard', 'anchored-standard'];
                  final sel = await _pickSheetItem<String>(
                    title: '选择模式',
                    options: [null, ...presets],
                    label: (v) => v == null ? '默认' : v,
                    selected: pickedPreset,
                  );
                  if (sel != null || presets.contains(sel)) pickedPreset = sel;
                  setSheet(() {});
                },
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 6, 20, 16),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: Ui.accent,
                      minimumSize: const Size(0, 46),
                    ),
                    onPressed: () => Navigator.pop(c, true),
                    child: Text(
                      '创建',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: Ui.accentOn,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (confirmed != true) return;
    try {
      final res = await api.rpc('session.create', {
        if (pickedCwd != null) 'cwd': pickedCwd,
        if (pickedPreset != null) 'agentPreset': pickedPreset,
      });
      final sessionId = res['sessionId']?.toString() ?? '';
      if (sessionId.isEmpty) throw Exception('响应缺少 sessionId');
      // 新会话立即本地登记（带所选 cwd）——否则列表里显示「未分组」（store 占位行 cwd 为空）
      if (pickedCwd != null) {
        await StoreService.shared.upsertSessions(_dshId, [
          StoredSession(id: sessionId, dshId: _dshId, title: '新会话', cwd: pickedCwd!, updatedAt: DateTime.now().millisecondsSinceEpoch),
        ]);
      }
      if (pickedProvider != null && pickedModel != null) {
        unawaited(
          api.rpc('session.selectModel', {
            'sessionId': sessionId,
            'provider': pickedProvider,
            'model': pickedModel,
          }, timeout: const Duration(seconds: 15)),
        );
      }
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => SessionChatPage(sessionId: sessionId, title: '新会话'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('新建会话失败: $e')));
    }
  }

  /// 通用单选项 sheet。
  Future<T?> _pickSheetItem<T>({
    required String title,
    required List<T?> options,
    required String Function(T?) label,
    required T? selected,
  }) async {
    return showModalBottomSheet<T?>(
      context: context,
      backgroundColor: Ui.bg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (c) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: Ui.ink,
                ),
              ),
            ),
            for (final opt in options)
              ListTile(
                leading: opt == selected
                    ? Icon(Icons.check, size: 18, color: Ui.accent)
                    : Icon(
                        Icons.circle_outlined,
                        size: 18,
                        color: Ui.inkMuted,
                      ),
                title: Text(
                  label(opt),
                  style: TextStyle(fontSize: 14, color: Ui.ink),
                ),
                onTap: () => Navigator.pop(c, opt),
              ),
          ],
        ),
      ),
    );
  }

  /// 模型二级选择（provider → model）。
  Future<(String, String)?> _pickModelSheet() async {
    final api = _api;
    if (api == null) return null;
    final res = await api.rpc(
      'llm.providers',
      {},
      timeout: const Duration(seconds: 10),
    );
    final providers = (res['providers'] as List? ?? const [])
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList();
    final providerId = await _pickSheetItem<String>(
      title: '选择供应商',
      options: providers.map((p) => p['id']?.toString()).toList(),
      label: (v) {
        final m = providers.where((p) => p['id']?.toString() == v).firstOrNull;
        return (m?['name'] ?? v ?? '?').toString();
      },
      selected: providers.isNotEmpty ? providers.first['id']?.toString() : null,
    );
    if (providerId == null) return null;
    final mres = await api.rpc('llm.models', {
      'provider': providerId,
    }, timeout: const Duration(seconds: 10));
    final models = (mres['models'] as List? ?? const [])
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList();
    final modelId = await _pickSheetItem<String>(
      title: '选择模型 · $providerId',
      options: models.map((m) => m['id']?.toString()).toList(),
      label: (v) {
        final m = models.where((x) => x['id']?.toString() == v).firstOrNull;
        return (m?['name'] ?? v ?? '?').toString();
      },
      selected: models.isNotEmpty ? models.first['id']?.toString() : null,
    );
    if (modelId == null) return null;
    return (providerId, modelId);
  }

  Future<void> _pickDsh() async {
    final state = _state;
    final candidates = state.pairings.where((p) => p.access != null).toList();
    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('暂无可操作的配对 dsh（等待 pairings 拉取或 dsh 上线）')),
      );
      return;
    }
    final selected = await showModalBottomSheet<DeviceInfo>(
      context: context,
      backgroundColor: Ui.bg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: Text(
                '切换设备',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: Ui.ink,
                ),
              ),
            ),
            for (final p in candidates)
              ListTile(
                leading: p.dsh.deviceId == state.joinedDsh?.deviceId
                    ? Icon(Icons.check_circle, color: Ui.ink, size: 20)
                    : Icon(
                        Icons.computer_outlined,
                        color: Ui.inkMuted,
                        size: 20,
                      ),
                title: Text(
                  p.dsh.name,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Ui.ink,
                  ),
                ),
                subtitle: Text(
                  'dsh 节点',
                  style: TextStyle(fontSize: 12, color: Ui.inkMuted),
                ),
                onTap: () => Navigator.pop(c, p.dsh),
              ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
    if (selected != null) {
      await state.selectJoinedDsh(selected);
      if (mounted) {
        setState(() {
          _activeSessionId = null;
          _activeSessionTitle = null;
        });
      }
    }
  }

  // ---------- 分组 ----------

  String _projectName(String cwd) {
    if (cwd.isEmpty) return '未分组';
    final parts = cwd.split('/').where((x) => x.isNotEmpty).toList();
    return parts.isEmpty ? '未分组' : parts.last;
  }

  List<({String name, String cwd, List<StoredSession> rows})> _buildGroups() {
    final q = _query.trim().toLowerCase();
    final visibleSessions = _sessions.where((s) {
      if (q.isEmpty) return true;
      return s.title.toLowerCase().contains(q) ||
          s.id.toLowerCase().contains(q);
    }).toList();
    // 主会话分组；子会话挂在同组里（样式区分），与桌面版一致以最近活跃排序。
    final groups = <String, List<StoredSession>>{};
    for (final s in visibleSessions) {
      final name = _projectName(s.cwd);
      (groups[name] ??= []).add(s);
    }
    final names = groups.keys.toList()
      ..sort((a, b) {
        final ma = groups[a]!.fold<int>(
          0,
          (p, s) => s.updatedAt > p ? s.updatedAt : p,
        );
        final mb = groups[b]!.fold<int>(
          0,
          (p, s) => s.updatedAt > p ? s.updatedAt : p,
        );
        return mb.compareTo(ma);
      });
    return [
      for (final n in names)
        (
          name: n,
          cwd: '',
          rows: groups[n]!..sort((a, b) => b.updatedAt.compareTo(a.updatedAt)),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final dshName = _state.joinedDsh?.name ?? '未选择 dsh';
    // 宽屏双栏：头部 + 搜索 + 列表 整体作为左列面板；窄屏原样。
    final listPane = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 12, 6),
          child: Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: _pickDsh,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          dshName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.w700,
                            color: Ui.ink,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        Icons.expand_more,
                        size: 22,
                        color: Ui.inkMuted,
                      ),
                    ],
                  ),
                ),
              ),
              if (_refreshing)
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 10),
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Ui.inkMuted,
                    ),
                  ),
                )
              else
                IconButton(
                  icon: Icon(Icons.refresh, size: 21, color: Ui.inkMuted),
                  onPressed: _refresh,
                ),
              _circleAction(
                icon: Icons.add,
                onPressed: _newSession,
                tooltip: '新会话',
              ),
            ],
          ),
        ),
        // 搜索框
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
          child: SizedBox(
            height: 38,
            child: TextField(
              controller: _searchCtrl,
              onChanged: (v) => setState(() => _query = v),
              style: TextStyle(fontSize: 14, color: Ui.ink),
              decoration: InputDecoration(
                hintText: '搜索会话',
                hintStyle: TextStyle(color: Ui.inkMuted, fontSize: 14),
                prefixIcon: Icon(
                  Icons.search,
                  size: 18,
                  color: Ui.inkMuted,
                ),
                filled: true,
                fillColor: Ui.bgSubtle,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: Icon(
                          Icons.close,
                          size: 16,
                          color: Ui.inkMuted,
                        ),
                        onPressed: () {
                          _searchCtrl.clear();
                          setState(() => _query = '');
                        },
                      ),
              ),
            ),
          ),
        ),
        Expanded(
          child: _error != null && _sessions.isEmpty
              ? _errorView()
              : RefreshIndicator(
                  onRefresh: _refresh,
                  color: Ui.ink,
                  child: _sessions.isEmpty
                      ? ListView(
                          children: [
                            Padding(
                              padding: EdgeInsets.all(40),
                              child: Center(
                                child: Text(
                                  '暂无会话',
                                  style: TextStyle(
                                    color: Ui.inkMuted,
                                    fontSize: 15,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        )
                      : _groupedList(),
                ),
        ),
      ],
    );
    return Scaffold(
      backgroundColor: Ui.bg,
      body: SafeArea(child: _paneOrSplit(listPane)),
    );
  }

  // ---------- 宽屏双栏（2026-09-06：与 Stitch 右侧呼应对齐） ----------

  /// 宽屏（>=720）时点击会话不跳页，而是在右侧打开聊天面板（左列表保持）。
  bool get _wide => MediaQuery.of(context).size.width >= 720;

  void _openChat(StoredSession s) {
    final title = s.title.isNotEmpty
        ? s.title
        : (s.id.length > 12 ? '${s.id.substring(0, 12)}…' : s.id);
    if (_wide) {
      setState(() {
        _activeSessionId = s.id;
        _activeSessionTitle = title;
      });
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SessionChatPage(sessionId: s.id, title: title),
      ),
    );
  }

  /// 宽屏容器：Row(左列表 340 + 分隔线 + 右聊天)。窄屏退回普通列表。
  Widget _paneOrSplit(Widget listPane) {
    if (!_wide) return listPane;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(width: 340, child: listPane),
        Container(width: 1, color: Ui.separator),
        Expanded(
          child: _activeSessionId == null
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.forum_outlined, size: 52, color: Ui.inkMuted),
                      SizedBox(height: 16),
                      Text(
                        '选择一个会话',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: Ui.ink,
                        ),
                      ),
                      SizedBox(height: 6),
                      Text(
                        '右侧将在此处打开对话内容',
                        style: TextStyle(fontSize: 13, color: Ui.inkMuted),
                      ),
                    ],
                  ),
                )
              : SessionChatPage(
                  key: ValueKey(_activeSessionId),
                  sessionId: _activeSessionId!,
                  title: _activeSessionTitle ?? '会话',
                ),
        ),
      ],
    );
  }

  Widget _circleAction({
    required IconData icon,
    required VoidCallback onPressed,
    String? tooltip,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Tooltip(
        message: tooltip ?? '',
        child: Material(
          color: Ui.accent,
          borderRadius: BorderRadius.circular(18),
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: onPressed,
            child: SizedBox(
              width: 36,
              height: 36,
              child: Icon(Icons.add, size: 20, color: Ui.accentOn),
            ),
          ),
        ),
      ),
    );
  }

  /// 分组列表：组头（项目名 + 条数 + 折叠）→ 预览 5 条 → 「显示全部」。
  Widget _groupedList() {
    final groups = _buildGroups();
    if (groups.isEmpty) {
      return ListView(
        children: [
          Padding(
            padding: EdgeInsets.all(40),
            child: Center(
              child: Text(
                '无匹配会话',
                style: TextStyle(color: Ui.inkMuted, fontSize: 15),
              ),
            ),
          ),
        ],
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: groups.length,
      itemBuilder: (_, gi) {
        final g = groups[gi];
        final isCollapsed = _collapsed.contains(g.name);
        final full = _expanded.contains(g.name) || _query.trim().isNotEmpty;
        final mainRows = g.rows
            .where((s) => s.parentSessionId == null)
            .toList();
        final subRows = g.rows.where((s) => s.parentSessionId != null).toList();
        // 展示行：主会话在前 + （展开时的）子会话；折叠时只显示组头。
        final shownMain = full
            ? mainRows
            : mainRows.take(_kPreviewCount).toList();
        final display = [...shownMain, if (full) ...subRows];
        final total = mainRows.length + subRows.length;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 组头：项目名 + 条数，点击折叠/展开
            InkWell(
              onTap: () => setState(() {
                if (isCollapsed) {
                  _collapsed.remove(g.name);
                } else {
                  _collapsed.add(g.name);
                  _expanded.remove(g.name);
                }
              }),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                child: Row(
                  children: [
                    Icon(
                      isCollapsed ? Icons.expand_more : Icons.expand_less,
                      size: 18,
                      color: Ui.inkMuted,
                    ),
                    const SizedBox(width: 2),
                    Text(
                      g.name,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Ui.inkSecondary,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '$total',
                      style: TextStyle(fontSize: 12, color: Ui.inkMuted),
                    ),
                    if (subRows.isNotEmpty && !isCollapsed && !full) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: Ui.bgSubtle,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '含 ${subRows.length} 子智能体',
                          style: TextStyle(
                            fontSize: 10,
                            color: Ui.inkMuted,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (!isCollapsed) ...[
              for (final s in display) _sessionRow(s),
              if (!full && mainRows.length > _kPreviewCount)
                TextButton(
                  onPressed: () => setState(() => _expanded.add(g.name)),
                  child: Text(
                    '显示全部 ${mainRows.length} 条',
                    style: TextStyle(
                      fontSize: 13,
                      color: Ui.inkSecondary,
                    ),
                  ),
                ),
              if (full && subRows.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 6, 20, 2),
                  child: Text(
                    '子智能体会话（${subRows.length}）',
                    style: TextStyle(fontSize: 11, color: Ui.inkMuted),
                  ),
                ),
            ],
            if (gi < groups.length - 1) const SizedBox(height: 10),
          ],
        );
      },
    );
  }

  Widget _sessionRow(StoredSession s) {
    final isSub = s.parentSessionId != null;
    final isActive = _activeSessionId == s.id;
    final title = s.title.isNotEmpty
        ? s.title
        : (s.id.length > 12 ? '${s.id.substring(0, 12)}…' : s.id);
    return InkWell(
      onTap: () {
        if (isSub) {
          // host 尚未挂载 subagent.* API（实测 404）：给出说明而非空白页。
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                '子智能体会话：当前 host 版本未开放移动端读取（需升级 dsh 的 subagents API），请在桌面端查看',
              ),
            ),
          );
          return;
        }
        _openChat(s);
      },
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
        decoration: BoxDecoration(
          color: isActive ? Ui.bubbleUser : Ui.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isActive ? Ui.accent : Ui.separator,
            width: isActive ? 1.4 : 1,
          ),
        ),
        child: Padding(
          padding: EdgeInsets.only(
            left: isSub ? 40 : 12,
            right: 12,
            top: 10,
            bottom: 10,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 行首图标 tile：主会话 chat / 子智能体 robot
              Container(
                width: 38,
                height: 38,
                margin: const EdgeInsets.only(right: 12, top: 2),
                decoration: BoxDecoration(
                  color: isSub ? Ui.bgSubtle : Ui.bubbleUser,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  isSub ? Icons.smart_toy_outlined : Icons.chat_bubble_outline,
                  size: isSub ? 16 : 18,
                  color: isSub ? Ui.inkMuted : Ui.accent,
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: isSub ? 13 : 15,
                        fontWeight: FontWeight.w600,
                        color: isSub ? Ui.inkMuted : Ui.ink,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        if (!isSub && s.messageCount > 0) ...[
                          Text(
                            '${s.messageCount} 条消息',
                            style: TextStyle(
                              fontSize: 12,
                              color: Ui.inkMuted,
                            ),
                          ),
                          Padding(
                            padding: EdgeInsets.symmetric(horizontal: 6),
                            child: Text(
                              '·',
                              style: TextStyle(
                                fontSize: 12,
                                color: Ui.inkMuted,
                              ),
                            ),
                          ),
                        ],
                        Text(
                          s.updatedAt > 0 ? relativeTime(s.updatedAt) : '—',
                          style: TextStyle(
                            fontSize: 12,
                            color: Ui.inkMuted,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (isSub)
                Container(
                  margin: const EdgeInsets.only(top: 6),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: Ui.bgSubtle,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '子',
                    style: TextStyle(
                      fontSize: 10,
                      color: Ui.inkMuted,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _errorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.cloud_off_outlined, color: Ui.inkMuted, size: 44),
            const SizedBox(height: 14),
            SelectableText(
              _error!,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: Ui.inkSecondary),
            ),
            const SizedBox(height: 14),
            TextButton(
              onPressed: _refresh,
              child: Text(
                '重试',
                style: TextStyle(
                  color: Ui.ink,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 相对时间（列表页副标题）：刚刚 / N 分钟前 / N 小时前 / 昨天 / M-d / yyyy-MM-dd。
String relativeTime(int ms) {
  if (ms <= 0) return '';
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  final now = DateTime.now();
  final diff = now.difference(t);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
  if (diff.inHours < 24 && now.day == t.day) return '${diff.inHours} 小时前';
  if (diff.inDays == 1) return '昨天';
  if (t.year == now.year)
    return '${t.month}-${t.day.toString().padLeft(2, '0')}';
  return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
}
