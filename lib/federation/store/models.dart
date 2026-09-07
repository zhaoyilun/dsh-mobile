// dsh-federation — 本地库纯模型（全平台可用，无 io 依赖）
// 会话行 / 消息行 / host history 归一化函数。
import 'dart:convert';

/// 会话行（列表页渲染单元）。
class StoredSession {
  StoredSession({
    required this.id,
    required this.dshId,
    this.title = '',
    this.cwd = '',
    this.messageCount = 0,
    this.updatedAt = 0,
    this.lastSeq = 0,
    this.parentSessionId,
    this.blank = false,
  });

  final String id;
  final String dshId;
  final String title;

  /// 会话的工作目录（host list 的 cwd）——按项目分组用。
  final String cwd;
  final int messageCount;
  final int updatedAt;
  final int lastSeq;

  /// 非空 = subagent（子智能体）会话：host 拒绝移动端直接读历史
  /// （"subagent Sessions require their durable parent address"），列表应过滤。
  final String? parentSessionId;

  /// host 标记的空白会话。
  final bool blank;

  /// 移动端列表应显示的会话：主会话且非空（subagent 内部会话没有独立可读历史）。
  bool get mobileVisible => parentSessionId == null && !blank;

  /// 从 host `session.list` 条目归一化：
  /// 真实 host：{sessionId, updatedAt, projections:{asOfSeq, values:{title}}}
  /// mock：{id, title, messageCount, updatedAt, lastSeq}
  factory StoredSession.fromListJson(Map<String, dynamic> json, String dshId) {
    final projections = json['projections'] as Map?;
    final values = projections?['values'] as Map?;
    final asOfSeq = (projections?['asOfSeq'] as num?)?.toInt() ?? 0;
    return StoredSession(
      id: json['sessionId']?.toString() ?? json['id']?.toString() ?? '',
      dshId: dshId,
      title: (values?['title'] ?? json['title'] ?? '').toString(),
      cwd: json['cwd']?.toString() ?? '',
      messageCount: (json['messageCount'] as num?)?.toInt() ?? (json['message_count'] as num?)?.toInt() ?? 0,
      updatedAt: (json['updatedAt'] as num?)?.toInt() ?? (json['updated_at'] as num?)?.toInt() ?? 0,
      lastSeq: (json['lastSeq'] as num?)?.toInt() ?? (json['last_seq'] as num?)?.toInt() ?? asOfSeq,
      parentSessionId: json['parentSessionId']?.toString(),
      blank: json['blank'] == true,
    );
  }
}

/// 消息行（聊天页渲染单元；content 为 JSON：{message:{role,content,...}} 或 {name}）。
class StoredMessage {
  StoredMessage({
    this.id,
    required this.sessionId,
    required this.dshId,
    required this.seq,
    required this.role,
    required this.contentJson,
    required this.ts,
  });

  final int? id;
  final String sessionId;
  final String dshId;

  /// 正数 = host 事件 seq（幂等键）；负数 = 发送回显临时行（按 ts 排序沉底）。
  final int seq;
  final String role;
  final String contentJson;
  final int ts;

  Map<String, dynamic> get content {
    try {
      return (jsonDecode(contentJson) as Map).cast<String, dynamic>();
    } catch (_) {
      return <String, dynamic>{};
    }
  }
}

/// host `session.history` 条目 → 本地消息行（纯函数，便于单测）。
/// 兼容两种形状：
/// - 真实 host：{event:{type, seq, time, data}}（list 在 `events` 键下）
/// - mock/legacy：{role, text, ts, seq}（list 在 `entries` 键下）
/// 策略：只入库「完整消息」（user/message、assistant/message）与 tool 标记；
/// assistant/text 增量不入库（其后的 assistant/message 终态事件会覆盖全量文本）。
List<StoredMessage> historyEntriesToMessages(List<dynamic> raw, {required String sessionId, required String dshId}) {
  final out = <StoredMessage>[];
  for (final e in raw) {
    if (e is! Map) continue;
    final m = e.cast<String, dynamic>();
    final ev = m['event'] as Map?;
    if (ev != null) {
      final type = ev['type']?.toString() ?? '';
      final seq = (ev['seq'] as num?)?.toInt() ?? 0;
      final ts = (ev['time'] as num?)?.toInt() ?? 0;
      final data = ev['data'] is Map ? (ev['data'] as Map).cast<String, dynamic>() : const <String, dynamic>{};
      if (type == 'user/message' || type == 'assistant/message') {
        // 兼容双形状：SSE 实时事件 data={turn,step,message}；history 快照 data=平铺
        // （id/role/source/content 直接在 data 层）——统一包装成 {'message': msg} 存储，
        // 读取侧（_extractText / echo 匹配 / 气泡）无需感知差异。
        final msg = data['message'] is Map ? (data['message'] as Map).cast<String, dynamic>() : data;
        // 系统注入（router 引导、审批旁白等 source.kind='plugin'）不渲染为用户消息
        final source = msg['source'];
        if (source is Map && source['kind']?.toString() == 'plugin') continue;
        if (msg.isEmpty) continue;
        out.add(StoredMessage(
          sessionId: sessionId,
          dshId: dshId,
          seq: seq,
          role: type.startsWith('user') ? 'user' : 'assistant',
          contentJson: jsonEncode({'message': msg}),
          ts: ts,
        ));
      } else if (type.startsWith('tool/')) {
        out.add(StoredMessage(
          sessionId: sessionId,
          dshId: dshId,
          seq: seq,
          role: 'tool',
          contentJson: jsonEncode({'name': data['name'] ?? type}),
          ts: ts,
        ));
      }
      continue;
    }
    // mock/legacy 形状：直接是消息
    final text = m['text']?.toString() ?? '';
    if (text.isEmpty) continue;
    final role = m['role']?.toString() ?? 'system';
    out.add(StoredMessage(
      sessionId: sessionId,
      dshId: dshId,
      seq: (m['seq'] as num?)?.toInt() ?? 0,
      role: role,
      contentJson: jsonEncode({
        'message': {'role': role, 'content': [{'type': 'text', 'text': text}]}
      }),
      ts: (m['ts'] as num?)?.toInt() ?? 0,
    ));
  }
  return out;
}
