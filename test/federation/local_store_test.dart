// dsh-federation — 本地历史库合并逻辑单测（PAIRING-SPEC §5）
// sqflite 用 sqflite_common_ffi 内存数据库（databaseFactory 注入），不碰平台通道。
// 覆盖：upsertSessions 覆盖合并、upsertMessages 按 seq 幂等（INSERT OR REPLACE）、
// sessionsStream 响应式推送、发送回显（负 seq）清除、history 归一化纯函数。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:dsh_mobile/federation/store/local_store.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  StoreService newStore() =>
      StoreService(databaseFactory: databaseFactoryFfi, path: inMemoryDatabasePath, singleInstance: false);

  StoredMessage msg(String sessionId, int seq, String role, String text, {int ts = 1000}) => StoredMessage(
        sessionId: sessionId,
        dshId: 'dsh_1',
        seq: seq,
        role: role,
        contentJson: jsonEncode({
          'message': {'role': role, 'content': [{'type': 'text', 'text': text}]}
        }),
        ts: ts,
      );

  group('StoreService（内存库）', () {
    test('upsertSessions：同 id 覆盖合并，按 updated_at 倒序', () async {
      final store = newStore();
      await store.upsertSessions('dsh_1', [
        StoredSession(id: 's1', dshId: 'dsh_1', title: '旧标题', updatedAt: 100),
        StoredSession(id: 's2', dshId: 'dsh_1', title: 'B', updatedAt: 300),
      ]);
      await store.upsertSessions('dsh_1', [
        StoredSession(id: 's1', dshId: 'dsh_1', title: '新标题', updatedAt: 200),
      ]);
      final list = await store.sessions('dsh_1');
      expect(list.length, 2);
      expect(list.first.id, 's2'); // updated_at 300 在前
      expect(list.last.title, '新标题'); // s1 被覆盖而非重复插入
    });

    test('upsertMessages：按 (session_id, seq) 幂等，重复合并不产生重复行', () async {
      final store = newStore();
      await store.upsertSessions('dsh_1', [StoredSession(id: 's1', dshId: 'dsh_1', updatedAt: 1)]);
      final first = [
        msg('s1', 101, 'user', '你好'),
        msg('s1', 102, 'assistant', '在的'),
      ];
      await store.upsertMessages('dsh_1', 's1', first);
      // 二次合并：102 内容更新 + 103 新增 → 仍应只有 3 行
      await store.upsertMessages('dsh_1', 's1', [
        msg('s1', 102, 'assistant', '在的（修订）'),
        msg('s1', 103, 'assistant', '完成'),
      ]);
      final rows = await store.messages('s1');
      expect(rows.length, 3);
      expect(rows.map((m) => m.seq).toList(), [101, 102, 103]);
      expect(rows[1].content['message']['content'][0]['text'], '在的（修订）');
      // 不同会话同 seq 不冲突（唯一键含 session_id）
      await store.upsertMessages('dsh_1', 's2', [msg('s2', 101, 'user', '另一会话')]);
      expect((await store.messages('s2')).length, 1);
    });

    test('messages：确认行按 seq 升序，负 seq 回显沉底按 ts 排序', () async {
      final store = newStore();
      await store.upsertMessages('dsh_1', 's1', [
        msg('s1', 5, 'assistant', '早'),
        msg('s1', 3, 'user', '问'),
        msg('s1', -2000, 'user', '回显B', ts: 2000),
        msg('s1', -1000, 'user', '回显A', ts: 1000),
      ]);
      final rows = await store.messages('s1');
      expect(rows.map((m) => m.seq).toList(), [3, 5, -1000, -2000]);
      expect(rows[2].content['message']['content'][0]['text'], '回显A'); // 同为负 seq 时按 ts 升序
    });

    test('removeUserEcho：确认消息落库前清除同文本回显', () async {
      final store = newStore();
      await store.upsertMessages('dsh_1', 's1', [
        msg('s1', -1000, 'user', '刚发出的', ts: 1000),
        msg('s1', -900, 'user', '另一条', ts: 1100),
      ]);
      await store.removeUserEcho('s1', '刚发出的');
      final rows = await store.messages('s1');
      expect(rows.length, 1);
      expect(rows.first.content['message']['content'][0]['text'], '另一条');
      // SSE 确认（正 seq）落库后不残留回显
      await store.upsertMessages('dsh_1', 's1', [msg('s1', 120, 'user', '刚发出的', ts: 1200)]);
      expect((await store.messages('s1')).length, 2);
    });

    test('sessionsStream：写入后自动推送最新列表（含本地消息计数）', () async {
      final store = newStore();
      await store.upsertSessions('dsh_1', [StoredSession(id: 's1', dshId: 'dsh_1', updatedAt: 1)]);
      final emitted = <List<StoredSession>>[];
      final sub = store.sessionsStream('dsh_1').listen(emitted.add);
      await Future<void>.delayed(const Duration(milliseconds: 50)); // onListen 快照
      await store.upsertMessages('dsh_1', 's1', [msg('s1', 1, 'user', 'hi')]);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await sub.cancel();
      expect(emitted.length, greaterThanOrEqualTo(2));
      expect(emitted.first.length, 1); // 初始快照
      expect(emitted.last.first.messageCount, 1); // 本地计数（列表响应不含 messageCount 时由库维护）
      expect(emitted.last.first.lastSeq, 1); // last_seq 随消息推进
    });

    test('dsh 隔离：不同 dsh_id 的会话互不可见', () async {
      final store = newStore();
      await store.upsertSessions('dsh_1', [StoredSession(id: 's1', dshId: 'dsh_1')]);
      await store.upsertSessions('dsh_2', [StoredSession(id: 's9', dshId: 'dsh_2')]);
      expect((await store.sessions('dsh_1')).map((s) => s.id), ['s1']);
      expect((await store.sessions('dsh_2')).map((s) => s.id), ['s9']);
    });
  });

  group('historyEntriesToMessages（归一化纯函数）', () {
    test('真实 host 形状：events=[{event:{type,seq,time,data}}]，只取完整消息与 tool 标记', () {
      final out = historyEntriesToMessages([
        {
          'event': {'type': 'user/message', 'seq': 10, 'time': 100, 'data': {'message': {'role': 'user', 'content': [{'type': 'text', 'text': '问'}]}}}
        },
        {
          'event': {'type': 'assistant/text', 'seq': 11, 'time': 101, 'data': {'text': '增量'}}
        },
        {
          'event': {'type': 'assistant/message', 'seq': 12, 'time': 102, 'data': {'message': {'role': 'assistant', 'content': [{'type': 'text', 'text': '终态全量'}]}}}
        },
        {
          'event': {'type': 'tool/call', 'seq': 13, 'time': 103, 'data': {'name': 'fs.read'}}
        },
      ], sessionId: 's1', dshId: 'dsh_1');
      expect(out.length, 3); // assistant/text 增量不入库
      expect(out[0].seq, 10);
      expect(out[0].role, 'user');
      expect(out[1].seq, 12);
      expect(out[1].role, 'assistant');
      expect(out[2].role, 'tool');
      expect(out[2].content['name'], 'fs.read');
    });

    test('mock/legacy 形状：{role,text,seq,ts} 直接入库', () {
      final out = historyEntriesToMessages([
        {'role': 'user', 'text': '你好', 'seq': 1, 'ts': 1},
        {'role': 'assistant', 'text': '在的', 'seq': 2, 'ts': 2},
        {'role': 'system', 'text': '', 'seq': 3, 'ts': 3}, // 空文本跳过
      ], sessionId: 's1', dshId: 'dsh_1');
      expect(out.length, 2);
      expect(out[0].content['message']['content'][0]['text'], '你好');
    });
  });
}
