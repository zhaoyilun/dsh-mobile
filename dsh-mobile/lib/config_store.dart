import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 连接模式:公网服务器(默认,推荐)与局域网直连(次要)。
enum ConnectionMode { public, lan }

/// 应用配置:连接模式 + 服务器地址 + 访问凭据(公网=手机口令,局域网=配对令牌)。
///
/// 多设备支持:
/// - [id] 是设备档案的唯一 ID,由 ConfigStore 分配;为空表示尚未落库(首次保存时分配);
/// - [name] 是展示名,便于在手机上一眼认出 Mac mini / Windows / Linux 等设备;
/// - 凭据仍走 flutter_secure_storage,绝不进入 shared_preferences 明文。
class AppConfig {
  const AppConfig({
    this.mode = ConnectionMode.public,
    required this.serverUrl,
    required this.token,
    this.id,
    this.name,
  });

  final ConnectionMode mode;
  final String serverUrl;
  final String token;
  final String? id;
  final String? name;

  bool get isComplete => serverUrl.isNotEmpty && token.isNotEmpty;

  String get baseUrl => serverUrl.replaceAll(RegExp(r'/+$'), '');

  String get displayOrigin {
    final uri = Uri.tryParse(baseUrl);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return serverUrl;
    }
    return uri.origin;
  }

  String get modeLabel => switch (mode) {
    ConnectionMode.public => '公网服务器',
    ConnectionMode.lan => '局域网直连',
  };

  /// 默认设备名:优先使用用户命名,否则用服务器主机名。
  String get displayName {
    final explicit = name?.trim();
    if (explicit != null && explicit.isNotEmpty) return explicit;
    final uri = Uri.tryParse(baseUrl);
    if (uri != null && uri.host.isNotEmpty) return uri.host;
    return '未命名设备';
  }

  AppConfig copyWith({
    ConnectionMode? mode,
    String? serverUrl,
    String? token,
    String? id,
    String? name,
  }) {
    return AppConfig(
      mode: mode ?? this.mode,
      serverUrl: serverUrl ?? this.serverUrl,
      token: token ?? this.token,
      id: id ?? this.id,
      name: name ?? this.name,
    );
  }
}

/// 两个 URL 是否同源(scheme/host/port 一致)。
bool isSameOriginUrl(String? a, String? b) {
  final ua = Uri.tryParse((a ?? '').trim());
  final ub = Uri.tryParse((b ?? '').trim());
  if (ua == null || ub == null) {
    return false;
  }
  return ua.scheme == ub.scheme && ua.host == ub.host && ua.port == ub.port;
}

/// 按连接模式校验服务器地址,返回错误文案;合法时返回 null。
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
/// - 设备档案列表(模式/地址/名称)存 shared_preferences(非敏感,JSON);
/// - 每个设备的访问凭据独立存 flutter_secure_storage(Keystore 加密);
/// - 兼容旧版单设备字段,首次读取时自动迁移成一条「默认设备」档案。
class ConfigStore {
  static const _kProfiles = 'device_profiles';
  static const _kActiveProfile = 'active_device_id';
  static const _kTokenPrefix = 'profile_token_';

  // 旧版单设备字段,仅用于兼容迁移。
  static const _kServerUrl = 'server_url';
  static const _kToken = 'pair_token';
  static const _kMode = 'connection_mode';

  static const _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  String _tokenKey(String id) => '$_kTokenPrefix$id';

  String _newId() => DateTime.now().microsecondsSinceEpoch.toString();

  /// 读取已保存的配置;未配置、配置不完整或已失效时返回 null(回设置页)。
  Future<AppConfig?> load() async {
    final activeId = await _activeId();
    if (activeId != null) {
      final config = await _loadProfile(activeId);
      if (config != null) return config;
    }
    return _loadLegacy();
  }

  /// 读取全部设备档案(含各自凭据;损坏/缺 token 的档案会跳过)。
  Future<List<AppConfig>> loadProfiles() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kProfiles);
    final list = <AppConfig>[];
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is! Map<String, dynamic>) continue;
            final id = item['id'];
            final serverUrl = item['serverUrl'];
            final modeName = item['mode'];
            final name = item['name'];
            if (id is! String || serverUrl is! String || modeName is! String) {
              continue;
            }
            final mode = _modeFromName(modeName);
            final token = await _secure.read(key: _tokenKey(id));
            if (token == null || token.isEmpty) continue;
            if (validateModeServerUrl(mode, serverUrl) != null) continue;
            list.add(AppConfig(
              mode: mode,
              serverUrl: serverUrl,
              token: token,
              id: id,
              name: name is String ? name : null,
            ));
          }
        }
      } catch (_) {
        // 解析失败按空列表处理;旧版迁移路径会兜底。
      }
    }
    if (list.isNotEmpty) return list;

    // 旧版单设备迁移:分配新 id,写回 profile 列表,返回已迁移的档案。
    final legacy = await _loadLegacy();
    if (legacy == null) return [];
    final migrated = legacy.copyWith(id: _newId());
    await _saveProfile(migrated, makeActive: true);
    return [migrated];
  }

  /// 当前激活的设备 ID。
  Future<String?> activeProfileId() => _activeId();

  /// 保存配置。若 [config] 带 id 则更新该档案,否则更新当前激活档案
  /// (没有激活档案时新建一条)并设为激活。
  Future<void> save(AppConfig config) async {
    // 显式带 id 表示编辑已有设备;不带 id 表示新增一台设备。
    final id = config.id ?? _newId();
    final mode = config.mode;
    if (validateModeServerUrl(mode, config.serverUrl) != null) {
      throw ArgumentError('invalid server url');
    }
    if (config.token.trim().isEmpty) {
      throw ArgumentError('token is empty');
    }
    await _saveProfile(config.copyWith(id: id), makeActive: true);
  }

  /// 删除一个设备档案;若删除的是当前激活档案,自动切到剩余档案的第一条。
  Future<void> deleteProfile(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final list = await _readProfileMetadata();
    final next = list.where((item) => item['id'] != id).toList();
    await prefs.setString(_kProfiles, jsonEncode(next));
    await _secure.delete(key: _tokenKey(id));

    final activeId = await _activeId();
    if (activeId == id) {
      if (next.isNotEmpty) {
        final nextId = next.first['id'] as String;
        await switchProfile(nextId);
      } else {
        await prefs.remove(_kActiveProfile);
        await _clearLegacy();
      }
    } else {
      // 非激活档案被删,保持当前激活状态;同步旧版镜像以免 stale。
      await _mirrorLegacyIfActive(await _activeId());
    }
  }

  /// 切换激活设备,并同步旧版单设备镜像字段。
  Future<void> switchProfile(String id) async {
    final profile = await _loadProfile(id);
    if (profile == null) {
      throw ArgumentError('profile not found or incomplete: $id');
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kActiveProfile, id);
    await _mirrorLegacy(profile);
  }

  /// 清空所有设备档案与凭据。
  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    final list = await _readProfileMetadata();
    for (final item in list) {
      final id = item['id'];
      if (id is String) {
        await _secure.delete(key: _tokenKey(id));
      }
    }
    await prefs.remove(_kProfiles);
    await prefs.remove(_kActiveProfile);
    await _clearLegacy();
  }

  Future<void> _saveProfile(AppConfig config, {required bool makeActive}) async {
    final prefs = await SharedPreferences.getInstance();
    final id = config.id ?? _newId();
    final list = await _readProfileMetadata();
    final entry = {
      'id': id,
      'name': config.name ?? '',
      'mode': config.mode.name,
      'serverUrl': config.serverUrl.trim(),
    };
    final index = list.indexWhere((item) => item['id'] == id);
    if (index >= 0) {
      list[index] = entry;
    } else {
      list.add(entry);
    }
    await prefs.setString(_kProfiles, jsonEncode(list));
    await _secure.write(key: _tokenKey(id), value: config.token.trim());
    if (makeActive) {
      await prefs.setString(_kActiveProfile, id);
      await _mirrorLegacy(config.copyWith(id: id));
    }
  }

  Future<AppConfig?> _loadProfile(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kProfiles);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return null;
      for (final item in decoded) {
        if (item is! Map<String, dynamic>) continue;
        if (item['id'] != id) continue;
        final serverUrl = item['serverUrl'];
        final modeName = item['mode'];
        final name = item['name'];
        if (serverUrl is! String || modeName is! String) continue;
        final mode = _modeFromName(modeName);
        final token = await _secure.read(key: _tokenKey(id));
        if (token == null || token.isEmpty) return null;
        if (validateModeServerUrl(mode, serverUrl) != null) return null;
        return AppConfig(
          mode: mode,
          serverUrl: serverUrl,
          token: token,
          id: id,
          name: name is String ? name : null,
        );
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  Future<String?> _activeId() async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(_kActiveProfile);
    if (id == null || id.isEmpty) return null;
    return id;
  }

  Future<List<Map<String, dynamic>>> _readProfileMetadata() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kProfiles);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded.whereType<Map<String, dynamic>>().toList();
    } catch (_) {
      return [];
    }
  }

  Future<AppConfig?> _loadLegacy() async {
    final prefs = await SharedPreferences.getInstance();
    final serverUrl = prefs.getString(_kServerUrl) ?? '';
    final token = await _secure.read(key: _kToken) ?? '';
    if (serverUrl.isEmpty || token.isEmpty) return null;
    final mode = _modeFromName(prefs.getString(_kMode));
    if (validateModeServerUrl(mode, serverUrl) != null) return null;
    return AppConfig(
      mode: mode,
      serverUrl: serverUrl,
      token: token,
      id: null,
      name: null,
    );
  }

  Future<void> _mirrorLegacy(AppConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kServerUrl, config.serverUrl.trim());
    await prefs.setString(_kMode, config.mode.name);
    await _secure.write(key: _kToken, value: config.token.trim());
  }

  Future<void> _mirrorLegacyIfActive(String? activeId) async {
    if (activeId == null) return;
    final active = await _loadProfile(activeId);
    if (active != null) {
      await _mirrorLegacy(active);
    }
  }

  Future<void> _clearLegacy() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kServerUrl);
    await prefs.remove(_kMode);
    await _secure.delete(key: _kToken);
  }

  ConnectionMode _modeFromName(String? name) {
    for (final mode in ConnectionMode.values) {
      if (mode.name == name) return mode;
    }
    return ConnectionMode.public;
  }
}
