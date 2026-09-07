// dsh-federation — 会话聊天页（PAIRING-SPEC §5）：本地库优先 + 网络增量合并 + SSE 流式
// 数据流：打开先读本地库渲染 → rpc session.history(50) 按 seq 去重合并入库 → SSE 增量照旧
// （lastSeq 推进时消息级事件同步写库）；发送回显即写库（负 seq 临时行，确认后清除）。
// HostSession 来自 joinedDsh 的配对凭证（不再要求用户手动绑定）。
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:image_picker/image_picker.dart';

import '../theme.dart';
import 'federation_state.dart';
import 'groupchat.dart';
import 'host_events.dart';
import 'image_cache.dart';
import 'local_api.dart';
import 'local_settings.dart';
import 'native_bridge.dart';
import 'session_list_page.dart' show Ui;
import 'store/local_store.dart';

class SessionChatPage extends StatefulWidget {
  const SessionChatPage({
    super.key,
    required this.sessionId,
    required this.title,
  });

  final String sessionId;
  final String title;

  @override
  State<SessionChatPage> createState() => _SessionChatPageState();
}

class _ChatEntry {
  _ChatEntry({
    required this.role,
    required this.text,
    this.tool = false,
    this.detail,
    this.images = const [],
    this.ts = 0,
    this.children,
  });
  final String role;
  final String text;
  final bool tool;
  final int ts; // 消息时间（毫秒）；0=不显示

  /// 工具组：相邻工具调用折叠为一个组（点击展开显示 children）。
  final List<_ChatEntry>? children;

  /// 工具详情的原始载荷（arguments/result 等），供点击展开与复制。
  final String? detail;

  /// 消息内图片（已解码字节）：气泡内缩略预览，避免「忘了发了哪张」。
  final List<Uint8List> images;
}

/// 待批工具（approval/requested 帧的域字段 + 应答密钥 rpcId）。
class _ApprovalPending {
  _ApprovalPending({
    required this.rpcId,
    required this.approvalId,
    required this.toolName,
    this.reason,
  });
  final String rpcId;
  final String approvalId;
  final String toolName;
  final String? reason;
}

/// 待答提问（question/requested 帧）。
class _QuestionPending {
  _QuestionPending({required this.rpcId, required this.items});
  final String rpcId;
  final List<Map<String, dynamic>> items;
}

class _SessionChatPageState extends State<SessionChatPage> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final List<_ChatEntry> _entries = [];
  String _liveAssistant = '';
  bool _liveAssistantActive = false;
  bool _groupView = false;
  bool _showToolCalls = true;
  bool _loading = true;
  int _sendingCount = 0;
  bool _sending = false;
  int _lastSendTryMs = 0;
  double _drawerOffset = 0; // 抽屉跟手偏移（0=关，0.7w=开）
  bool _drawerActive = false;
  bool _drawerDragging = false;
  String? _error;
  Timer? _pollTimer;
  Timer? _sseRetry;
  bool _sseUp = false;
  int _pollCounter = 0;
  int _lastSeq = 0;

  /// SSE 断线重试的当前退避秒数（成功进入 subscribed 后重置为 3）。
  int _sseRetryDelay = 3;

  /// 是否贴底自动滚动：用户在消息区上滑看历史时置 false（流式不再抢滚动），
  /// 滑回底部或点「回到底部」浮钮后置 true。
  bool _stickBottom = true;

  /// 待处理的工具审批（从 approval/requested 帧来，可应答）。
  _ApprovalPending? _approval;

  /// 待回答的提问（question/requested 帧）。
  _QuestionPending? _question;

  /// 待处理的提问表单草稿：questionId → 已选 label 列表（无选项时为 [自定义文本空串]）。
  final Map<String, List<String>> _qAnswers = {};

  /// agent 收件箱待处理消息数（session/queue 镜像；只做提示条，不混入消息流——
  /// 混入的消息在 30s 库重建后会被清走，表现为「消息凭空消失」）。
  int _queueCount = 0;

  /// 排队中（inbox 待处理）的消息条目：id + 文本。渲染可见 + 每条可插队。
  List<({String id, String text})> _queueItems = const [];

  String get _dshId => FederationState.instance.joinedDsh?.deviceId ?? '';

  /// App 是否在前台（决定回复完成要不要发系统通知）。
  bool get _appInForeground =>
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  HostSessionService? get _api => FederationState.instance.hostApi();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _loadLocal().then((_) => _loadRemote(initial: true));
    // 兜底轮询（5s 一个 tick）：SSE 正常时 30s 慢速对账（防半开连接静默丢帧），
    // SSE 断开时 5s 快速轮询顶上。
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _pollCounter++;
      if (!_sseUp || _pollCounter >= 6) {
        _pollCounter = 0;
        _loadRemote();
      }
    });
    _connectSse();
  }

  /// 用户在消息区手动滑动 → 更新「贴底」状态（上滑看历史时流式不再抢滚动）。
  /// 只认用户手势：SSE 内容增长导致的 maxScrollExtent 变化（userScrollDirection 为
  /// idle）不触发贴底失效——否则浮钮会在自动滚动时误常驻。
  void _onScroll() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    if (pos.userScrollDirection == ScrollDirection.idle) return;
    final nearBottom = pos.maxScrollExtent - pos.pixels < 80;
    if (nearBottom != _stickBottom && mounted) {
      setState(() => _stickBottom = nearBottom);
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _sseRetry?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // ---------- 本地库（首屏与合并基线） ----------

  /// 打开即读库渲染（离线/弱网也有历史），并取已确认的最大 seq 作为去重水位。
  Future<void> _loadLocal() async {
    final rows = await StoreService.shared.messages(widget.sessionId);
    // 注意：short id（如 mock 的 "s1"）也会走到这里，substring 越界会抛 RangeError
    // 卡死 loading 态——先截长度再切片。
    final idPreview = widget.sessionId.length > 20
        ? widget.sessionId.substring(0, 20)
        : widget.sessionId;
    debugPrint('[chat] loadLocal session=$idPreview rows=${rows.length}');
    if (!mounted) return;
    setState(() {
      _entries
        ..clear()
        ..addAll(
          rows.map(
            (m) => _ChatEntry(
              role: m.role,
              text: _extractText(m.content),
              images: _extractImages(m.content),
              ts: m.ts,
            ),
          ),
        );
      _lastSeq = rows.fold<int>(0, (a, m) => m.seq > a ? m.seq : a);
      _loading = false;
    });
    // 首屏：本地行渲染出来后立即停在最新处（force 忽略贴底状态），
    // 之后的 loadRemote 完成时再滚一次——避免「先看到中间→闪到底」。
    _scrollToBottom(force: true);
  }

  /// 网络刷新：session.history(50) → 归一化 → 幂等入库（按 seq）→ 从库重渲染。
  Future<void> _loadRemote({bool initial = false}) async {
    final api = _api;
    if (api == null) {
      if (initial && mounted) setState(() => _error = '未选择目标 dsh');
      return;
    }
    try {
      // 增量：非首次同步携带 beforeSeq（仅取新帧，KB 级）；首次全量 50 条
      final payload = {
        'sessionId': widget.sessionId,
        'maxMessages': 50,
        if (!initial && _lastSeq > 0) 'beforeSeq': _lastSeq,
      };
      final res = await api.rpc('session.history', payload);
      // 真实 host：events:[{event:{...}}]；mock：entries:[{role,text,seq}]
      final raw =
          (res['events'] as List? ??
          res['entries'] as List? ??
          res['history'] as List? ??
          []);
      final dshId = _dshId;
      final messages = historyEntriesToMessages(
        raw,
        sessionId: widget.sessionId,
        dshId: dshId,
      );
      debugPrint(
        '[chat] loadRemote session=${widget.sessionId} raw=${raw.length} → 入库=${messages.length}',
      );
      await StoreService.shared.upsertMessages(
        dshId,
        widget.sessionId,
        messages,
      );
      // 历史同步后合并清理：已确认的同文本回显删除（旧消息「一直出现/沉底」根因）
      await StoreService.shared.removeEchoesMatchingConfirmed(widget.sessionId);
      // 兜底：30 分钟未确认的旧回显（纯图/漏确认）清掉——避免「永沉底」
      await StoreService.shared.removeStaleEchoes(
        widget.sessionId,
        olderThanMs: 30 * 60 * 1000,
      );
      if (!mounted) return;
      await _renderFromStore();
      setState(() => _error = null);
      if (initial) _scrollToBottom();
    } catch (e) {
      debugPrint('[chat] loadRemote 失败: $e');
      if (!mounted) return;
      if (initial && _entries.isEmpty) {
        final msg = e.toString().contains('agent-busy')
            ? '这是子智能体（subagent）会话：host 不允许移动端直接读取其历史，请在桌面端查看。'
            : '$e';
        setState(() {
          _loading = false;
          _error = msg;
        });
      }
    }
  }

  /// 以本地库为准整体重建消息区。
  /// 注意：**不重置 _liveAssistant**——30s 对账/重连补拉期间 agent 正在流式
  /// 回复（chunk 只在终态 assistant/message 时才入库），清掉会让屏幕闪空/丢字。
  Future<void> _renderFromStore() async {
    final rows = await StoreService.shared.messages(widget.sessionId);
    debugPrint('[chat] renderFromStore rows=${rows.length}');
    if (!mounted) return;
    // 归一化文本（去 📷 前缀）：同文本确认行存在 → 回显行过滤（UI 兜底，
    // 即使 db 清理未跑也不出现「沉底/重复」——图片消息的 📷 前缀曾导致匹配失败）
    String norm(String t) => t.replaceAll(RegExp(r'📷\s*图片'), '').trim();
    final confirmed = rows
        .where((m) => m.seq >= 0 && m.role == 'user')
        .map((m) => norm(_extractText(m.content)))
        .where((t) => t.isNotEmpty)
        .toSet();
    bool isPluginRow(StoredMessage m) {
      final msgg = m.content['message'];
      if (msgg is Map) {
        final src = msgg['source'];
        if (src is Map && src['kind']?.toString() == 'plugin') return true;
      }
      return false;
    }

    final visible = rows
        .where((m) => !isPluginRow(m))
        .where(
          (m) =>
              !(m.seq < 0 &&
                  m.role == 'user' &&
                  confirmed.contains(norm(_extractText(m.content)))),
        )
        .toList();
    setState(() {
      _entries
        ..clear()
        ..addAll(
          visible.map(
            (m) => _ChatEntry(
              role: m.role,
              text: _extractText(m.content),
              images: _extractImages(m.content),
              ts: m.ts,
            ),
          ),
        );
      _lastSeq = rows.fold<int>(0, (a, m) => m.seq > a ? m.seq : a);
    });
  }

  // ---------- SSE ----------

  Future<void> _connectSse() async {
    try {
      final api = _api;
      if (api == null || !mounted) return;
      // SSE 基址 = 该 dsh 的 HostSession.baseUrl（与 rpc 同源同 cookie）
      final session = await api.ensure();
      if (!mounted) return;
      final stream = HostEventsStream(session: session).open('/api/events.mux');
      await for (final frame in stream) {
        if (!mounted) return;
        if (frame.sessionId != widget.sessionId) continue;
        _onFrame(frame);
      }
      // 流结束/断开
      _sseUp = false;
      if (mounted) _scheduleSseRetry();
    } catch (_) {
      _sseUp = false;
      if (mounted) _scheduleSseRetry();
    }
  }

  void _scheduleSseRetry() {
    _sseRetry?.cancel();
    final delay = _sseRetryDelay;
    // 固定 3s 在 host 长期不可达时会打爆连接；指数退避（3→6→12→24→48→60s 封顶）
    _sseRetryDelay = (_sseRetryDelay * 2).clamp(3, 60);
    _sseRetry = Timer(Duration(seconds: delay), () {
      if (mounted) _connectSse();
    });
  }

  void _onFrame(MuxFrame frame) {
    switch (frame.type) {
      case 'session/subscribed':
        _sseUp = true;
        _sseRetryDelay = 3; // 连通即重置退避
        if (frame.lastSeq != null && frame.lastSeq! > _lastSeq)
          _lastSeq = frame.lastSeq!;
        break;

      case 'session/event':
        final ev = frame.event;
        if (ev == null) break;
        final seq = (ev['seq'] as num?)?.toInt() ?? 0;
        if (seq <= _lastSeq) break; // 重复/乱序跳过
        _lastSeq = seq;
        _applyEvent(ev, seq);
        break;

      case 'session/queue':
        // 收件箱镜像：排队消息对用户必须可见（agent 忙时消息无 user/message 终态、
        // history 也没有——只报计数=「消息消失」）。渲染每条文本 + 可插队。
        if (mounted) {
          final items = frame.queueItems ?? const <Map<String, dynamic>>[];
          setState(() {
            _queueCount = items.length;
            _queueItems = items
                .map((e) {
                  final msg = e['message'];
                  final text = msg is Map
                      ? _extractText(msg.cast<String, dynamic>())
                      : '';
                  return (id: e['id']?.toString() ?? '', text: text);
                })
                .where((x) => x.id.isNotEmpty)
                .toList();
          });
        }
        break;

      case 'approval/requested':
        // 注意：toolName/reason 在帧顶层（不是 event 里）——旧实现读错字段，
        // 审批通知里工具名永远是空的。
        setState(() {
          _approval = _ApprovalPending(
            rpcId: frame.rpcId ?? '',
            approvalId: frame.approvalId ?? '',
            toolName: frame.toolName ?? '未知工具',
            reason: frame.reason,
          );
        });
        _notify('⚠️ 工具「${frame.toolName ?? '?'}」请求执行');
        if (LocalSettings.notify) {
          unawaited(
            NativeBridge.notify(
              'DSH 审批请求',
              '「${widget.title}」请求使用工具 ${frame.toolName ?? '?'}${frame.reason != null ? '：${frame.reason}' : ''}，点开处理',
              sessionId: widget.sessionId,
            ),
          );
        }
        break;

      case 'approval/resolved':
        if (_approval != null &&
            frame.approvalId != null &&
            frame.approvalId == _approval!.approvalId) {
          setState(() => _approval = null);
          _notify(frame.outcome == 'allowed-once' ? '✅ 工具已获准执行' : '工具请求已拒绝/取消');
        }
        break;

      case 'question/requested':
        setState(() {
          _question = _QuestionPending(
            rpcId: frame.rpcId ?? '',
            items: frame.questions ?? const [],
          );
          _qAnswers.clear();
        });
        _notify('❓ Agent 等待你的回答');
        if (LocalSettings.notify) {
          unawaited(
            NativeBridge.notify(
              'DSH 需要你的回答',
              '「${widget.title}」的 agent 提出了问题，点开回答',
              sessionId: widget.sessionId,
            ),
          );
        }
        break;

      case 'question/resolved':
        if (_question != null &&
            frame.questionRpcId != null &&
            frame.questionRpcId == _question!.rpcId) {
          setState(() {
            _question = null;
            _qAnswers.clear();
          });
        }
        break;
    }
  }

  void _applyEvent(Map<String, dynamic> ev, int seq) {
    final type = ev['type']?.toString() ?? '';
    final data = ev['data'];
    final dataMap = data is Map
        ? data.cast<String, dynamic>()
        : <String, dynamic>{};
    if (type == 'user/message' || type == 'assistant/message') {
      // 双形状兼容：实时=message 包装；history（经库渲染）已统一包装——这里同样兜底
      final message = dataMap['message'] is Map
          ? (dataMap['message'] as Map).cast<String, dynamic>()
          : dataMap;
      {
        final source = message['source'];
        if (source is Map && source['kind']?.toString() == 'plugin')
          return; // 系统注入不渲染
        final text = _extractText(message.cast<String, dynamic>());
        if (text.isNotEmpty) {
          final role = type.startsWith('user') ? 'user' : 'assistant';
          setState(() {
            if (role == 'user') {
              // 用户消息 = 上一轮结束：把残留的 live 预览落成正式气泡。
              _flushLiveAssistant();
              if (_liveAssistantActive) _liveAssistantActive = false;
              // 先删 UI 回显再加确认行——否则同屏两条（重复闪现），等轮询才合并
              _entries.removeWhere((x) => x.role == 'user' && x.text == text);
            } else {
              // 终态 assistant/message 携带完整文本：live 只是分块预览，
              // 丢弃预览直接插终态，否则同一条回复显示两遍（真实 host 必现）。
              _liveAssistant = '';
              _liveAssistantActive = false;
            }
            _entries.add(
              _ChatEntry(
                role: role,
                text: text,
                images: _extractImages(message),
                ts: (ev['time'] as num?)?.toInt() ?? 0,
              ),
            );
          });
          _scrollToBottom();
          // 消息级终态：写库（user 先清同文本回显临时行）
          _persistMessage(seq, role, {
            'message': message,
          }, confirmText: role == 'user' ? text : null);
          // 回复完成：仅 App 不在前台时发系统通知（前台有 SnackBar/页面本身，避免打扰）。
          if (role == 'assistant' && !_appInForeground) {
            final preview = text.length > 60
                ? '${text.substring(0, 60)}…'
                : text;
            if (LocalSettings.notify) {
              unawaited(
                NativeBridge.notify(
                  'DSH 回复完成',
                  '「${widget.title}」：$preview',
                  sessionId: widget.sessionId,
                ),
              );
            }
          }
        }
      }
      return;
    }
    if (type == 'approval/asked') {
      // 真实 host 事件 → 复用现有审批状态机（approval/requested 帧语义）
      final f = MuxFrame.parse({
        'type': 'approval/requested',
        'sessionId': widget.sessionId,
        'approvalId': dataMap['id']?.toString() ?? '',
        'toolName': dataMap['toolName']?.toString() ?? '未知工具',
        if (dataMap['reason'] != null) 'reason': dataMap['reason'],
      });
      if (f != null) _onFrame(f);
      return;
    }
    if (type == 'approval/decided') {
      final f = MuxFrame.parse({
        'type': 'approval/resolved',
        'sessionId': widget.sessionId,
        'approvalId': dataMap['id']?.toString() ?? '',
        'outcome': dataMap['outcome']?.toString(),
      });
      if (f != null) _onFrame(f);
      return;
    }
    if (type.startsWith('agent/inbox/')) {
      // 真实 host 的排队数据：agent/inbox/spliced → inserted[] = UserMessage（排队消息）
      // compat/mock 的标准 queue 帧走 MuxFrame 通道；此处兜底同一事件流
      final inserted = dataMap['inserted'];
      if (inserted is List) {
        final items = inserted
            .whereType<Map>()
            .map(
              (m) => (
                id: m['id']?.toString() ?? '',
                text: _extractText(m.cast<String, dynamic>()),
              ),
            )
            .where((x) => x.id.isNotEmpty)
            .toList();
        if (mounted) {
          setState(() {
            _queueCount = items.length;
            _queueItems = items;
          });
        }
      }
      return;
    }
    if (type.endsWith('/text') && type.startsWith('assistant')) {
      final text = dataMap['text']?.toString() ?? '';
      if (text.isNotEmpty) {
        setState(() {
          _liveAssistantActive = true;
          _liveAssistant += text;
        });
        _scrollToBottom();
      }
      return;
    }
    // 真实 host 的流式增量：assistant/chunk（data.chunk.type="text-delta"，text 字段）。
    // （mock/compat 层则翻译成 assistant/text——两条路径都支持。）
    if (type == 'assistant/chunk') {
      final chunk = dataMap['chunk'];
      if (chunk is Map) {
        final t = chunk['type']?.toString();
        final text = chunk['text']?.toString() ?? '';
        // text-delta = 可见正文增量；reasoning-delta/tool-call 暂不渲染
        if (t == 'text-delta' && text.isNotEmpty) {
          setState(() {
            _liveAssistantActive = true;
            _liveAssistant += text;
          });
          _scrollToBottom();
        }
      }
      return;
    }
    if (type == 'assistant/error' || type == 'stream/error') {
      final message = dataMap['message']?.toString() ?? 'agent 出错';
      setState(() {
        _flushLiveAssistant();
        _entries.add(
          _ChatEntry(role: 'assistant', text: '⚠️ $message', tool: true),
        );
      });
      if (LocalSettings.notify)
        unawaited(
          NativeBridge.notify(
            'DSH 任务失败',
            '「${widget.title}」：$message',
            sessionId: widget.sessionId,
          ),
        );
      return;
    }
    // 工具事件全量入档：call 带 arguments（完整命令），result 带 content。
    if (type == 'tool/call' || type == 'tool/result') {
      final name = dataMap['name']?.toString() ?? type;
      final args = dataMap['arguments']?.toString() ?? '';
      final isResult = type == 'tool/result';
      final content = isResult ? _toolResultText(dataMap) : '';
      final summary = isResult
          ? (content.isNotEmpty
                ? '↩ $content'
                : '↩ ${dataMap['message']?['callId'] ?? '结果'}')
          : '🔧 $name${args.isNotEmpty ? ' ${_brief(args)}' : ''}';
      final detail = StringBuffer()
        ..writeln(isResult ? '结果' : '工具：$name')
        ..writeln()
        ..write(
          isResult
              ? (content.isNotEmpty ? content : '(无文本结果)')
              : (args.isNotEmpty ? args : '(无参数)'),
        );
      setState(() {
        if (isResult) {
          // 结果挂到最近一条 tool/call 未带结果的条目上（按 callId 匹配失败则新增）
          final idx = _entries.lastIndexWhere(
            (e) =>
                e.tool &&
                e.role == 'tool' &&
                (e.detail == null || !e.detail!.startsWith('结果')),
          );
          if (idx >= 0 && _entries[idx].text.startsWith('🔧')) {
            _entries[idx] = _ChatEntry(
              role: 'tool',
              text: _entries[idx].text,
              tool: true,
              detail:
                  '${_entries[idx].detail ?? ''}\n\n===== 结果 =====\n${content.isNotEmpty ? content : '(无文本结果)'}',
            );
          } else {
            _entries.add(
              _ChatEntry(
                role: 'tool',
                text: summary,
                tool: true,
                detail: detail.toString(),
              ),
            );
          }
        } else {
          _entries.add(
            _ChatEntry(
              role: 'tool',
              text: summary,
              tool: true,
              detail: detail.toString(),
            ),
          );
        }
      });
      _scrollToBottom();
      _persistMessage(seq, 'tool', {'name': name, 'arguments': args});
    }
    // 其余类型（agent 内部状态等）：v1 不渲染，仅推进 seq
  }

  /// 取消息 content 里的图片字节（image 块的 data=base64 时解码；无 data 返回空）。
  static List<Uint8List> _extractImages(Map<String, dynamic> content) {
    final msg = content['message'] is Map
        ? (content['message'] as Map)
        : content;
    final blocks = msg['content'] is List ? (msg['content'] as List) : const [];
    final out = <Uint8List>[];
    for (final b in blocks) {
      if (b is! Map) continue;
      if (b['type']?.toString() != 'image') continue;
      final data = b['data']?.toString() ?? '';
      if (data.isNotEmpty) {
        try {
          out.add(base64Decode(data));
        } catch (_) {}
        continue;
      }
      // 历史消息的 attachment 引用：attachmentId = sha256:hex → 本地缓存命中则显示缩略图
      final att = b['attachment'];
      if (att is Map) {
        final id = att['attachmentId']?.toString() ?? '';
        final hex = id.startsWith('sha256:') ? id.substring(7) : id;
        final cached = ImageCacheStore.get(hex);
        if (cached != null) out.add(cached);
      }
    }
    return out;
  }

  static String _brief(String s) =>
      s.length > 80 ? '${s.substring(0, 80)}…' : s;

  /// tool/result 事件的可展示文本（message.content 文本块拼装）。
  static String _toolResultText(Map<String, dynamic> dataMap) {
    final message = dataMap['message'];
    if (message is! Map) return '';
    final content = message['content'];
    if (content is String) return content;
    if (content is List) {
      final buf = StringBuffer();
      for (final part in content) {
        if (part is Map && part['text'] is String) buf.write(part['text']);
      }
      return buf.toString();
    }
    return '';
  }

  /// 消息级事件落库（SSE 与 history 共用一套 seq 幂等）。
  void _persistMessage(
    int seq,
    String role,
    Map<String, dynamic> content, {
    String? confirmText,
  }) {
    final dshId = _dshId;
    final store = StoreService.shared;
    if (confirmText != null) {
      unawaited(store.removeUserEcho(widget.sessionId, confirmText));
    }
    unawaited(
      store.upsertMessage(
        StoredMessage(
          sessionId: widget.sessionId,
          dshId: dshId,
          seq: seq,
          role: role,
          contentJson: jsonEncode(content),
          ts: DateTime.now().millisecondsSinceEpoch,
        ),
      ),
    );
  }

  void _flushLiveAssistant() {
    if (_liveAssistantActive && _liveAssistant.isNotEmpty) {
      _entries.add(
        _ChatEntry(
          role: 'assistant',
          text: _liveAssistant,
          ts: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    }
    _liveAssistant = '';
    _liveAssistantActive = false;
  }

  String _extractText(Map message) {
    // store 行的 content 是 {'message': {...}} 包装，SSE 路径传的则是 message 本体——
    // 这里统一解包（否则历史消息文本永远取不到，页面渲染成全空白）。
    final inner = message['message'];
    if (inner is Map) return _extractText(inner.cast<String, dynamic>());
    // tool 行的 content 是 {'name': ...}（工具标记，无文本块）。
    final name = message['name'];
    if (name != null) return '🔧 $name';
    final content = message['content'];
    if (content is String) return content;
    if (content is List) {
      final buf = StringBuffer();
      for (final part in content) {
        if (part is Map) {
          final type = part['type']?.toString();
          if (type == 'text') {
            final t = part['text'];
            if (t is String) buf.write(t);
          } else if (type == 'image') {
            // 图片块不产出文本（缩略图由渲染层控制；📷 占位只用于无缓存历史兜底）
          } else if (type == 'tool-call') {
            // 工具调用块：显示名称 + 参数摘要（此前只显示「🔧 name」，用户看不到工具内容）
            final name = part['name']?.toString() ?? 'tool';
            final args = part['arguments']?.toString() ?? '';
            final brief = args.length > 80 ? '${args.substring(0, 80)}…' : args;
            if (buf.isNotEmpty && !buf.toString().endsWith('\n'))
              buf.write('\n');
            buf.write('🔧 $name${brief.isNotEmpty ? ' $brief' : ''}');
            if (brief.isNotEmpty) buf.write('\n');
          }
        }
      }
      return buf.toString();
    }
    return message['text']?.toString() ?? '';
  }

  void _notify(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 4)),
    );
  }

  void _scrollToBottom({bool force = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 用户不在贴底状态（在翻历史）时，流式/新消息不夺走滚动位置；
      // 但自己刚发的消息必须强制可见（force：发送动作场景）
      if ((!force && !_stickBottom) || !_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
      // 下一帧再补一次：异步渲染（loadRemote/SSE）会让内容继续增长，单次 jump 后
      // maxScrollExtent 仍可能是旧值——打开会话/新会话不回底的首因。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if ((!force && !_stickBottom) || !_scroll.hasClients) return;
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    });
  }

  // ---------- 发送 / 停止 ----------

  Future<void> _send() async {
    final text = _input.text.trim();
    final images = List<Uint8List>.from(_pendingImages);
    final image = images.isNotEmpty ? images.first : null;
    if (text.isEmpty && image == null) return;
    // 防连点/超时后重试竞态：5s 冷却窗内忽略重复发送（避免同一条消息发两次）
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs - _lastSendTryMs < 5000) return;
    _lastSendTryMs = nowMs;
    final api = _api;
    if (api == null) {
      _notify('未选择目标 dsh');
      return;
    }
    setState(() {
      _sending = true;
      _sendingCount++;
    });
    try {
      // 即时回显（纯文本或图文都回显；图片显示 📷 占位 + 配文）
      // 回显行的文本构造与 _extractText 输出保持一致（确认事件来时按文本清除）
      final echoText = text; // 与确认行文本完全一致（图片由缩略图渲染，不出现在文本里）
      setState(() {
        _flushLiveAssistant();
        _entries.add(
          _ChatEntry(
            role: 'user',
            text: echoText,
            images: images,
            ts: DateTime.now().millisecondsSinceEpoch,
          ),
        );
      });
      _scrollToBottom(force: true);
      final echoSeq =
          -DateTime.now().millisecondsSinceEpoch; // 临时行：负 seq 不与事件 seq 冲突
      final echo = StoredMessage(
        sessionId: widget.sessionId,
        dshId: _dshId,
        seq: echoSeq,
        role: 'user',
        contentJson: jsonEncode({
          'message': {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': echoText},
            ],
          },
        }),
        ts: DateTime.now().millisecondsSinceEpoch,
      );
      unawaited(StoreService.shared.upsertMessage(echo));
      // 本地图片缓存：host 的 attachmentId = sha256(bytes)，发送时预存，历史渲染即可命中
      for (final img in images) {
        // 双钥匙：host 的 attachmentId 可能基于解码字节或 base64 串做 sha256，两个都缓存
        final b64 = base64Encode(img);
        ImageCacheStore.put(crypto.sha256.convert(img).toString(), img);
        ImageCacheStore.put(
          crypto.sha256.convert(b64.codeUnits).toString(),
          img,
        );
      }
      final content = <Map<String, dynamic>>[
        if (text.isNotEmpty) {'type': 'text', 'text': text},
        for (final img in images)
          {
            'type': 'image',
            'mediaType': 'image/jpeg',
            'data': base64Encode(img),
          },
      ];
      // 发送语义：默认 steer（插进当前轮）。只有 host 明确拒绝（steer-unavailable 等）
      // 才回退 queue——网络超时/连接错可能已送达（重复发送元凶），绝不重发。
      try {
        await api.rpc(
          'session.prompt',
          {'sessionId': widget.sessionId, 'mode': 'steer', 'content': content},
          timeout: image != null
              ? const Duration(seconds: 60)
              : const Duration(seconds: 20),
        );
      } catch (e) {
        final msg = e.toString();
        final hostRejected =
            msg.contains('steer-unavailable') ||
            msg.contains('steer/') ||
            msg.contains('queue-');
        if (hostRejected) {
          await api.rpc(
            'session.prompt',
            {
              'sessionId': widget.sessionId,
              'mode': 'queue',
              'content': content,
            },
            timeout: image != null
                ? const Duration(seconds: 60)
                : const Duration(seconds: 20),
          );
        } else {
          // 网络/超时/未知错误：消息可能已送达（host 接受后才回响应的时序差）——
          // 不报「失败」：温和提示等待确认，内容保留（用户可重试），交由 SSE 确认清除回显
          _notify('发送超时，等待 agent 确认…');
          _lastSendTryMs = DateTime.now().millisecondsSinceEpoch;
          return;
        }
      }
      _input.clear();
      if (images.isNotEmpty && mounted) {
        setState(() => _pendingImages.clear());
      }
      _scrollToBottom(force: true); // 自己发的消息必须可见（不依赖贴底状态）
    } catch (e) {
      // 发送失败：文本消息撤回回显；图片保留在预览条（可重发）
      if (image == null) {
        await StoreService.shared.removeUserEcho(widget.sessionId, text);
        if (!mounted) return;
        setState(() {
          _entries.removeWhere((x) => x.role == 'user' && x.text == text);
        });
      }
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('发送失败: $e')));
      }
    } finally {
      if (mounted) {
        setState(() {
          _sendingCount = (_sendingCount - 1).clamp(0, 1 << 30);
          _sending = _sendingCount > 0;
        });
      }
    }
  }

  Future<void> _stop() async {
    try {
      final api = _api;
      if (api == null) return;
      await api.rpc('session.cancel', {'sessionId': widget.sessionId});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('停止失败: $e')));
    }
  }

  // ---------- 审批 / 提问应答（/api/respond） ----------

  Future<void> _respondApproval(bool allow) async {
    final a = _approval;
    if (a == null || a.rpcId.isEmpty) return;
    try {
      final api = _api;
      if (api == null) throw StateError('未选择目标 dsh');
      await api.respond(
        a.rpcId,
        value: {
          'sessionId': widget.sessionId,
          'approvalId': a.approvalId,
          'outcome': allow ? 'allowed-once' : 'rejected',
        },
      );
      if (!mounted) return;
      setState(() => _approval = null);
      _notify(allow ? '✅ 已允许「${a.toolName}」执行一次' : '已拒绝「${a.toolName}」');
    } catch (e) {
      if (!mounted) return;
      _notify('应答失败: $e');
    }
  }

  Future<void> _respondQuestion() async {
    final q = _question;
    if (q == null || q.rpcId.isEmpty || q.items.isEmpty) return;
    try {
      // 组 answers：有选项 → selected=[label]；无选项 → custom 原文（selected 留空）
      final answers = <Map<String, dynamic>>[];
      for (final item in q.items) {
        final id = item['id']?.toString() ?? '';
        final selected = (_qAnswers[id] ?? const <String>[])
            .where((s) => s.isNotEmpty)
            .toList();
        final hasOptions = (item['options'] as List?)?.isNotEmpty ?? false;
        if (selected.isEmpty && !hasOptions) {
          final custom = _qAnswers[id]?.firstOrNull ?? '';
          if (custom.isEmpty) throw Exception('请完成所有问题再提交');
          answers.add({'id': id, 'selected': const [], 'custom': custom});
        } else {
          if (selected.isEmpty) throw Exception('请完成所有问题再提交');
          answers.add({'id': id, 'selected': selected});
        }
      }
      final api = _api;
      if (api == null) throw StateError('未选择目标 dsh');
      await api.respond(
        q.rpcId,
        value: {
          'sessionId': widget.sessionId,
          'answer': {'answers': answers},
        },
      );
      if (!mounted) return;
      setState(() {
        _question = null;
        _qAnswers.clear();
      });
      _notify('✅ 回答已提交');
    } catch (e) {
      if (!mounted) return;
      _notify('回答失败: $e');
    }
  }

  Future<void> _cancelQuestion() async {
    final q = _question;
    if (q == null || q.rpcId.isEmpty) return;
    try {
      final api = _api;
      if (api == null) throw StateError('未选择目标 dsh');
      await api.respond(q.rpcId, cancel: true);
      if (!mounted) return;
      setState(() {
        _question = null;
        _qAnswers.clear();
      });
      _notify('已取消提问');
    } catch (e) {
      if (!mounted) return;
      _notify('取消失败: $e');
    }
  }

  /// 暂存待发送图片（多选；选图 ≠ 发送：可预览、可配文，点发送才发出）。
  final List<Uint8List> _pendingImages = [];

  Future<void> _pickImages() async {
    final picker = ImagePicker();
    // 1280/80：控制在 ~300-800KB（base64 后 ~0.4-1MB），再大弱网上传必超时。
    final images = await picker.pickMultiImage(
      maxWidth: 1280,
      imageQuality: 80,
      limit: 9,
    );
    if (images.isEmpty) return;
    final bytes = await Future.wait(images.map((x) => x.readAsBytes()));
    if (!mounted) return;
    setState(() {
      for (final b in bytes) {
        if (_pendingImages.length < 9) _pendingImages.add(b);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final live = _liveAssistantActive && _liveAssistant.isNotEmpty;
    // 群聊视图全量解析一次（itemBuilder 里逐行调 _groupBubbles() 是 O(n²)，长会话卡顿）。
    final groupBubbles = _groupView ? _groupBubbles() : const <GcBubble>[];
    final busy = _liveAssistantActive || _sending;
    return Scaffold(
      backgroundColor: Ui.bg,
      // DeepSeek 式侧滑抽屉（窄屏）：从左缘右滑滑出会话列表（70% 宽、动画），
      // 选中→切换该会话；未选→右滑/点遮罩划回。
      appBar: AppBar(
        title: Text(
          widget.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: Ui.ink,
          ),
        ),
        backgroundColor: Ui.bg,
        surfaceTintColor: Ui.bg,
        foregroundColor: Ui.ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        actions: [
          TextButton.icon(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              foregroundColor: Ui.inkSecondary,
              textStyle: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            onPressed: _pickSessionModel,
            icon: const Icon(Icons.smart_toy_outlined, size: 15),
            label: Text(
              _sessionModelLabel(),
              style: const TextStyle(fontSize: 12),
            ),
          ),
          TextButton.icon(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              foregroundColor: _showToolCalls ? Ui.accent : Ui.inkMuted,
              textStyle: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            onPressed: () => setState(() => _showToolCalls = !_showToolCalls),
            icon: Icon(
              _showToolCalls ? Icons.construction : Icons.construction_outlined,
              size: 16,
            ),
            label: Text(_showToolCalls ? '工具' : '工具详情'),
          ),
          Tooltip(
            message: _sseUp ? '实时连接中' : '实时连接断开（已走轮询兜底）',
            child: Padding(
              padding: const EdgeInsets.only(left: 4, right: 4),
              child: Center(
                child: Icon(
                  _sseUp ? Icons.wifi : Icons.wifi_off,
                  size: 15,
                  color: _sseUp ? Ui.success : Ui.inkMuted,
                ),
              ),
            ),
          ),
          // 只有正在跑任务（流式生成/发送中）才显示停止，常驻按钮容易被误触
          if (busy)
            IconButton(
              icon: Icon(
                Icons.stop_circle_outlined,
                size: 20,
                color: Ui.danger,
              ),
              tooltip: '停止当前任务',
              onPressed: _stop,
            ),
        ],
      ),
      body: Stack(
        children: [
          Column(
            children: [
              if (_queueItems.isNotEmpty)
                Container(
                  margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                  decoration: BoxDecoration(
                    color: Ui.bubbleUser,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Ui.separator),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.hourglass_top_outlined,
                            size: 14,
                            color: Ui.accent,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              '$_queueCount 条消息排队等待 agent 处理',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: Ui.inkSecondary,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      for (final item in _queueItems)
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Text(
                                item.text,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 13, color: Ui.ink),
                              ),
                            ),
                            const SizedBox(width: 6),
                            TextButton(
                              onPressed: () => _promoteQueue(item.id),
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                                minimumSize: const Size(0, 32),
                              ),
                              child: Text(
                                '插队',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: Ui.accent,
                                ),
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              Expanded(
                child: GestureDetector(
                  // 全屏横滑 → 抽屉跟手（任意起点；松开瞬间判定开/关）
                  onHorizontalDragStart: (_) =>
                      setState(() => _drawerDragging = true),
                  onHorizontalDragUpdate: (d) {
                    final w = MediaQuery.of(context).size.width;
                    setState(() {
                      _drawerOffset = (_drawerOffset + d.delta.dx)
                          .clamp(0.0, w * 0.7)
                          .toDouble();
                      _drawerActive = _drawerOffset > 0;
                    });
                  },
                  onHorizontalDragEnd: (d) {
                    final w = MediaQuery.of(context).size.width;
                    final v = d.primaryVelocity ?? 0;
                    setState(() {
                      _drawerDragging = false;
                      _drawerOffset = (v > 250 || _drawerOffset > w * 0.35)
                          ? w * 0.7
                          : 0.0;
                      _drawerActive = _drawerOffset > 0;
                    });
                  },
                  behavior: HitTestBehavior.translucent,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: _loading
                            ? Center(
                                child: CircularProgressIndicator(
                                  color: Ui.accent,
                                ),
                              )
                            : _error != null
                            ? _errorView()
                            : ListView.builder(
                                controller: _scroll,
                                padding: const EdgeInsets.all(12),
                                itemCount: chatItemCount(
                                  live: live,
                                  groupBubbles: groupBubbles,
                                ),
                                itemBuilder: (_, i) {
                                  final disp = _displayEntries();
                                  final base = _groupView
                                      ? groupBubbles.length
                                      : disp.length + (live ? 1 : 0);
                                  // 末尾追加待处理卡（审批/提问入消息流——2026-09-06 裁决）
                                  if (i >= base) {
                                    final k = i - base;
                                    if (_approval != null && k == 0)
                                      return _approvalBanner();
                                    return _questionBanner();
                                  }
                                  if (!_groupView) {
                                    if (i == disp.length) {
                                      return _bubble(
                                        _ChatEntry(
                                          role: 'assistant',
                                          text: _liveAssistant,
                                        ),
                                      );
                                    }
                                    return _bubble(_entries[i]);
                                  }
                                  return _groupBubble(groupBubbles[i]);
                                },
                              ),
                      ),
                      // 用户上滑读历史后：右下角「回到底部」浮钮（不贴底才出现）
                      if (!_stickBottom && !_loading && _error == null)
                        Positioned(
                          right: 14,
                          bottom: 12,
                          child: Material(
                            color: Ui.accent,
                            shape: const CircleBorder(),
                            elevation: 2,
                            child: InkWell(
                              customBorder: const CircleBorder(),
                              onTap: () {
                                setState(() => _stickBottom = true);
                                _scrollToBottom();
                              },
                              child: SizedBox(
                                width: 40,
                                height: 40,
                                child: Icon(
                                  Icons.arrow_downward,
                                  size: 20,
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
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            color: Ui.bgSubtle,
                            borderRadius: BorderRadius.circular(24),
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              // 待发送图片预览条（选图 ≠ 发送：可预览/移除/配文）
                              if (_pendingImages.isNotEmpty)
                                Container(
                                  margin: const EdgeInsets.fromLTRB(
                                    12,
                                    8,
                                    12,
                                    0,
                                  ),
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: Ui.surface,
                                    borderRadius: BorderRadius.circular(14),
                                    border: Border.all(color: Ui.separator),
                                  ),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Wrap(
                                        spacing: 8,
                                        runSpacing: 8,
                                        children: [
                                          for (
                                            var i = 0;
                                            i < _pendingImages.length;
                                            i++
                                          )
                                            Stack(
                                              children: [
                                                ClipRRect(
                                                  borderRadius:
                                                      BorderRadius.circular(8),
                                                  child: Image.memory(
                                                    _pendingImages[i],
                                                    width: 52,
                                                    height: 52,
                                                    fit: BoxFit.cover,
                                                  ),
                                                ),
                                                Positioned(
                                                  right: 2,
                                                  top: 2,
                                                  child: GestureDetector(
                                                    onTap: () => setState(
                                                      () => _pendingImages
                                                          .removeAt(i),
                                                    ),
                                                    child: Container(
                                                      width: 16,
                                                      height: 16,
                                                      decoration:
                                                          const BoxDecoration(
                                                            color:
                                                                Colors.black54,
                                                            shape:
                                                                BoxShape.circle,
                                                          ),
                                                      child: const Icon(
                                                        Icons.close,
                                                        size: 11,
                                                        color: Colors.white,
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              TextField(
                                controller: _input,
                                minLines: 1,
                                maxLines: 5,
                                style: TextStyle(fontSize: 15, color: Ui.ink),
                                decoration: InputDecoration(
                                  hintText: _pendingImages.isNotEmpty
                                      ? '添加说明（可选）…'
                                      : '发送消息',
                                  hintStyle: TextStyle(
                                    color: Ui.inkMuted,
                                    fontSize: 15,
                                  ),
                                  border: InputBorder.none,
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 11,
                                  ),
                                ),
                                // Enter 由 TextField 提交（IME 组合 Enter 不会触发 onSubmitted——拼音选词安全）
                                onSubmitted: (_) => _send(),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Row(
                          children: [
                            IconButton(
                              onPressed: _sending ? null : _pickImages,
                              icon: Icon(
                                Icons.add_photo_alternate_outlined,
                                size: 22,
                                color: Ui.inkMuted,
                              ),
                              tooltip: '发送图片',
                            ),
                            IconButton(
                              // 换行（桌面 Enter=发送；需要多行时点此在光标处换行）
                              onPressed: () {
                                final v = _input.value;
                                final sel = v.selection.isValid
                                    ? v.selection
                                    : TextSelection.collapsed(
                                        offset: v.text.length,
                                      );
                                final text = v.text.replaceRange(
                                  sel.start,
                                  sel.end,
                                  '\n',
                                );
                                _input.value = TextEditingValue(
                                  text: text,
                                  selection: TextSelection.collapsed(
                                    offset: sel.start + 1,
                                  ),
                                );
                              },
                              icon: Icon(
                                Icons.keyboard_return_outlined,
                                size: 20,
                                color: Ui.inkMuted,
                              ),
                              tooltip: '换行',
                            ),
                            Material(
                              color: Ui.accent,
                              borderRadius: BorderRadius.circular(20),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(20),
                                onTap: _sending ? null : _send,
                                child: SizedBox(
                                  width: 40,
                                  height: 40,
                                  child: Icon(
                                    Icons.arrow_upward,
                                    size: 20,
                                    color: Ui.accentOn,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          // 全屏横滑抽屉层（跟手动画 + 遮罩）
          if (MediaQuery.of(context).size.width < 720)
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: MediaQuery.of(context).size.width,
              child: _drawerActive
                  ? GestureDetector(
                      onTap: () => setState(() {
                        _drawerOffset = 0;
                        _drawerActive = false;
                      }),
                      child: Container(
                        color: Colors.black.withValues(alpha: 0.35),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          if (MediaQuery.of(context).size.width < 720)
            AnimatedPositioned(
              duration: _drawerDragging
                  ? Duration.zero
                  : const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              left: _drawerOffset - MediaQuery.of(context).size.width * 0.7,
              top: 0,
              bottom: 0,
              width: MediaQuery.of(context).size.width * 0.7,
              child: Material(
                color: Ui.bg,
                elevation: 8,
                borderRadius: const BorderRadius.horizontal(
                  right: Radius.circular(18),
                ),
                clipBehavior: Clip.antiAlias,
                child: _SessionDrawer(
                  api: _api,
                  currentSessionId: widget.sessionId, onClose: () => setState(() { _drawerOffset = 0; _drawerActive = false; }),
                ),
              ),
            ),
        ],
      ),
    );
  }

  List<GcBubble> _groupBubbles() {
    final msgs = [
      for (final e in _entries)
        {
          'role': e.role,
          'text': e.text,
          'ts': DateTime.now().millisecondsSinceEpoch,
        },
      if (_liveAssistantActive && _liveAssistant.isNotEmpty)
        {
          'role': 'assistant',
          'text': _liveAssistant,
          'ts': DateTime.now().millisecondsSinceEpoch,
        },
    ];
    return groupChatBubbles(msgs);
  }

  Widget _groupBubble(GcBubble b) {
    if (b.kind == 'sys') {
      return Center(
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: DshTokens.kleinBlueSoft,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            b.text,
            style: const TextStyle(
              fontSize: 11,
              fontStyle: FontStyle.italic,
              color: DshTokens.inkSecondary,
            ),
          ),
        ),
      );
    }
    final isOwner = b.kind == 'owner';
    return Align(
      alignment: isOwner ? Alignment.centerRight : Alignment.centerLeft,
      child: Row(
        mainAxisAlignment: isOwner
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isOwner) _avatar(b),
          const SizedBox(width: 6),
          Flexible(
            child: Column(
              crossAxisAlignment: isOwner
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: [
                if (!isOwner)
                  Text(
                    b.name,
                    style: TextStyle(
                      fontSize: 10,
                      color: b.color,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                const SizedBox(height: 2),
                Container(
                  margin: const EdgeInsets.symmetric(vertical: 3),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    // 群聊里「本人」气泡同单聊：品牌深蓝填充
                    color: isOwner ? Ui.accent : Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: isOwner
                        ? null
                        : Border.all(color: DshTokens.divider),
                  ),
                  child: Text(
                    b.text,
                    style: TextStyle(
                      fontSize: 13,
                      color: isOwner ? Ui.accentOn : DshTokens.ink,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (isOwner) const SizedBox(width: 6),
          if (isOwner) _avatar(b),
        ],
      ),
    );
  }

  Widget _avatar(GcBubble b) {
    return CircleAvatar(
      radius: 14,
      backgroundColor: b.color.withValues(alpha: 0.16),
      child: Text(b.emoji, style: const TextStyle(fontSize: 13)),
    );
  }

  /// 消息列表条数 = 消息（+live） + 待处理卡（审批/提问，入消息流）。
  int chatItemCount({
    required bool live,
    required List<GcBubble> groupBubbles,
    int? displayCount,
  }) {
    final base = _groupView
        ? groupBubbles.length
        : (displayCount ?? _entries.length) + (live ? 1 : 0);
    return base + (_approval != null ? 1 : 0) + (_question != null ? 1 : 0);
  }

  /// 相邻工具行折叠为「组」entry（3080 桌面逻辑）：点击展开显示全部成员。
  final Set<int> _expandedToolGroups = {};

  List<_ChatEntry> _displayEntries() {
    // 相邻工具行折叠为一个组（3080 桌面逻辑）：折叠态=组摘要；展开态=成员+收起行。
    final out = <_ChatEntry>[];
    int i = 0;
    while (i < _entries.length) {
      final e = _entries[i];
      if (e.tool) {
        final group = <_ChatEntry>[];
        while (i < _entries.length && _entries[i].tool) {
          group.add(_entries[i]);
          i++;
        }
        final first = group.first;
        final key = first.ts;
        if (_expandedToolGroups.contains(key)) {
          out.addAll(group);
          out.add(_ChatEntry(
            role: 'tool',
            text: '🔧 收起工具调用',
            tool: true,
            ts: first.ts,
          ));
        } else if (!_showToolCalls) {
          out.add(_ChatEntry(
            role: 'tool',
            text: '🔧 工具调用 ×${group.length} · ${_short(first.text)}',
            tool: true,
            ts: first.ts,
            children: group,
          ));
        } else {
          // 详情态：逐条完整展示（旧行为）
          out.addAll(group);
        }
      } else {
        out.add(e);
        i++;
      }
    }
    return out;
  }

  String _short(String t) {
    final name = t.split(' ').first.replaceFirst('🔧', '').trim();
    return name.length > 12 ? '${name.substring(0, 12)}…' : name;
  }

  String _sessionModelId = '默认模型';

  /// 消息时间显示：今天 HH:mm；昨天 HH:mm；更早 M-d HH:mm。
  static String _fmtMsgTime(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final d = DateTime(t.year, t.month, t.day);
    final hm =
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    if (d == today) return hm;
    if (today.difference(d).inDays == 1) return '昨天 $hm';
    if (t.year == now.year) return '${t.month}-${t.day} $hm';
    return '${t.year}-${t.month}-${t.day} $hm';
  }

  String _sessionModelLabel() => _sessionModelId;

  /// 会话内切换模型（真实 host 目录）；选中后附思维深度三档（reasoningEffort）。
  Future<void> _pickSessionModel() async {
    try {
      final api = _api;
      if (api == null) {
        _notify('未选择目标 dsh');
        return;
      }
      final res = await api.rpc(
        'llm.providers',
        {},
        timeout: const Duration(seconds: 10),
      );
      final providers = (res['providers'] as List? ?? const [])
          .map((e) => (e as Map).cast<String, dynamic>())
          .toList();
      if (providers.isEmpty) throw StateError('模型列表为空');
      final providerId = await showModalBottomSheet<String>(
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
                padding: EdgeInsets.fromLTRB(20, 18, 20, 8),
                child: Text(
                  '切换模型 · 供应商',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Ui.ink,
                  ),
                ),
              ),
              for (final p in providers)
                ListTile(
                  leading: Icon(Icons.dns_outlined, size: 18, color: Ui.accent),
                  title: Text(
                    (p['name'] ?? p['id'] ?? '?').toString(),
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Ui.ink,
                    ),
                  ),
                  onTap: () => Navigator.pop(c, p['id']?.toString()),
                ),
            ],
          ),
        ),
      );
      if (providerId == null || !mounted) return;
      final mres = await api.rpc('llm.models', {
        'provider': providerId,
      }, timeout: const Duration(seconds: 10));
      final models = (mres['models'] as List? ?? const [])
          .map((e) => (e as Map).cast<String, dynamic>())
          .toList();
      if (models.isEmpty) throw StateError('该供应商无可用模型');
      final modelId = await showModalBottomSheet<String>(
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
                  '切换模型 · $providerId',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Ui.ink,
                  ),
                ),
              ),
              for (final m in models)
                ListTile(
                  leading: Icon(
                    Icons.smart_toy_outlined,
                    size: 18,
                    color: Ui.accent,
                  ),
                  title: Text(
                    (m['name'] ?? m['id'] ?? '?').toString(),
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Ui.ink,
                    ),
                  ),
                  subtitle: Text(
                    (m['id'] ?? '').toString(),
                    style: TextStyle(fontSize: 11, color: Ui.inkMuted),
                  ),
                  onTap: () => Navigator.pop(c, m['id']?.toString()),
                ),
            ],
          ),
        ),
      );
      if (modelId == null || !mounted) return;
      // 思维深度（reasoningEffort）：高/中/低/默认
      final effort = await showModalBottomSheet<String>(
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
                padding: EdgeInsets.fromLTRB(20, 18, 20, 8),
                child: Text(
                  '思维深度',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Ui.ink,
                  ),
                ),
              ),
              for (final e in [
                ('high', '高 · 复杂推理'),
                ('medium', '中 · 平衡'),
                ('low', '低 · 快速'),
              ])
                ListTile(
                  leading: Icon(
                    Icons.psychology_outlined,
                    size: 18,
                    color: Ui.accent,
                  ),
                  title: Text(
                    e.$2,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Ui.ink,
                    ),
                  ),
                  onTap: () => Navigator.pop(c, e.$1),
                ),
            ],
          ),
        ),
      );
      if (!mounted) return;
      await api.rpc('session.selectModel', {
        'sessionId': widget.sessionId,
        'provider': providerId,
        'model': modelId,
        if (effort != null) 'reasoningEffort': effort,
      }, timeout: const Duration(seconds: 15));
      if (mounted) {
        setState(
          () =>
              _sessionModelId = effort != null ? '$modelId · $effort' : modelId,
        );
        _notify('已切换模型：$modelId${effort != null ? '（$effort）' : ''}');
      }
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('404')) {
        _notify('模型接口未开放：宿主 dsh 需升级（compat 更新并重启后可用）');
      } else {
        _notify('切换失败: ${msg.length > 80 ? msg.substring(0, 80) : msg}');
      }
    }
  }

  /// 工具详情底部弹层：完整参数/结果（等宽）+ 一键复制。
  void _showToolDetail(_ChatEntry e) {
    final detail = e.detail ?? '';
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Ui.bg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      isScrollControlled: true,
      builder: (c) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(c).size.height * 0.7,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.build_circle_outlined,
                      size: 18,
                      color: Ui.accent,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        e.text,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: Ui.ink,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: Icon(Icons.copy, size: 18, color: Ui.accent),
                      tooltip: '复制',
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: detail));
                        if (c.mounted) Navigator.pop(c);
                        if (mounted) _notify('已复制工具内容');
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Flexible(
                  child: SingleChildScrollView(
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Ui.bgSubtle,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: SelectionArea(
                        child: Text(
                          detail,
                          style: TextStyle(
                            fontSize: 12.5,
                            height: 1.5,
                            color: Ui.ink,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 把排队中的一条消息提升到当前轮（agent 可立即转向处理）。
  /// 需要 host 侧 session.updateQueue 支持（apiproxy-compat 端点；未更新时给出提示）。
  Future<void> _promoteQueue(String itemId) async {
    try {
      final api = _api;
      if (api == null) throw StateError('未选择目标 dsh');
      await api.rpc('session.updateQueue', {
        'sessionId': widget.sessionId,
        'itemId': itemId,
        'action': {'kind': 'steer'},
      });
      _dropFromQueue(itemId);
      if (mounted) _notify('✅ 已插队，agent 正在处理');
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString();
      // host 已消费该条（再次插队/已处理）→ 实际成功：本地移除、温和提示，不报「失败」
      if (msg.contains('queue-item-not-found') ||
          msg.contains('steer-unavailable') ||
          msg.contains('not found')) {
        _dropFromQueue(itemId);
        _notify('该消息已开始处理');
      } else if (msg.contains('404')) {
        _notify('插队接口未开放：宿主 dsh 需升级（apiproxy-compat 更新后）');
      } else {
        _notify('插队失败: ${msg.length > 80 ? msg.substring(0, 80) : msg}');
      }
    }
  }

  /// 本地移除排队项（插队成功或已被 host 消费后按钮随之消失）。
  void _dropFromQueue(String itemId) {
    setState(() {
      _queueItems = _queueItems.where((x) => x.id != itemId).toList();
      _queueCount = _queueItems.length;
    });
  }

  /// 消息长按复制面板（Web 系统选区不稳定的可靠兜底）。
  void _showMessageCopy(_ChatEntry e) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Ui.bg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      isScrollControlled: true,
      builder: (c) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(c).size.height * 0.7,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      e.role == 'user'
                          ? Icons.person_outline
                          : Icons.smart_toy_outlined,
                      size: 18,
                      color: Ui.accent,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        e.role == 'user' ? '我的消息' : '助手消息',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: Ui.ink,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: Icon(Icons.copy, size: 18, color: Ui.accent),
                      tooltip: '复制全文',
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: e.text));
                        if (c.mounted) Navigator.pop(c);
                        if (mounted) _notify('已复制消息全文');
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Flexible(
                  child: SingleChildScrollView(
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Ui.bgSubtle,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: SelectionArea(
                        child: Text(
                          e.text,
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.5,
                            color: Ui.ink,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
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
            Icon(Icons.cloud_off_outlined, size: 44, color: Ui.inkMuted),
            const SizedBox(height: 14),
            SelectableText(
              _error!,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: Ui.inkSecondary),
            ),
            const SizedBox(height: 14),
            TextButton(
              onPressed: () {
                setState(() => _error = null);
                _loadLocal().then((_) => _loadRemote(initial: true));
                _connectSse();
              },
              child: Text(
                '重试',
                style: TextStyle(
                  color: Ui.accent,
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

  /// 工具审批横幅（pending 期常驻，允许一次 / 拒绝）。
  Widget _approvalBanner() {
    final a = _approval!;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: Ui.bubbleUser,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Ui.separator),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.shield_outlined, size: 16, color: Ui.accent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '工具审批请求',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: Ui.ink,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Agent 请求执行「${a.toolName}」${a.reason != null && a.reason!.isNotEmpty ? '：${a.reason}' : ''}',
            style: TextStyle(fontSize: 13, height: 1.4, color: Ui.inkSecondary),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _respondApproval(false),
                  child: Text('拒绝', style: TextStyle(color: Ui.inkSecondary)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  onPressed: () => _respondApproval(true),
                  style: FilledButton.styleFrom(
                    backgroundColor: Ui.accent,
                    minimumSize: const Size(0, 42),
                  ),
                  child: Text('允许一次', style: TextStyle(color: Ui.accentOn)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Agent 提问横幅：选项 chip / 文本输入 + 提交/取消。
  Widget _questionBanner() {
    final q = _question!;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      constraints: const BoxConstraints(maxHeight: 340),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Ui.separator),
      ),
      child: ListView(
        shrinkWrap: true,
        children: [
          Row(
            children: [
              Icon(Icons.help_outline, size: 16, color: Ui.accent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Agent 提问',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: Ui.ink,
                  ),
                ),
              ),
            ],
          ),
          for (final item in q.items) _questionItem(item),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _cancelQuestion,
                  child: Text('取消', style: TextStyle(color: Ui.inkSecondary)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  onPressed: _respondQuestion,
                  style: FilledButton.styleFrom(
                    backgroundColor: Ui.accent,
                    minimumSize: const Size(0, 42),
                  ),
                  child: Text('提交回答', style: TextStyle(color: Ui.accentOn)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _questionItem(Map<String, dynamic> item) {
    final id = item['id']?.toString() ?? '';
    final header = item['header']?.toString();
    final question = item['question']?.toString() ?? '';
    final options =
        (item['options'] as List?)
            ?.map((e) => (e as Map).cast<String, dynamic>())
            .toList() ??
        const <Map<String, dynamic>>[];
    final multi = item['multiSelect'] == true;
    final selected = _qAnswers[id] ?? const <String>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (header != null && header.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 2),
            child: Text(
              header,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: Ui.accent,
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 2),
          child: Text(
            question,
            style: TextStyle(fontSize: 13, height: 1.4, color: Ui.ink),
          ),
        ),
        const SizedBox(height: 6),
        if (options.isNotEmpty)
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final o in options)
                FilterChip(
                  label: Text(
                    (o['label'] ?? '').toString(),
                    style: const TextStyle(fontSize: 12),
                  ),
                  selected: selected.contains(o['label'].toString()),
                  onSelected: (v) => setState(() {
                    final cur = <String>[
                      ...(_qAnswers[id] ?? const <String>[]),
                    ];
                    final label = (o['label'] ?? '').toString();
                    if (v) {
                      if (!multi) cur.clear();
                      if (!cur.contains(label)) cur.add(label);
                    } else {
                      cur.remove(label);
                    }
                    _qAnswers[id] = cur;
                  }),
                ),
            ],
          )
        else
          TextField(
            onChanged: (v) => setState(() => _qAnswers[id] = [v]),
            decoration: InputDecoration(
              hintText: '输入回答…',
              hintStyle: TextStyle(fontSize: 13, color: Ui.inkMuted),
              isDense: true,
              filled: true,
              fillColor: Ui.bgSubtle,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.all(Radius.circular(10)),
                borderSide: BorderSide.none,
              ),
            ),
            style: TextStyle(fontSize: 13, color: Ui.ink),
          ),
      ],
    );
  }

  /// markdown 样式表：isDark=用户深蓝气泡内（浅字），否则助手正文（深字）。
  MarkdownStyleSheet _markdownStyle({required bool isDark}) {
    final ink = isDark ? Ui.accentOn : Ui.ink;
    final soft = isDark ? Ui.accentDeep : Ui.bgSubtle;
    final accent = isDark ? Ui.accentOn : Ui.accent;
    return MarkdownStyleSheet(
      p: TextStyle(fontSize: LocalSettings.fontSize, height: 1.45, color: ink),
      a: TextStyle(color: accent, decoration: TextDecoration.underline),
      h1: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: ink),
      h2: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: ink),
      h3: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: ink),
      code: TextStyle(
        fontSize: 13,
        fontFamily: 'monospace',
        backgroundColor: soft,
        color: ink,
      ),
      codeblockDecoration: BoxDecoration(
        color: soft,
        borderRadius: BorderRadius.circular(8),
      ),
      codeblockPadding: const EdgeInsets.all(10),
      blockquote: TextStyle(fontSize: 14, color: ink.withValues(alpha: 0.9)),
      blockquoteDecoration: BoxDecoration(
        color: soft,
        borderRadius: BorderRadius.circular(6),
        border: Border(left: BorderSide(width: 3, color: accent)),
      ),
      blockquotePadding: const EdgeInsets.symmetric(
        horizontal: 10,
        vertical: 4,
      ),
      listBullet: TextStyle(fontSize: 15, color: ink),
      horizontalRuleDecoration: BoxDecoration(
        color: isDark ? Ui.accentOn.withValues(alpha: 0.4) : Ui.separator,
      ),
      tableHead: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: ink,
      ),
      tableBody: TextStyle(fontSize: 13, color: ink),
    );
  }

  Widget _bubble(_ChatEntry e) {
    if (e.text.isEmpty && e.images.isEmpty) return const SizedBox.shrink();
    final isUser = e.role == 'user';
    final isTool = e.role == 'tool';
    if (isTool && !_showToolCalls) return const SizedBox.shrink();
    if (isTool) {
      // 工具组摘要/收起行：点击展开（children）/收起
      if (e.children != null || e.text == '🔧 收起工具调用') {
        final isExpand = e.children != null;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () {
              final key = e.ts;
              setState(() {
                if (isExpand) {
                  _expandedToolGroups.add(key);
                } else {
                  _expandedToolGroups.remove(key);
                }
              });
            },
            child: Row(
              children: [
                Icon(Icons.unfold_more, size: 13, color: Ui.inkMuted),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    e.text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: Ui.inkSecondary,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      }
      // 工具行：详情态=参数+结果（点击看全文）；折叠态=仅工具名一行（隐藏的是什么：参数与结果）
      if (!_showToolCalls) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
          child: Row(
            children: [
              Icon(Icons.build_circle_outlined, size: 13, color: Ui.inkMuted),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  e.text.split(' ').first.replaceFirst('🔧', '').trim(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: Ui.inkMuted,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Icon(Icons.unfold_more, size: 13, color: Ui.inkMuted),
            ],
          ),
        );
      }
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: e.detail == null ? null : () => _showToolDetail(e),
          child: Row(
            children: [
              Icon(Icons.build_circle_outlined, size: 13, color: Ui.inkMuted),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  e.text,
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 12,
                    color: Ui.inkMuted,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              if (e.detail != null)
                Icon(Icons.unfold_more, size: 14, color: Ui.inkMuted),
            ],
          ),
        ),
      );
    }
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        // 长按 → 复制面板（Web 系统选区不稳定时的可靠兜底）
        onLongPress: () => _showMessageCopy(e),
        child: isUser
            // 用户消息：右侧品牌深蓝圆角气泡
            ? Container(
                margin: const EdgeInsets.symmetric(vertical: 4),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.78,
                ),
                decoration: BoxDecoration(
                  color: Ui.accent,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (e.images.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final img in e.images)
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.memory(
                                  img,
                                  width: 96,
                                  height: 96,
                                  fit: BoxFit.cover,
                                ),
                              ),
                          ],
                        ),
                      ),
                    SelectionArea(
                      child: MarkdownBody(
                        data: e.text.isEmpty ? '📷 图片' : e.text,
                        styleSheet: _markdownStyle(isDark: true),
                      ),
                    ),
                    if (e.ts > 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          _fmtMsgTime(e.ts),
                          style: TextStyle(
                            fontSize: 10.5,
                            color: Ui.accentOn.withValues(alpha: 0.65),
                          ),
                        ),
                      ),
                  ],
                ),
              )
            // 助手消息：无容器（DeepSeek/Gemini 式排版，阅读感优先）
            : Container(
                margin: const EdgeInsets.symmetric(vertical: 4),
                padding: const EdgeInsets.fromLTRB(2, 4, 8, 4),
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.92,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (e.images.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final img in e.images)
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.memory(
                                  img,
                                  width: 96,
                                  height: 96,
                                  fit: BoxFit.cover,
                                ),
                              ),
                          ],
                        ),
                      ),
                    SelectionArea(
                      child: MarkdownBody(
                        data: e.text.isEmpty ? '📷 图片' : e.text,
                        styleSheet: _markdownStyle(isDark: false),
                      ),
                    ),
                    if (e.ts > 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          _fmtMsgTime(e.ts),
                          style: TextStyle(
                            fontSize: 10.5,
                            color: Ui.inkMuted,
                            height: 1,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
      ),
    );
  }
}

/// 侧滑抽屉：会话列表（DeepSeek 客户端式）。
class _SessionDrawer extends StatefulWidget {
  const _SessionDrawer({this.api, required this.currentSessionId, this.onClose});

  final HostSessionService? api;
  final String currentSessionId;

  /// 抽屉收起（自定义 Stack 层没有 Navigator 路由，pop 无效）。
  final VoidCallback? onClose;

  @override
  State<_SessionDrawer> createState() => _SessionDrawerState();
}

class _SessionDrawerState extends State<_SessionDrawer> {
  List<Map<String, dynamic>> _items = [];
  bool _loading = false;
  String _q = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = widget.api;
    if (api == null) return;
    setState(() => _loading = true);
    try {
      final res = await api.rpc(
        'session.list',
        {},
        timeout: const Duration(seconds: 12),
      );
      if (!mounted) return;
      setState(() {
        _items = (res['items'] as List? ?? const [])
            .whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .where((s) => s['parentSessionId'] == null)
            .toList();
      });
    } catch (_) {
      // 拉取失败保持已有列表
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  ({String title, String id}) _title(Map<String, dynamic> s) {
    final proj = s['projections'];
    final values = proj is Map ? proj['values'] : null;
    var title = values is Map ? (values['title']?.toString() ?? '') : '';
    final id = s['sessionId']?.toString() ?? '';
    if (title.isEmpty) title = id.length > 12 ? '${id.substring(0, 12)}…' : id;
    return (title: title, id: id);
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _q.isEmpty
        ? _items
        : _items.where((s) => _title(s).title.contains(_q)).toList();
    final groups = <String, List<Map<String, dynamic>>>{};
    for (final s in filtered) {
      final cwd =
          (s['cwd']?.toString() ?? '')
              .split('/')
              .where((x) => x.isNotEmpty)
              .lastOrNull ??
          '未分组';
      groups.putIfAbsent(cwd, () => []).add(s);
    }
    final keys = groups.keys.toList()..sort();
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '会话',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: Ui.ink,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '新建会话',
                  icon: Icon(Icons.add, color: Ui.accent),
                  onPressed: () async {
                    final api = widget.api;
                    if (api == null) return;
                    try {
                      final res = await api.rpc(
                        'session.create',
                        {},
                        timeout: const Duration(seconds: 12),
                      );
                      final id = res['sessionId']?.toString() ?? '';
                      if (id.isEmpty || !mounted) return;
                      Navigator.of(context).pop();
                      if (context.mounted) {
                        Navigator.of(context).pushReplacement(
                          MaterialPageRoute(
                            builder: (_) =>
                                SessionChatPage(sessionId: id, title: '新会话'),
                          ),
                        );
                      }
                    } catch (_) {}
                  },
                ),
              ],
            ),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
            child: TextField(
              onChanged: (v) => setState(() => _q = v),
              style: TextStyle(fontSize: 13, color: Ui.ink),
              decoration: InputDecoration(
                hintText: '搜索会话',
                hintStyle: TextStyle(fontSize: 13, color: Ui.inkMuted),
                prefixIcon: Icon(Icons.search, size: 17, color: Ui.inkMuted),
                isDense: true,
                filled: true,
                fillColor: Ui.bgSubtle,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          Expanded(
            child: _loading && _items.isEmpty
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                : ListView(
                    children: [
                      for (final k in keys) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                          child: Text(
                            '$k · ${groups[k]!.length}',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Ui.inkMuted,
                            ),
                          ),
                        ),
                        for (final s in groups[k]!)
                          ListTile(
                            dense: true,
                            selected: _title(s).id == widget.currentSessionId,
                            selectedTileColor: Ui.bubbleUser.withValues(
                              alpha: 0.6,
                            ),
                            leading: Icon(
                              Icons.chat_bubble_outline,
                              size: 18,
                              color: Ui.inkMuted,
                            ),
                            title: Text(
                              _title(s).title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 14, color: Ui.ink),
                            ),
                            subtitle: Text(
                              relativeTime2(
                                (s['updatedAt'] as num?)?.toInt() ?? 0,
                              ),
                              style: TextStyle(
                                fontSize: 11,
                                color: Ui.inkMuted,
                              ),
                            ),
                            onTap: () {
                              final id = _title(s).id;
                              final t = _title(s).title;
                              if (id == widget.currentSessionId) {
                                Navigator.of(context).pop();
                                return;
                              }
                              Navigator.of(context).pop();
                              Navigator.of(context).pushReplacement(
                                MaterialPageRoute(
                                  builder: (_) =>
                                      SessionChatPage(sessionId: id, title: t),
                                ),
                              );
                            },
                          ),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// 抽屉行时间（复用列表页同款相对时间）。
String relativeTime2(int ms) {
  if (ms <= 0) return '';
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  final now = DateTime.now();
  final diff = now.difference(t);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
  if (diff.inHours < 24 && now.day == t.day) return '${diff.inHours} 小时前';
  if (now.difference(DateTime(t.year, t.month, t.day)).inDays == 1) return '昨天';
  if (t.year == now.year) return '${t.month}-${t.day}';
  return '${t.year}-${t.month}-${t.day}';
}
