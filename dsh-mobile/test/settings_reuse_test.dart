import 'package:dsh_mobile/config_store.dart';
import 'package:dsh_mobile/pages/settings_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const publicConfig = AppConfig(
    mode: ConnectionMode.public,
    serverUrl: 'https://relay.example.com',
    token: 'phone-pass',
  );

  group('canReuseStoredCredential', () {
    test('模式与 origin 都不变时允许留空复用', () {
      expect(
        canReuseStoredCredential(
          publicConfig,
          ConnectionMode.public,
          'https://relay.example.com/',
        ),
        isTrue,
      );
      // 默认端口写法不同但 origin 相同。
      expect(
        canReuseStoredCredential(
          publicConfig,
          ConnectionMode.public,
          'https://relay.example.com:443',
        ),
        isTrue,
      );
    });

    test('模式变化后禁止复用', () {
      expect(
        canReuseStoredCredential(
          publicConfig,
          ConnectionMode.lan,
          'https://relay.example.com',
        ),
        isFalse,
      );
    });

    test('服务器 host 或 port 变化后禁止复用', () {
      expect(
        canReuseStoredCredential(
          publicConfig,
          ConnectionMode.public,
          'https://other.example.com',
        ),
        isFalse,
      );
      expect(
        canReuseStoredCredential(
          publicConfig,
          ConnectionMode.public,
          'https://relay.example.com:8443',
        ),
        isFalse,
      );
    });

    test('无旧配置时禁止复用', () {
      expect(
        canReuseStoredCredential(
          null,
          ConnectionMode.public,
          'https://relay.example.com',
        ),
        isFalse,
      );
    });
  });
}
