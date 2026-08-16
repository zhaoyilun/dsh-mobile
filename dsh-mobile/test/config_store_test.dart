import 'package:dsh_mobile/config_store.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('validateModeServerUrl · public(公网服务器)', () {
    test('仅接受 https://', () {
      expect(
        validateModeServerUrl(
          ConnectionMode.public,
          'https://relay.example.com',
        ),
        isNull,
      );
      expect(
        validateModeServerUrl(
          ConnectionMode.public,
          ' https://relay.example.com:8443/ ',
        ),
        isNull,
      );
    });

    test('拒绝 http://(公网模式必须 TLS)', () {
      expect(
        validateModeServerUrl(
          ConnectionMode.public,
          'http://relay.example.com',
        ),
        isNotNull,
      );
      expect(
        validateModeServerUrl(ConnectionMode.public, 'http://192.168.1.5:3080'),
        isNotNull,
      );
    });
  });

  group('validateModeServerUrl · lan(局域网直连)', () {
    test('接受 http/https', () {
      expect(
        validateModeServerUrl(ConnectionMode.lan, 'http://192.168.1.5:3080'),
        isNull,
      );
      expect(
        validateModeServerUrl(ConnectionMode.lan, 'http://192.168.1.5'),
        isNull,
      );
      expect(
        validateModeServerUrl(ConnectionMode.lan, 'https://relay.example.com'),
        isNull,
      );
    });

    test('拒绝非 http/https', () {
      expect(
        validateModeServerUrl(ConnectionMode.lan, 'ftp://example.com'),
        isNotNull,
      );
      expect(
        validateModeServerUrl(ConnectionMode.lan, 'ws://example.com'),
        isNotNull,
      );
    });
  });

  group('validateModeServerUrl · 公共规则', () {
    test('两种模式都拒绝空/缺 scheme/缺 host', () {
      for (final mode in ConnectionMode.values) {
        expect(validateModeServerUrl(mode, ''), isNotNull);
        expect(validateModeServerUrl(mode, '   '), isNotNull);
        expect(validateModeServerUrl(mode, 'not a url'), isNotNull);
        expect(
          validateModeServerUrl(mode, 'example.com'),
          isNotNull,
        ); // 缺 scheme
        expect(validateModeServerUrl(mode, 'https://'), isNotNull); // 缺 host
      }
    });

    test('两种模式都拒绝 userinfo/query/fragment/非根 path/异常端口', () {
      for (final mode in ConnectionMode.values) {
        expect(
          validateModeServerUrl(mode, 'https://user:pass@relay.example.com'),
          isNotNull,
        );
        expect(
          validateModeServerUrl(mode, 'https://relay.example.com?x=1'),
          isNotNull,
        );
        expect(
          validateModeServerUrl(mode, 'https://relay.example.com#frag'),
          isNotNull,
        );
        expect(
          validateModeServerUrl(mode, 'https://relay.example.com/base'),
          isNotNull,
        );
        expect(
          validateModeServerUrl(mode, 'https://relay.example.com:99999'),
          isNotNull,
        );
      }
    });
  });

  group('isSameOriginUrl', () {
    test('scheme/host/port 一致即同源,path 不参与', () {
      expect(
        isSameOriginUrl(
          'https://relay.example.com',
          'https://relay.example.com/m/',
        ),
        isTrue,
      );
      expect(
        isSameOriginUrl(
          'https://relay.example.com',
          'https://relay.example.com:443',
        ),
        isTrue,
      );
      expect(
        isSameOriginUrl(
          'https://relay.example.com',
          'https://relay.example.com:8443',
        ),
        isFalse,
      );
      expect(
        isSameOriginUrl(
          'https://relay.example.com',
          'http://relay.example.com',
        ),
        isFalse,
      );
      expect(
        isSameOriginUrl('https://relay.example.com', 'not a url'),
        isFalse,
      );
    });
  });

  group('AppConfig', () {
    test('默认模式为公网(推荐)', () {
      const config = AppConfig(serverUrl: 'https://a.com', token: 't');
      expect(config.mode, ConnectionMode.public);
    });

    test('isComplete 需要地址与凭据都非空', () {
      expect(
        const AppConfig(serverUrl: 'https://a.com', token: 't').isComplete,
        isTrue,
      );
      expect(
        const AppConfig(serverUrl: 'https://a.com', token: '').isComplete,
        isFalse,
      );
      expect(const AppConfig(serverUrl: '', token: 't').isComplete, isFalse);
    });

    test('baseUrl 去掉尾部斜杠', () {
      const config = AppConfig(
        mode: ConnectionMode.lan,
        serverUrl: 'http://192.168.1.5:3080/',
        token: 't',
      );
      expect(config.baseUrl, 'http://192.168.1.5:3080');
    });

    test('displayOrigin 只暴露 origin,不暴露路径/查询/凭据', () {
      const publicConfig = AppConfig(
        mode: ConnectionMode.public,
        serverUrl: 'https://relay.example.com:8443/',
        token: 'secret',
      );
      expect(publicConfig.displayOrigin, 'https://relay.example.com:8443');

      const lanConfig = AppConfig(
        mode: ConnectionMode.lan,
        serverUrl: 'http://192.168.1.5:3080',
        token: 'secret',
      );
      expect(lanConfig.displayOrigin, 'http://192.168.1.5:3080');
      expect(lanConfig.displayOrigin.contains('secret'), isFalse);
    });

    test('modeLabel 返回模式中文名', () {
      const publicConfig = AppConfig(serverUrl: 'https://a.com', token: 't');
      const lanConfig = AppConfig(
        mode: ConnectionMode.lan,
        serverUrl: 'http://a.com',
        token: 't',
      );
      expect(publicConfig.modeLabel, '公网服务器');
      expect(lanConfig.modeLabel, '局域网直连');
    });
  });

  group('ConfigStore', () {
    test('保存后能读回;凭据走 secure storage,模式/地址走 shared_preferences', () async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});

      const config = AppConfig(
        mode: ConnectionMode.lan,
        serverUrl: 'http://192.168.1.5:3080',
        token: 'super-secret-token',
      );
      final store = ConfigStore();
      await store.save(config);

      final loaded = await store.load();
      expect(loaded, isNotNull);
      expect(loaded!.mode, ConnectionMode.lan);
      expect(loaded.serverUrl, 'http://192.168.1.5:3080');
      expect(loaded.token, 'super-secret-token');

      // 凭据不在 shared_preferences 里(Keystore 加密存储)。
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('pair_token'), isNull);
      // 模式存在 shared_preferences 中。
      expect(prefs.getString('connection_mode'), 'lan');
    });

    test('公网模式配置完整保存/读回', () async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});

      const config = AppConfig(
        mode: ConnectionMode.public,
        serverUrl: 'https://relay.example.com',
        token: 'phone-pass',
      );
      final store = ConfigStore();
      await store.save(config);

      final loaded = await store.load();
      expect(loaded, isNotNull);
      expect(loaded!.mode, ConnectionMode.public);
      expect(loaded.token, 'phone-pass');
    });

    test('旧版本配置(无模式字段 + https)加载时按公网模式处理', () async {
      SharedPreferences.setMockInitialValues({
        'server_url': 'https://relay.example.com',
      });
      FlutterSecureStorage.setMockInitialValues({'pair_token': 'legacy-token'});

      final loaded = await ConfigStore().load();
      expect(loaded, isNotNull);
      expect(loaded!.mode, ConnectionMode.public);
      expect(loaded.serverUrl, 'https://relay.example.com');
      expect(loaded.token, 'legacy-token');
    });

    test('旧版本 http 配置不再被当作公网模式放行(回设置页重配)', () async {
      SharedPreferences.setMockInitialValues({
        'server_url': 'http://192.168.1.5:3080',
      });
      FlutterSecureStorage.setMockInitialValues({'pair_token': 'legacy-token'});

      expect(await ConfigStore().load(), isNull);
    });

    test('已保存的非法/损坏地址加载时返回 null,不崩溃', () async {
      for (final serverUrl in ['not a url', 'https://', 'https://host:99999']) {
        SharedPreferences.setMockInitialValues({
          'server_url': serverUrl,
          'connection_mode': 'public',
        });
        FlutterSecureStorage.setMockInitialValues({'pair_token': 'token'});
        expect(await ConfigStore().load(), isNull, reason: serverUrl);
      }
    });

    test('未配置时返回 null(首次启动)', () async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      expect(await ConfigStore().load(), isNull);
    });

    test('clear 后再次 load 返回 null', () async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});

      const config = AppConfig(
        mode: ConnectionMode.public,
        serverUrl: 'https://relay.example.com',
        token: 't',
      );
      final store = ConfigStore();
      await store.save(config);
      await store.clear();
      expect(await store.load(), isNull);
    });
  });
}
