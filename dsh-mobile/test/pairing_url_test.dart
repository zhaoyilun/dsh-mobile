import 'package:dsh_mobile/config_store.dart';
import 'package:dsh_mobile/pairing_url.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('buildPairingUrl · public(公网服务器)', () {
    test('https 公网 → <server>/m/?pass=<phone-pass>', () {
      const config = AppConfig(
        mode: ConnectionMode.public,
        serverUrl: 'https://relay.example.com',
        token: 'phone-pass',
      );
      final url = buildPairingUrl(config);
      expect(url.scheme, 'https');
      expect(url.host, 'relay.example.com');
      expect(url.path, '/m/');
      expect(url.queryParameters['pass'], 'phone-pass');
      // 公网模式不再带 token 参数,也不落桌面页。
      expect(url.queryParameters.containsKey('token'), isFalse);
    });

    test('https 带端口', () {
      const config = AppConfig(
        mode: ConnectionMode.public,
        serverUrl: 'https://relay.example.com:8443',
        token: 't',
      );
      final url = buildPairingUrl(config);
      expect(url.port, 8443);
      expect(url.path, '/m/');
      expect(url.queryParameters['pass'], 't');
    });

    test('pass 含特殊字符时正确百分号编码', () {
      const config = AppConfig(
        mode: ConnectionMode.public,
        serverUrl: 'https://relay.example.com',
        token: 'a&b=c?d#e f/',
      );
      final url = buildPairingUrl(config);
      // Uri.queryParameters 会自动解码回来,证明编码往返无损。
      expect(url.queryParameters['pass'], 'a&b=c?d#e f/');
      // 原始串中 & 必须被编码,否则会被解析成两个参数。
      expect(url.query, contains('%26'));
      expect(url.queryParameters.length, 1);
    });

    test('完整 URL 形态', () {
      const config = AppConfig(
        mode: ConnectionMode.public,
        serverUrl: 'https://relay.example.com',
        token: 'abc123',
      );
      expect(
        buildPairingUrl(config).toString(),
        'https://relay.example.com/m/?pass=abc123',
      );
    });
  });

  group('buildMobileUrl · cookie 优先冷启动', () {
    test('公网与局域网都只落到无凭据的 /m/', () {
      const publicConfig = AppConfig(
        mode: ConnectionMode.public,
        serverUrl: 'https://relay.example.com/',
        token: 'phone-pass',
      );
      final publicUrl = buildMobileUrl(publicConfig);
      expect(publicUrl.toString(), 'https://relay.example.com/m/');
      expect(publicUrl.hasQuery, isFalse);

      const lanConfig = AppConfig(
        mode: ConnectionMode.lan,
        serverUrl: 'http://192.168.1.5:3080',
        token: 'pair-token',
      );
      final lanUrl = buildMobileUrl(lanConfig);
      expect(lanUrl.toString(), 'http://192.168.1.5:3080/m/');
      expect(lanUrl.hasQuery, isFalse);
    });
  });

  group('buildPairingUrl · lan(局域网直连)', () {
    test('http 局域网 → /pair?token=<token>&next=/m/', () {
      const config = AppConfig(
        mode: ConnectionMode.lan,
        serverUrl: 'http://192.168.1.5:3080',
        token: 'abc123',
      );
      final url = buildPairingUrl(config);
      expect(url.scheme, 'http');
      expect(url.host, '192.168.1.5');
      expect(url.port, 3080);
      expect(url.path, '/pair');
      expect(url.queryParameters['token'], 'abc123');
      // 配对后落在移动壳 /m/(不再落桌面页)。
      expect(url.queryParameters['next'], '/m/');
    });

    test('https 局域网(默认端口 443)', () {
      const config = AppConfig(
        mode: ConnectionMode.lan,
        serverUrl: 'https://relay.example.com',
        token: 'xyz',
      );
      final url = buildPairingUrl(config);
      expect(url.scheme, 'https');
      expect(url.port, 443);
      expect(url.path, '/pair');
      expect(url.queryParameters['token'], 'xyz');
      expect(url.queryParameters['next'], '/m/');
    });

    test('next=/m/ 被正确百分号编码', () {
      const config = AppConfig(
        mode: ConnectionMode.lan,
        serverUrl: 'http://192.168.1.5:3080',
        token: 't',
      );
      final url = buildPairingUrl(config);
      expect(url.query, contains('next=%2Fm%2F'));
    });

    test('token 含特殊字符时正确百分号编码', () {
      const config = AppConfig(
        mode: ConnectionMode.lan,
        serverUrl: 'http://192.168.1.5:3080',
        token: 'a&b=c?d#e f/',
      );
      final url = buildPairingUrl(config);
      expect(url.queryParameters['token'], 'a&b=c?d#e f/');
      expect(url.query, contains('%26'));
      expect(url.queryParameters.length, 2); // token + next
    });

    test('服务器地址尾斜杠被去除', () {
      const config = AppConfig(
        mode: ConnectionMode.lan,
        serverUrl: 'http://192.168.1.5:3080///',
        token: 't',
      );
      expect(
        buildPairingUrl(config).toString(),
        'http://192.168.1.5:3080/pair?token=t&next=%2Fm%2F',
      );
    });
  });
}
