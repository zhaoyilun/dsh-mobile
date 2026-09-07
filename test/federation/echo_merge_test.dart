import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_mobile/federation/store/local_store_sqflite.dart' show StoreService;
import 'package:dsh_mobile/federation/store/local_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  test('sqflite: 回显行被同文本确认行合并清理（flat 历史形状）', () async {
    sqfliteFfiInit();
    final s = StoreService(databaseFactory: databaseFactoryFfi, path: inMemoryDatabasePath, singleInstance: false);
    const dshId = 'dev_x';
    const sid = 'session-x';
    // 回显（负 seq，手机旧版格式）
    await s.upsertMessages(dshId, sid, [
      StoredMessage(
        sessionId: sid, dshId: dshId, seq: -12345, role: 'user',
        contentJson: jsonEncode({
          'message': {'role': 'user', 'content': [{'type': 'text', 'text': '手机上显示所有的都是未分组'}]}
        }),
        ts: DateTime.now().millisecondsSinceEpoch,
      ),
    ]);
    // 确认行（host flat 形状：content 在 message 层无包装）
    await s.upsertMessages(dshId, sid, [
      StoredMessage(
        sessionId: sid, dshId: dshId, seq: 422648, role: 'user',
        contentJson: jsonEncode({
          'message': {'id': 'm1', 'role': 'user', 'source': {'kind': 'user'},
            'content': [{'type': 'text', 'text': '手机上显示所有的都是未分组'}]}
        }),
        ts: DateTime.now().millisecondsSinceEpoch,
      ),
    ]);
    await s.removeEchoesMatchingConfirmed(sid);
    final rows = await s.messages(sid);
    final echoes = rows.where((m) => m.seq < 0).toList();
    expect(echoes, isEmpty, reason: '同文本确认行存在时回显应被清理');
    expect(rows.where((m) => m.seq == 422648), hasLength(1));
    
  });
}
