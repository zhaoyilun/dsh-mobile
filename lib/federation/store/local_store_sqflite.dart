// dsh-federation — 本地会话/消息历史库（sqflite 实现：Android/iOS/桌面）
// 表：sessions(id PK, dsh_id, title, message_count, updated_at, last_seq)
//     messages(id 自增 PK, session_id, dsh_id, seq, role, content JSON, ts)
// 幂等：messages 以 (session_id, seq) 唯一索引 + INSERT OR REPLACE 按 seq 去重合并；
// 发送回显用负数 seq（临时行），确认消息（SSE user/message 带 seq）落库时清掉同文本回显。
// Web 平台没有 sqflite/FFI，走 local_store_memory.dart（条件导出见 local_store.dart）。
import 'dart:async';
import 'dart:convert';

import 'package:path/path.dart' as p;
import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';  // re-export sqflite 全部符号（Database/DatabaseFactory 等）

import 'models.dart';

export 'models.dart';

/// 会话/消息本地库服务。生产用 sqflite 插件默认工厂；
/// 测试注入 databaseFactory（sqflite_common_ffi）+ inMemoryDatabasePath + singleInstance:false
/// （ffi 工厂按 path 复用单例，不关掉会跨用例共享同一内存库）。
DatabaseFactory? _ffiFactory;

/// 桌面工厂：首次调用初始化 FFI（幂等）。
DatabaseFactory _desktopFactory() {
  sqfliteFfiInit();
  return _ffiFactory ??= databaseFactoryFfi;
}

String _normEchoText(String t) => t.replaceAll(RegExp(r'📷\s*图片'), '').trim();

class StoreService {
  StoreService({DatabaseFactory? databaseFactory, String? path, bool singleInstance = true})
      : _factoryOverride = databaseFactory,
        _pathOverride = path,
        _singleInstance = singleInstance;

  /// 应用级共享实例（默认数据库文件 dsh_federation.db）。
  static final StoreService shared = StoreService();

  final DatabaseFactory? _factoryOverride;
  final String? _pathOverride;
  final bool _singleInstance;
  Database? _db;
  final Map<String, StreamController<List<StoredSession>>> _sessionStreams = {};

  Future<Database> _open() async {
    final db = _db;
    if (db != null) return db;
    // 桌面（FFI 工厂）的 getDatabasesPath 不可靠（可能落到无权限的工作目录）→ 显式用应用支持目录。
    final String path;
    if (_pathOverride != null) {
      path = _pathOverride;
    } else if (Platform.isMacOS || Platform.isLinux || Platform.isWindows) {
      final dir = Platform.environment['DSH_STORE_DIR'] ??
          '${Platform.environment['HOME'] ?? '.'}/Library/Application Support/dsh_mobile';
      Directory(dir).createSync(recursive: true);
      path = p.join(dir, 'dsh_federation.db');
    } else {
      path = p.join(await getDatabasesPath(), 'dsh_federation.db');
    }
    final options = OpenDatabaseOptions(
      version: 3,   // v3: parent_session_id 列（v2 已加 cwd）
      singleInstance: _singleInstance,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE sessions(
            id TEXT PRIMARY KEY,
            dsh_id TEXT NOT NULL,
            title TEXT NOT NULL DEFAULT '',
            cwd TEXT NOT NULL DEFAULT '',
            parent_session_id TEXT,
            message_count INTEGER NOT NULL DEFAULT 0,
            updated_at INTEGER NOT NULL DEFAULT 0,
            last_seq INTEGER NOT NULL DEFAULT 0
          )
        ''');
        await db.execute('''
          CREATE TABLE messages(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT NOT NULL,
            dsh_id TEXT NOT NULL,
            seq INTEGER NOT NULL,
            role TEXT NOT NULL,
            content TEXT NOT NULL,
            ts INTEGER NOT NULL
          )
        ''');
        await db.execute('CREATE UNIQUE INDEX idx_messages_session_seq ON messages(session_id, seq)');
      },
      onUpgrade: (db, oldV, newV) async {
        if (oldV < 2) {
          await db.execute("ALTER TABLE sessions ADD COLUMN cwd TEXT NOT NULL DEFAULT ''");
        }
        if (oldV < 3) {
          await db.execute("ALTER TABLE sessions ADD COLUMN parent_session_id TEXT");
        }
      },
    );
    // 桌面端（macOS/Linux/Windows）sqflite 无原生插件 → 切 FFI 工厂（生产与测试同源）
    final effectiveFactory = _factoryOverride ??
        (Platform.isMacOS || Platform.isLinux || Platform.isWindows ? _desktopFactory() : databaseFactory);
    final opened = await effectiveFactory.openDatabase(path, options: options);
    _db = opened;
    return opened;
  }

  // ---------- 写：幂等合并 ----------

  /// 批量 upsert 会话（session.list 刷新合并；同一 id 重复写覆盖，天然幂等）。
  Future<void> upsertSessions(String dshId, List<StoredSession> sessions) async {
    if (sessions.isEmpty) return;
    final db = await _open();
    final batch = db.batch();
    for (final s in sessions) {
      if (s.id.isEmpty) continue;
      batch.insert('sessions', {
        'id': s.id,
        'dsh_id': dshId,
        'title': s.title,
        'cwd': s.cwd,
        'parent_session_id': s.parentSessionId,
        'message_count': s.messageCount,
        'updated_at': s.updatedAt,
        'last_seq': s.lastSeq,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
    await _emitSessions(dshId);
  }

  /// 每会话本地保留的确认消息上限（UI 一次只加载最近 50 条，更早的缓存
  /// 纯属存储负担；负 seq 回显临时行不受此限制）。
  static const _maxMessagesPerSession = 2000;

  /// 批量 upsert 消息（INSERT OR REPLACE：按 (session_id, seq) 唯一索引幂等），
  /// 并同步推进 sessions.last_seq / updated_at。
  Future<void> upsertMessages(String dshId, String sessionId, List<StoredMessage> messages) async {
    if (messages.isEmpty) return;
    final db = await _open();
    final batch = db.batch();
    for (final m in messages) {
      batch.insert('messages', {
        'session_id': sessionId,
        'dsh_id': dshId,
        'seq': m.seq,
        'role': m.role,
        'content': m.contentJson,
        'ts': m.ts,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
    await _bumpSession(dshId, sessionId, messages);
    await _pruneMessages(db, sessionId);
    await _emitSessions(dshId);
  }

  Future<void> _pruneMessages(Database db, String sessionId) async {
    await db.rawDelete('''
      DELETE FROM messages WHERE session_id = ? AND seq > 0 AND id NOT IN (
        SELECT id FROM messages WHERE session_id = ? AND seq > 0 ORDER BY seq DESC LIMIT ?
      )
    ''', [sessionId, sessionId, _maxMessagesPerSession]);
  }

  Future<void> upsertMessage(StoredMessage m) => upsertMessages(m.dshId, m.sessionId, [m]);

  /// 确认消息落库前清掉同文本的发送回显（负 seq 临时行）。
  /// 删除超过 [olderThanMs] 未确认的回显（负 seq 临时行）——兜底同上。
  Future<void> removeStaleEchoes(String sessionId, {required int olderThanMs}) async {
    final cutoff = DateTime.now().millisecondsSinceEpoch - olderThanMs;
    final db = await _open();
    await db.delete('messages', where: 'session_id = ? AND seq < 0 AND ts < ?', whereArgs: [sessionId, cutoff]);
  }

  /// 历史同步后的回显合并（语义同内存版）：同文本确认行存在则删回显行。
  Future<void> removeEchoesMatchingConfirmed(String sessionId) async {
    final db = await _open();
    final confirmed = await db.rawQuery(
      "SELECT content FROM messages WHERE session_id = ? AND seq >= 0 AND role = 'user'",
      [sessionId],
    );
    final texts = <String>{};
    for (final row in confirmed) {
      try {
        final content = jsonDecode(row['content'] as String) as Map;
        final message = content['message'] as Map?;
        final blocks = message?['content'] as List? ?? const [];
        final t = _normEchoText(blocks.whereType<Map>().map((b) => b['text']?.toString() ?? '').join());
        if (t.isNotEmpty) texts.add(t);
      } catch (_) {}
    }
    if (texts.isEmpty) return;
    final echoes = await db.query('messages',
        columns: ['id', 'content'], where: 'session_id = ? AND seq < 0 AND role = ?', whereArgs: [sessionId, 'user']);
    for (final row in echoes) {
      try {
        final content = jsonDecode(row['content'] as String) as Map;
        final message = content['message'] as Map?;
        final blocks = message?['content'] as List? ?? const [];
        final t = _normEchoText(blocks.whereType<Map>().map((b) => b['text']?.toString() ?? '').join());
        if (texts.contains(t)) {
          await db.delete('messages', where: 'id = ?', whereArgs: [row['id']]);
        }
      } catch (_) {
        await db.delete('messages', where: 'id = ?', whereArgs: [row['id']]);
      }
    }
  }

  Future<void> removeUserEcho(String sessionId, String text) async {
    if (text.isEmpty) return;
    final db = await _open();
    final rows = await db.query('messages',
        columns: ['id', 'content'], where: 'session_id = ? AND seq < 0 AND role = ?', whereArgs: [sessionId, 'user']);
    for (final row in rows) {
      try {
        final content = jsonDecode(row['content'] as String) as Map;
        final message = content['message'] as Map?;
        final blocks = message?['content'] as List? ?? const [];
        final echoText = blocks.whereType<Map>().map((b) => b['text']?.toString() ?? '').join();
        if (echoText == text) {
          await db.delete('messages', where: 'id = ?', whereArgs: [row['id']]);
        }
      } catch (_) {
        // 回显行损坏：直接删除
        await db.delete('messages', where: 'id = ?', whereArgs: [row['id']]);
      }
    }
  }

  /// 用本地消息水位推进会话行（last_seq 取已确认事件的最大 seq；updated_at 取最大 ts）。
  Future<void> _bumpSession(String dshId, String sessionId, List<StoredMessage> messages) async {
    final maxSeq = messages.fold<int>(0, (a, m) => m.seq > a ? m.seq : a);
    final maxTs = messages.fold<int>(0, (a, m) => m.ts > a ? m.ts : a);
    final db = await _open();
    final updated = await db.rawUpdate('''
      UPDATE sessions SET
        last_seq = MAX(last_seq, ?),
        updated_at = MAX(updated_at, ?)
      WHERE id = ?
    ''', [maxSeq, maxTs, sessionId]);
    // 新会话首条消息时可能尚无 sessions 行（如 session.create 后直接发送）：补一行占位。
    // 注意不能用 UPSERT（INSERT ... ON CONFLICT DO UPDATE）：它需要 SQLite ≥ 3.24，
    // 而 Android ≤ 9（API ≤ 28）系统自带 SQLite 是 3.8–3.22，遇到就抛语法错误。
    if (updated == 0 && (maxSeq != 0 || maxTs != 0)) {
      await db.insert(
        'sessions',
        {
          'id': sessionId,
          'dsh_id': dshId,
          'title': '',
          'cwd': '',
          'message_count': 0,
          'updated_at': maxTs,
          'last_seq': maxSeq,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
  }

  // ---------- 读 ----------

  /// 某会话的全部消息（确认行按 seq 升序；回显临时行 seq<0 沉底按 ts 升序）。
  Future<List<StoredMessage>> messages(String sessionId) async {
    final db = await _open();
    final rows = await db.rawQuery('''
      SELECT * FROM messages WHERE session_id = ?
      ORDER BY CASE WHEN seq < 0 THEN 1 ELSE 0 END ASC,
               CASE WHEN seq < 0 THEN ts ELSE seq END ASC
    ''', [sessionId]);
    return rows.map(_rowToMessage).toList();
  }

  /// 会话列表（响应式）：onListen 先发当前快照，此后每次写入自动重发。
  Stream<List<StoredSession>> sessionsStream(String dshId) {
    final existing = _sessionStreams[dshId];
    if (existing != null) return existing.stream;
    final controller = StreamController<List<StoredSession>>.broadcast(onListen: () => _emitSessions(dshId));
    _sessionStreams[dshId] = controller;
    return controller.stream;
  }

  Future<List<StoredSession>> sessions(String dshId) async {
    final db = await _open();
    final rows = await db.rawQuery('''
      SELECT s.id, s.dsh_id, s.title, s.cwd, s.parent_session_id, s.updated_at, s.last_seq,
             (SELECT COUNT(*) FROM messages m WHERE m.session_id = s.id) AS message_count
      FROM sessions s WHERE s.dsh_id = ?
      ORDER BY s.updated_at DESC
    ''', [dshId]);
    return rows
        .map((r) => StoredSession(
              id: r['id'] as String,
              dshId: r['dsh_id'] as String,
              title: (r['title'] as String?) ?? '',
              cwd: (r['cwd'] as String?) ?? '',
              parentSessionId: r['parent_session_id'] as String?,
              messageCount: (r['message_count'] as num?)?.toInt() ?? 0,
              updatedAt: (r['updated_at'] as num?)?.toInt() ?? 0,
              lastSeq: (r['last_seq'] as num?)?.toInt() ?? 0,
            ))
        .toList();
  }

  Future<void> _emitSessions(String dshId) async {
    final controller = _sessionStreams[dshId];
    if (controller == null || controller.isClosed) return;
    try {
      controller.add(await sessions(dshId));
    } catch (_) {
      // 读失败不打断流
    }
  }

  StoredMessage _rowToMessage(Map<String, Object?> r) => StoredMessage(
        id: r['id'] as int?,
        sessionId: r['session_id'] as String,
        dshId: r['dsh_id'] as String,
        seq: (r['seq'] as num?)?.toInt() ?? 0,
        role: r['role'] as String? ?? 'system',
        contentJson: r['content'] as String? ?? '{}',
        ts: (r['ts'] as num?)?.toInt() ?? 0,
      );
}
