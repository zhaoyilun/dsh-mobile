// dsh-federation — 会话列表「保留已登记工作区」合并逻辑回归测试。
// 背景：移动端「新建会话」选了指定工作区(cwd)后，host 侧 apiproxy create 若未透传 cwd
// 会把会话落到默认项目；即便 host 修复后，host 对「未记录 cwd」的会话也不会返回该字段
// （SessionSummary.cwd?: string 契约）。mergeKnownCwd 只在 host 未提供 cwd 时保留本地
// 已登记值，绝不用空串把指定工作区打回「未分组」。
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/federation/session_list_page.dart';
import 'package:dsh_mobile/federation/store/models.dart';

StoredSession sess(String id, {String cwd = '', String title = '新会话'}) => StoredSession(
      id: id,
      dshId: 'dsh_1',
      title: title,
      cwd: cwd,
      updatedAt: 1,
    );

void main() {
  group('mergeKnownCwd — host 未记录 cwd 时保留本地已登记项目', () {
    test('host 返回空 cwd + 本地有非空 cwd → 保留本地', () {
      final incoming = [sess('s1', cwd: '')];
      final out = mergeKnownCwd(incoming, {'s1': '/usr/proj/alpha'});
      expect(out.single.cwd, '/usr/proj/alpha');
    });

    test('host 返回非空 cwd → 采用 host（即使与本地不同）', () {
      final incoming = [sess('s1', cwd: '/usr/proj/host')];
      final out = mergeKnownCwd(incoming, {'s1': '/usr/proj/local'});
      expect(out.single.cwd, '/usr/proj/host');
    });

    test('无本地登记 + host 空 cwd → 保持空（未分组）', () {
      final incoming = [sess('s1', cwd: '')];
      final out = mergeKnownCwd(incoming, {});
      expect(out.single.cwd, '');
    });

    test('host 与本地 cwd 一致 → 不变（幂等）', () {
      final incoming = [sess('s1', cwd: '/usr/proj/alpha')];
      final out = mergeKnownCwd(incoming, {'s1': '/usr/proj/alpha'});
      expect(out.single.cwd, '/usr/proj/alpha');
    });

    test('仅覆盖主机空 cwd 的会话，其余原样保留（含 title/blank/updatedAt）', () {
      final incoming = [
        sess('s1', cwd: '', title: 'A'),
        sess('s2', cwd: '/usr/proj/beta', title: 'B'),
      ];
      final out = mergeKnownCwd(incoming, {'s1': '/usr/proj/alpha'});
      expect(out[0].cwd, '/usr/proj/alpha');
      expect(out[0].title, 'A');
      expect(out[1].cwd, '/usr/proj/beta');
      expect(out[1].title, 'B');
      expect(identical(out[1], incoming[1]), isTrue); // 未改动的直接复用原对象
    });
  });
}
