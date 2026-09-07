// dsh-federation — host SSE 事件流客户端（/api/events.mux 的 Dart 侧实现）
// 帧协议（host/apiproxy events.schema）：SSE data 行 = ServerRequest 信封，payload = MuxFrame；
// 帧分隔 \n\n；data 前缀 "data: "。连接即全量推送（payload:{}），按 sessionId 筛选。
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'http_client_factory.dart' if (dart.library.html) 'http_client_factory_web.dart';
import 'local_api.dart';

/// Mux 帧（简化视图：只取本会话需要的字段）。
class MuxFrame {
  MuxFrame({
    required this.type,
    required this.sessionId,
    this.event,
    this.queueItems,
    this.lastSeq,
    this.rpcId,
    this.approvalId,
    this.toolName,
    this.reason,
    this.outcome,
    this.questions,
    this.questionRpcId,
  });

  final String type;
  final String? sessionId;
  final Map<String, dynamic>? event; // session/event 的 {type, seq, time, data}
  final List<Map<String, dynamic>>? queueItems; // session/queue 的 items
  final int? lastSeq;

  /// 本帧的 SSE 信封 rpcId（host 端 pending 表路由键）：
  /// approval/question 应答必须带回这个 id（client-response 信封的 rpcId 字段）。
  final String? rpcId;

  // approval/requested | approval/resolved 的帧顶层字段（注意：不在 event 里！）
  final String? approvalId;
  final String? toolName;
  final String? reason;
  final String? outcome; // allowed-once | rejected | cancelled | unavailable

  // question/requested 的 questions[]；question/resolved 的 questionRpcId
  final List<Map<String, dynamic>>? questions;
  final String? questionRpcId;

  static MuxFrame? parse(Map<String, dynamic> raw, {String? envelopeRpcId}) {
    final type = raw['type']?.toString();
    if (type == null) return null;
    final sessionId = raw['sessionId']?.toString();
    Map<String, dynamic>? event;
    if (raw['event'] is Map) event = (raw['event'] as Map).cast<String, dynamic>();
    List<Map<String, dynamic>>? items;
    if (raw['items'] is List) {
      items = (raw['items'] as List).map((e) => (e as Map).cast<String, dynamic>()).toList();
    }
    List<Map<String, dynamic>>? questions;
    if (raw['questions'] is List) {
      questions = (raw['questions'] as List).map((e) => (e as Map).cast<String, dynamic>()).toList();
    }
    return MuxFrame(
      type: type,
      sessionId: sessionId,
      event: event,
      queueItems: items,
      lastSeq: (raw['lastSeq'] as num?)?.toInt(),
      rpcId: envelopeRpcId,
      approvalId: raw['approvalId']?.toString(),
      toolName: raw['toolName']?.toString(),
      reason: raw['reason']?.toString(),
      outcome: raw['outcome']?.toString(),
      questions: questions,
      questionRpcId: raw['questionRpcId']?.toString(),
    );
  }
}

/// 打开 /api/events.mux（或 events.host）并产出 MuxFrame 流。
class HostEventsStream {
  HostEventsStream({required this.session});
  final HostSession session;

  /// 空闲看门狗：这么久没收到任何字节（含 SSE 注释心跳）就判定连接已死
  /// （典型：手机 WiFi↔蜂窝切换后的 TCP 半开），抛错让调用方走重连。
  static const idleTimeout = Duration(seconds: 90);

  Stream<MuxFrame> open(String path /* '/api/events.mux' */) async* {
    final client = createHttpClient();
    final req = http.Request('GET', Uri.parse('${session.baseUrl}$path'))..headers.addAll(session.headers);
    try {
      final res = await client.send(req);
      if (res.statusCode != 200) {
        throw StateError('sse open failed: http ${res.statusCode}');
      }
      String buffer = '';
      final lines = res.stream
          .transform(utf8.decoder)
          .timeout(idleTimeout, onTimeout: (sink) => sink.addError(StateError('sse idle ${idleTimeout.inSeconds}s（连接可能已半开）')));
      await for (final chunk in lines) {
        buffer += chunk;
        int boundary;
        while ((boundary = buffer.indexOf('\n\n')) != -1) {
          final eventBlock = buffer.substring(0, boundary);
          buffer = buffer.substring(boundary + 2);
          final dataLines = eventBlock
              .split('\n')
              .where((l) => l.startsWith('data: '))
              .map((l) => l.substring(6))
              .join();
          if (dataLines.isEmpty) continue;
          try {
            final full = jsonDecode(dataLines) as Map<String, dynamic>;
            final payload = full['payload'];
            if (payload is Map<String, dynamic>) {
              final frame = MuxFrame.parse(payload, envelopeRpcId: full['rpcId']?.toString());
              if (frame != null) yield frame;
            }
          } catch (_) {
            // 帧格式不符：跳过（host 侧已按 schema 校验，理论不出现）
          }
        }
      }
    } finally {
      client.close();
    }
  }
}
