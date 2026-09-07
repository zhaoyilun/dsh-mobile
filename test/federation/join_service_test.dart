// dsh-federation — join 根地址派生规则单测（PAIRING-SPEC §5，表驱动）
// 规则见 JoinService.deriveApiBaseUrl：裸域名补 https://dsh-api. 前缀；
// 完整 api 地址（带 dsh-api. 前缀或带路径）原样使用；IP/localhost 不派生。
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/federation/join_service.dart';

void main() {
  group('JoinService.deriveApiBaseUrl', () {
    const cases = <(String, String)>[
      // 裸域名 → 补 https://dsh-api. 前缀
      ('example.com', 'https://dsh-api.example.com'),
      ('example.com/', 'https://dsh-api.example.com'), // 尾部斜杠归一
      ('  example.com  ', 'https://dsh-api.example.com'), // 首尾空白归一
      ('example.org', 'https://dsh-api.example.org'),
      // 完整 registry 地址 → 原样
      ('https://dsh-api.example.com', 'https://dsh-api.example.com'),
      ('https://dsh-api.example.com/', 'https://dsh-api.example.com'),
      ('http://dsh-api.local:8787', 'http://dsh-api.local:8787'), // 带 dsh-api 前缀的本地联调地址
      // 有 scheme 的裸域名（host 不带 dsh-api.、无路径）→ 同样派生
      ('http://example.com', 'https://dsh-api.example.com'),
      ('https://example.com', 'https://dsh-api.example.com'),
      // 完整 api 地址（带路径）→ 原样使用
      ('https://dsh-api.example.com/v1', 'https://dsh-api.example.com/v1'),
      ('https://api.example.com/v1/pairing/join', 'https://api.example.com/v1/pairing/join'),
      // IP / localhost（本地联调，派生无意义）→ 原样使用
      ('http://127.0.0.1:8787', 'http://127.0.0.1:8787'),
      ('http://localhost:8787', 'http://localhost:8787'),
    ];
    for (final (input, expected) in cases) {
      test('"$input" → "$expected"', () {
        expect(JoinService.deriveApiBaseUrl(input), expected);
      });
    }

    test('空输入抛 FormatException', () {
      expect(() => JoinService.deriveApiBaseUrl('  '), throwsFormatException);
    });
  });
}
