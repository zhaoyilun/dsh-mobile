// dsh-federation — 本地库 Web 实现（内存版）
// 浏览器没有 sqflite/FFI，Web 上会话/消息只活在本次页面会话里
// （刷新即失；聊天页每次打开都会走 session.history 全量拉取，功能不受影响，
// 只损失「离线冷启动也有历史」）。语义与 sqflite 版对齐：
// (sessionId, seq) 幂等、负 seq 回显沉底、sessionsStream 响应式。
import 'dart:async';

import 'models.dart';

export 'models.dart';

String _normEchoText(String t) => t.replaceAll(RegExp(r'📷\s*图片'), '').trim();

class StoreService {
  StoreService();

  /// 应用级共享实例。
  static final StoreService shared = StoreService();

  final Map<String, StoredSession> _sessions = {}; // key: sessionId
  final Map<String, List<StoredMessage>> _messages = {}; // key: sessionId
  final Map<String, StreamController<List<StoredSession>>> _sessionStreams = {};

  Future<void> upsertSessions(String dshId, List<StoredSession> sessions) async {
    for (final s in sessions) {
      if (s.id.isEmpty) continue;
      _sessions[s.id] = s;
    }
    await _emitSessions(dshId);
  }

  Future<void> upsertMessages(String dshId, String sessionId, List<StoredMessage> messages) async {
    final list = _messages[sessionId] ??= [];
    for (final m in messages) {
      // 按 (sessionId, seq) 幂等：同 seq 覆盖。
      final idx = list.indexWhere((e) => e.seq == m.seq);
      if (idx >= 0) {
        list[idx] = m;
      } else {
        list.add(m);
      }
    }
    // 会话水位推进（无行则补占位，与 sqflite 版 _bumpSession 语义一致）。
    final s = _sessions[sessionId];
    final maxSeq = messages.fold<int>(0, (a, m) => m.seq > a ? m.seq : a);
    final maxTs = messages.fold<int>(0, (a, m) => m.ts > a ? m.ts : a);
    if (s != null) {
      _sessions[sessionId] = StoredSession(
        id: s.id,
        dshId: s.dshId,
        title: s.title,
        cwd: s.cwd,
        messageCount: s.messageCount,
        updatedAt: s.updatedAt > maxTs ? s.updatedAt : maxTs,
        lastSeq: s.lastSeq > maxSeq ? s.lastSeq : maxSeq,
      );
    } else if (maxSeq != 0 || maxTs != 0) {
      _sessions[sessionId] = StoredSession(id: sessionId, dshId: dshId, updatedAt: maxTs, lastSeq: maxSeq);
    }
    await _emitSessions(dshId);
  }

  Future<void> upsertMessage(StoredMessage m) => upsertMessages(m.dshId, m.sessionId, [m]);

  Future<void> removeUserEcho(String sessionId, String text) async {
    final list = _messages[sessionId];
    if (list == null || text.isEmpty) return;
    list.removeWhere((m) {
      if (m.seq >= 0 || m.role != 'user') return false;
      final blocks = m.content['message']?['content'] as List? ?? const [];
      final echoText = blocks.whereType<Map>().map((b) => b['text']?.toString() ?? '').join();
      return echoText == text;
    });
  }

  /// 删除超过 [olderThanMs] 未确认的回显（负 seq 临时行）。
  /// 兜底：纯图/漏确认场景下，旧回显不再永驻（确认行若存在会以正确顺序显示）。
  Future<void> removeStaleEchoes(String sessionId, {required int olderThanMs}) async {
    final list = _messages[sessionId];
    if (list == null) return;
    final cutoff = DateTime.now().millisecondsSinceEpoch - olderThanMs;
    list.removeWhere((m) => m.seq < 0 && m.ts < cutoff);
  }

  /// 历史同步后的回显合并：已存在同文本确认行（seq>=0）的回显（seq<0）删除。
  /// 场景：确认事件在未开会话时错过（旧 APK queue 消息），回显残留导致「很久前的消息一直出现在最底部」。
  Future<void> removeEchoesMatchingConfirmed(String sessionId) async {
    final list = _messages[sessionId];
    if (list == null) return;
    final confirmed = list.where((m) => m.seq >= 0 && m.role == 'user').map((m) {
      final blocks = m.content['message']?['content'] as List? ?? const [];
      return _normEchoText(blocks.whereType<Map>().map((b) => b['text']?.toString() ?? '').join());
    }).where((t) => t.isNotEmpty).toSet();
    if (confirmed.isEmpty) return;
    list.removeWhere((m) {
      if (m.seq >= 0 || m.role != 'user') return false;
      final blocks = m.content['message']?['content'] as List? ?? const [];
      final t = _normEchoText(blocks.whereType<Map>().map((b) => b['text']?.toString() ?? '').join());
      return confirmed.contains(t);
    });
  }

  /// 确认行按 seq 升序；回显临时行（seq<0）沉底按 ts 升序。
  Future<List<StoredMessage>> messages(String sessionId) async {
    final list = _messages[sessionId] ?? const <StoredMessage>[];
    final confirmed = list.where((m) => m.seq >= 0).toList()..sort((a, b) => a.seq.compareTo(b.seq));
    final echoes = list.where((m) => m.seq < 0).toList()..sort((a, b) => a.ts.compareTo(b.ts));
    return [...confirmed, ...echoes];
  }

  Stream<List<StoredSession>> sessionsStream(String dshId) {
    final existing = _sessionStreams[dshId];
    if (existing != null) return existing.stream;
    final controller = StreamController<List<StoredSession>>.broadcast(onListen: () => _emitSessions(dshId));
    _sessionStreams[dshId] = controller;
    return controller.stream;
  }

  Future<List<StoredSession>> sessions(String dshId) async {
    final out = _sessions.values.where((s) => s.dshId == dshId).toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return out
        .map((s) => StoredSession(
              id: s.id,
              dshId: s.dshId,
              title: s.title,
              cwd: s.cwd,
              messageCount: _messages[s.id]?.where((m) => m.seq >= 0).length ?? 0,
              updatedAt: s.updatedAt,
              lastSeq: s.lastSeq,
            ))
        .toList();
  }

  Future<void> _emitSessions(String dshId) async {
    final controller = _sessionStreams[dshId];
    if (controller == null || controller.isClosed) return;
    controller.add(await sessions(dshId));
  }
}
