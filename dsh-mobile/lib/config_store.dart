import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 连接模式:公网服务器(默认,推荐)与局域网直连(次要)。
///
/// - [ConnectionMode.public]:服务器地址 `https://<域名>` + 手机口令
///   (phone-pass),经云端中继接入;
/// - [ConnectionMode.lan]:服务器地址 `http(s)://<ip>:<port>` + 配对令牌,
///   直连局域网内 DSH 服务器。
enum ConnectionMode { public, lan }

/// 应用配置:连接模式 + 服务器地址 + 访问凭据(公网=手机口令,局域网=配对令牌)。
///
/// 安全要求(见 DESIGN.md §6 R):
/// - 凭据用 flutter_secure_storage(Android Keystore)加密存储,绝不明文落盘;
/// - 凭据绝不出现在日志/崩溃报告中;
/// - 公网模式仅允许 https://;局域网模式允许 http:// 与 https://。
class AppConfig {
  const AppConfig({
    this.mode = ConnectionMode.public,
    required this.serverUrl,
    required this.token,
  });

  final ConnectionMode mode;

  /// 服务器地址(含 scheme,可带端口)。
  final String serverUrl;

  /// 访问凭据:公网模式为手机口令(phone-pass),局域网模式为配对令牌。
  final String token;

  bool get isComplete => serverUrl.isNotEmpty && token.isNotEmpty;

  /// 去掉尾部斜杠后的服务器地址,用于拼接配对 URL。
  String get baseUrl => serverUrl.replaceAll(RegExp(r'/+$'), '');

  /// 用于展示的 origin(不含路径、查询与凭据),可在加载页/错误页/设置页
  /// 安全展示;解析失败时回退为原地址。
  String get displayOrigin {
    final uri = Uri.tryParse(baseUrl);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return serverUrl;
    }
    return uri.origin;
  }

  /// 模式的中文展示名。
  String get modeLabel => switch (mode) {
    ConnectionMode.public => '公网服务器',
    ConnectionMode.lan => '局域网直连',
  };
}

/// 两个 URL 是否同源(scheme/host/port 一致)。
///
/// 解析失败或任一为空时返回 false;path/query 不参与比较。
bool isSameOriginUrl(String? a, String? b) {
  final ua = Uri.tryParse((a ?? '').trim());
  final ub = Uri.tryParse((b ?? '').trim());
  if (ua == null || ub == null) {
    return false;
  }
  return ua.scheme == ub.scheme && ua.host == ub.host && ua.port == ub.port;
}

/// 按连接模式校验服务器地址,返回错误文案;合法时返回 null。
///
/// - public:仅接受 https://(公网域名,手机口令须经 TLS 传输);
/// - lan:接受 http://(局域网直连)与 https:// 两种 scheme;
/// - 拒绝 userinfo、query、fragment、非根 path 与异常端口,避免配置歧义。
String? validateModeServerUrl(ConnectionMode mode, String? raw) {
  final value = raw?.trim() ?? '';
  if (value.isEmpty) {
    return '请输入服务器地址';
  }
  final uri = Uri.tryParse(value);
  final malformed =
      uri == null ||
      !uri.hasScheme ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.path.isNotEmpty && uri.path != '/') ||
      (uri.hasPort && (uri.port < 1 || uri.port > 65535));
  if (malformed) {
    return switch (mode) {
      ConnectionMode.public => '地址格式不正确,示例:https://relay.example.com',
      ConnectionMode.lan =>
        '地址格式不正确,示例:http://192.168.1.5:3080 或 https://relay.example.com',
    };
  }
  if (mode == ConnectionMode.public) {
    if (uri.scheme != 'https') {
      return '公网模式仅支持 https:// 地址';
    }
  } else if (uri.scheme != 'http' && uri.scheme != 'https') {
    return '仅支持 http:// 或 https:// 地址';
  }
  return null;
}

/// 配置持久化:
/// - 连接模式与服务器地址:shared_preferences(非敏感);
/// - 访问凭据:flutter_secure_storage(Keystore 加密)。
///
/// 注意:flutter_secure_storage v10 起 `encryptedSharedPreferences` 已被
/// Jetpack Security 上游废弃(v11 移除),数据会自动迁移到 Keystore 自定义
/// cipher(AES-GCM + RSA 包装);保留该参数以显式声明加密存储意图。
class ConfigStore {
  static const _kServerUrl = 'server_url';
  static const _kToken = 'pair_token';
  static const _kMode = 'connection_mode';

  static const _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  /// 读取已保存的配置;未配置、配置不完整或已失效时返回 null(回设置页)。
  ///
  /// 兼容旧版本:未保存过连接模式时按公网模式(默认推荐)处理;但加载时仍会
  /// 按模式重新校验 URL,旧版 `http://` 配置不会被当作公网配置放行。
  Future<AppConfig?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final serverUrl = prefs.getString(_kServerUrl) ?? '';
    final token = await _secure.read(key: _kToken) ?? '';
    if (serverUrl.isEmpty || token.isEmpty) {
      return null;
    }
    final mode = _modeFromName(prefs.getString(_kMode));
    if (validateModeServerUrl(mode, serverUrl) != null) {
      return null;
    }
    final config = AppConfig(mode: mode, serverUrl: serverUrl, token: token);
    try {
      Uri.parse(config.baseUrl);
    } on FormatException {
      return null;
    }
    return config;
  }

  Future<void> save(AppConfig config) async {
    // 存储层同样守住「模式 ↔ URL」约束,避免绕过 UI 把凭据写入错误模式。
    final urlError = validateModeServerUrl(config.mode, config.serverUrl);
    if (urlError != null) {
      throw ArgumentError(urlError);
    }
    if (config.token.trim().isEmpty) {
      throw ArgumentError('token is empty');
    }
    final prefs = await SharedPreferences.getInstance();
    // 保存旧值,任一步写入失败时尽量回滚,避免「新服务器/新模式 + 旧 token」
    // 这类半更新状态把凭据发往错误端点。
    final oldServerUrl = prefs.getString(_kServerUrl);
    final oldMode = prefs.getString(_kMode);
    final oldToken = await _secure.read(key: _kToken);
    try {
      await prefs.setString(_kServerUrl, config.serverUrl.trim());
      await prefs.setString(_kMode, config.mode.name);
      await _secure.write(key: _kToken, value: config.token.trim());
    } catch (_) {
      await _restore(prefs, oldServerUrl, oldMode, oldToken);
      rethrow;
    }
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    // 先删敏感凭据:即使后续 prefs 删除失败,load() 也会因 token 为空返回 null,
    // 不会残留可用会话。
    await _secure.delete(key: _kToken);
    await prefs.remove(_kServerUrl);
    await prefs.remove(_kMode);
  }

  Future<void> _restore(
    SharedPreferences prefs,
    String? serverUrl,
    String? mode,
    String? token,
  ) async {
    try {
      if (serverUrl == null) {
        await prefs.remove(_kServerUrl);
      } else {
        await prefs.setString(_kServerUrl, serverUrl);
      }
      if (mode == null) {
        await prefs.remove(_kMode);
      } else {
        await prefs.setString(_kMode, mode);
      }
      if (token == null) {
        await _secure.delete(key: _kToken);
      } else {
        await _secure.write(key: _kToken, value: token);
      }
    } catch (_) {
      // 回滚失败时保留首次异常;load() 的校验会兜底。
    }
  }

  ConnectionMode _modeFromName(String? name) {
    for (final mode in ConnectionMode.values) {
      if (mode.name == name) {
        return mode;
      }
    }
    return ConnectionMode.public;
  }
}
