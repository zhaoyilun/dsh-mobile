// dsh-federation — host API 访问层：签名 cookie 方案（PAIRING-SPEC §4/§5）
// 原理：凭证由配对的 dsh 经 registry 按边下发（access.credential，tokenUrl 或 token=value）；
// App 用凭证 GET（禁重定向）换取签名 cookie（Set-Cookie），此后所有 API/SSE 请求带同源 Cookie。
// 会话按 dshId 维度持久化（支持多 dsh）；lanUrl 优先（3s 超时切 publicUrl）。
// Web 差异：浏览器禁止 JS 读写 Cookie 头——交换响应里的 Set-Cookie 读不到、
// 手动携带 cookie 头会被静默丢弃。Web 走「浏览器托管」路径（同源部署时
// withCredentials 让浏览器在交换时存 cookie、后续自动携带），cookie 字段用占位值。
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'http_client_factory.dart' if (dart.library.html) 'http_client_factory_web.dart';
import 'kv_store.dart';
import 'pairings.dart';

/// 一个 dsh 的已认证 host 会话（cookie + 基址）。
class HostSession {
  HostSession({
    required this.dshId,
    required this.baseUrl,
    required this.cookieName,
    required this.cookieValue,
    this.relayPass,
  });

  /// 会话归属的 dsh 设备 id（持久化 key 的一部分，支持多 dsh 各自持有会话）。
  final String dshId;
  final String baseUrl;
  final String cookieName;
  final String cookieValue;

  /// 公网入口的中继口令（dsh-cloud-relay 的 X-DC-Pass）；lan 直连时为 null（无需）。
  final String? relayPass;

  static const _kBasePrefix = 'host.session.baseUrl.';
  static const _kNamePrefix = 'host.session.cookieName.';
  static const _kValuePrefix = 'host.session.cookieValue.';
  static const _kRelayPrefix = 'host.session.relayPass.';

  Map<String, String> get headers => {
        if (cookieName.isNotEmpty) 'cookie': '$cookieName=$cookieValue',
        // 中继口令：只要存在就带（同源反代部署时 base 是 http 但上游仍是 https，
        // 按 scheme 判断会漏发；lan 直连场景本就无 relayPass）。
        if (relayPass != null && relayPass!.isNotEmpty) 'x-dc-pass': relayPass!,
      };

  Future<void> save() async {
    final st = KvStore();
    await st.write(key: '$_kBasePrefix$dshId', value: baseUrl);
    await st.write(key: '$_kNamePrefix$dshId', value: cookieName);
    await st.write(key: '$_kValuePrefix$dshId', value: cookieValue);
    if (relayPass != null && relayPass!.isNotEmpty) {
      await st.write(key: '$_kRelayPrefix$dshId', value: relayPass!);
    } else {
      await st.delete(key: '$_kRelayPrefix$dshId');
    }
  }

  static Future<HostSession?> load(String dshId) async {
    final st = KvStore();
    final base = await st.read(key: '$_kBasePrefix$dshId');
    final name = await st.read(key: '$_kNamePrefix$dshId');
    final value = await st.read(key: '$_kValuePrefix$dshId');
    if (base == null || name == null || value == null) return null;
    final relay = await st.read(key: '$_kRelayPrefix$dshId');
    return HostSession(
      dshId: dshId,
      baseUrl: base,
      cookieName: name,
      cookieValue: value,
      relayPass: (relay != null && relay.isNotEmpty) ? relay : null,
    );
  }

  static Future<void> clear(String dshId) async {
    final st = KvStore();
    for (final prefix in [_kBasePrefix, _kNamePrefix, _kValuePrefix, _kRelayPrefix]) {
      await st.delete(key: '$prefix$dshId');
    }
  }

  /// 凭配对凭证建会话（PAIRING-SPEC §5：lan 优先、超时 3s 切 public）。
  /// [credential] 兼容两种形态：完整 tokenUrl（https://dsh.example.com/?token=xxx）或 `token=value`。
  /// lan 尝试时把 tokenUrl 的 authority 重写为 lan 地址（保留 token 查询参数），
  /// 保证「交换凭证的 authority」与「后续带 cookie 请求的 authority」一致。
  static Future<HostSession> fromAccess({
    required String dshId,
    String? lanUrl,
    required String publicUrl,
    required String credential,
  }) async {
    // 凭证两种形态：JSON（{tokenUrl, relayPass?} / {bridgeToken}，新 bridge 上传）或裸字符串（tokenUrl/token，兼容）
    String inner = credential.trim();
    String? relayPass;
    if (inner.startsWith('{')) {
      try {
        final j = jsonDecode(inner) as Map<String, dynamic>;
        final t = j['tokenUrl'];
        if (t is String && t.isNotEmpty) {
          inner = t;
          final rp = j['relayPass'];
          relayPass = (rp is String && rp.isNotEmpty) ? rp : null;
        }
      } catch (_) {
        throw StateError('凭证 JSON 解析失败');
      }
    }
    // 架构原则：访问必须经云端绕回（app → vps → 隧道 → dsh），不直接访问本地——
    // 路径唯一、安全边界唯一（lanUrl 字段仅作展示，不参与连接）。
    final candidates = <({String base, Duration timeout})>[
      (base: publicUrl, timeout: const Duration(seconds: 10)),
    ];
    Object? lastError;
    for (final c in candidates) {
      for (var attempt = 1; attempt <= 2; attempt++) {
        try {
          final session = await _exchange(
            dshId: dshId,
            tokenUrl: _tokenUrlFor(c.base, inner),
            baseUrl: c.base,
            timeout: c.timeout,
            // 中继口令只在公网入口需要（lan 直连不经过 relay）
            relayPass: c.base == publicUrl ? relayPass : null,
          );
          await session.save();
          return session;
        } catch (e) {
          lastError = e; // 瞬时失败（页面加载期与 MQTT 建连并发等）重试一次
          if (attempt == 1) await Future<void>.delayed(const Duration(milliseconds: 800));
        }
      }
    }
    throw StateError('host 凭证交换失败（lan/public 均不可达）: $lastError');
  }

  /// 把凭证解析为针对 [base] 的 tokenUrl：
  /// - 完整 URL：同源原样用；异源（lan 直连）重写 scheme/authority，保留路径与 token 参数；
  /// - `token=value` 形式：直接拼到基址查询串；
  /// - 裸 token 值：按 `?token=<value>` 拼。
  static String _tokenUrlFor(String base, String credential) {
    final trimmed = base.replaceAll(RegExp(r'/+$'), '');
    final c = credential.trim();
    if (c.startsWith('http://') || c.startsWith('https://')) {
      final u = Uri.parse(c);
      final b = Uri.parse(trimmed);
      if (u.authority == b.authority && u.scheme == b.scheme) return c;
      final query = u.query.isEmpty ? '' : '?${u.query}';
      final path = u.path.isEmpty ? '/' : u.path;
      return '${b.scheme}://${b.authority}$path$query';
    }
    if (c.startsWith('token=')) return '$trimmed/?$c';
    return '$trimmed/?token=${Uri.encodeQueryComponent(c)}';
  }

  /// GET tokenUrl（禁重定向）→ 303/302/200 的 Set-Cookie → 会话对象。
  /// [relayPass] 非空时携带 X-DC-Pass（公网入口经 dsh-cloud-relay 的必需口令）。
  static Future<HostSession> _exchange({
    required String dshId,
    required String tokenUrl,
    required String baseUrl,
    required Duration timeout,
    String? relayPass,
  }) async {
    final client = createHttpClient();
    try {
      final request = http.Request('GET', Uri.parse(tokenUrl));
      // IO：禁重定向以读取 303 的 Set-Cookie。
      // Web：必须跟随重定向——http 包把 followRedirects=false 映射为 fetch 的
      // redirect:'error'，遇到 303 直接抛 "Failed to fetch"（浏览器也读不到
      // Set-Cookie，真实 cookie 由浏览器在重定向链中自动托管）。
      if (!kIsWeb) request.followRedirects = false;
      if (relayPass != null && relayPass.isNotEmpty) {
        request.headers['x-dc-pass'] = relayPass;
      }
      // http.Client 无内置超时：用 .timeout 包裹（超时抛 TimeoutException，由上层切候选基址）
      final streamed = await client.send(request).timeout(timeout);
      final res = await http.Response.fromStream(streamed).timeout(timeout);
      if (res.statusCode != 303 && res.statusCode != 302 && res.statusCode != 200) {
        throw Exception('token exchange failed: http ${res.statusCode}');
      }
      // Web：浏览器禁止读取 Set-Cookie；交换响应（或其重定向链）里的真实
      // cookie 已由浏览器存下（withCredentials + 同源），后续请求自动携带。
      // 这里给占位值让会话能落盘，占位 cookie 头浏览器本来也会丢弃。
      if (kIsWeb) {
        return HostSession(
          dshId: dshId,
          baseUrl: baseUrl.replaceAll(RegExp(r'/+$'), ''),
          cookieName: 'browser',
          cookieValue: 'managed',
          relayPass: (relayPass != null && relayPass.isNotEmpty) ? relayPass : null,
        );
      }
      final setCookie = res.headers['set-cookie'];
      if (setCookie == null) {
        throw Exception('token exchange: no set-cookie header (token 可能已失效)');
      }
      // http 包把多条 Set-Cookie 合并成一个串（'a=1; Path=/, b=2; Path=/'）：
      // 中继（dsh_relay_pass）与 host（dsh-auth-*）各发一条，必须精确挑 host 的认证 cookie。
      final candidates = setCookie
          .split(RegExp(r',\s*(?=[\w-]+=)'))
          .map((c) => c.split(';').first.trim())
          .where((c) => c.startsWith('dsh-auth'))
          .toList();
      if (candidates.isEmpty) {
        throw Exception('token exchange: no dsh-auth cookie (got: ${setCookie.split(";").first})');
      }
      final first = candidates.first; // name=value
      final eq = first.indexOf('=');
      if (eq <= 0) throw Exception('malformed set-cookie');
      return HostSession(
        dshId: dshId,
        baseUrl: baseUrl.replaceAll(RegExp(r'/+$'), ''),
        cookieName: first.substring(0, eq),
        cookieValue: first.substring(eq + 1),
        relayPass: (relayPass != null && relayPass.isNotEmpty) ? relayPass : null,
      );
    } finally {
      client.close();
    }
  }
}

/// 面向页面层的 host RPC 入口：内存缓存 → 按 dshId 持久化会话 → 凭 access 重新交换。
class HostSessionService {
  HostSessionService({required this.dshId, this.access});

  final String dshId;

  /// 配对边下发的最新凭证（无缓存会话时用于交换；null 则要求先刷新 pairings）。
  final PairingAccess? access;
  HostSession? _session;

  Future<HostSession> ensure() async {
    final cached = _session;
    if (cached != null) return cached;
    final loaded = await HostSession.load(dshId);
    if (loaded != null) {
      _session = loaded;
      return loaded;
    }
    return _exchangeFresh();
  }

  Future<HostSession> _exchangeFresh() async {
    final a = access;
    if (a == null) {
      throw StateError('无 host 会话且无配对凭证 — 请先完成配对（或等待 pairings 刷新）');
    }
    final session = await HostSession.fromAccess(
      dshId: dshId,
      lanUrl: a.lanUrl,
      publicUrl: a.publicUrl,
      credential: a.credential,
    );
    _session = session;
    return session;
  }

  /// [timeout]：单次 HTTP 请求超时。文本消息默认 20s；大 payload（如 base64 图片）
  /// 由调用方放宽，弱网上传才不会中途被掐。
  Future<Map<String, dynamic>> rpc(String method, Map<String, dynamic> payload,
      {Duration timeout = const Duration(seconds: 20)}) async {
    var session = await ensure();
    var res = await _post(session, method, payload, timeout);
    if (res.statusCode == 401) {
      // cookie 失效：清缓存按最新凭证重换一次再重试（一次为限，避免循环）
      await HostSession.clear(dshId);
      _session = null;
      session = await _exchangeFresh();
      res = await _post(session, method, payload, timeout);
      if (res.statusCode == 401) throw StateError('host auth expired — 凭证已失效，等待 dsh 重新上线刷新');
    }
    if (res.statusCode == 404) {
      // 认证已通过但端点不存在：host 未开放会话接口（apiproxy 缺失），与凭证无关
      throw Exception('此 dsh 未开放会话接口（$method → 404）：host 侧 apiproxy 未装载，等待宿主恢复');
    }
    if (res.statusCode != 200) throw Exception('host api $method failed: http ${res.statusCode}');
    final body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (body['type'] != 'server-response') throw Exception('unexpected envelope');
    final result = body['result'] as Map<String, dynamic>?;
    if (result?['ok'] != true) {
      final err = result?['error'] as Map<String, dynamic>?;
      throw Exception('host api $method error: ${err?['code']} ${err?['message']}');
    }
    return (result?['value'] as Map<String, dynamic>? ?? {}).cast<String, dynamic>();
  }

  /// 应答 host 的交互请求（工具审批 / 提问）：POST /api/respond。
  /// [rpcId] 必须是触发帧（approval/question/requested）所附的 SSE 信封 id；
  /// [value] 为应答域载荷（approval: {sessionId,approvalId,outcome}；
  /// question: {sessionId,answer:{answers:[{id,selected,custom}]}}）；
  /// [cancel] 用于取消提问（error envelope code=cancelled）。
  Future<Map<String, dynamic>> respond(String rpcId,
      {Map<String, dynamic>? value, bool cancel = false}) async {
    var session = await ensure();
    var res = await _postRespond(session, rpcId, value: value, cancel: cancel);
    if (res.statusCode == 401) {
      // cookie 失效：清缓存重换后再试一次（与 rpc 同策略）
      await HostSession.clear(dshId);
      _session = null;
      session = await _exchangeFresh();
      res = await _postRespond(session, rpcId, value: value, cancel: cancel);
      if (res.statusCode == 401) throw StateError('host auth expired — 凭证已失效，等待 dsh 重新上线刷新');
    }
    if (res.statusCode != 200) throw Exception('host respond failed: http ${res.statusCode}');
    final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (j['accepted'] != true) {
      throw Exception('应答被拒绝: ${j['reason'] ?? 'unknown'}（审批可能已过期或被他人处理）');
    }
    return j;
  }

  Future<http.Response> _post(HostSession session, String method, Map<String, dynamic> payload, Duration timeout) {
    final client = createHttpClient();
    return client
        .post(
          Uri.parse('${session.baseUrl}/api/$method'),
          headers: {...session.headers, 'content-type': 'application/json'},
          body: jsonEncode({
            'type': 'client-request',
            'rpcId': 'fj_${DateTime.now().microsecondsSinceEpoch}',
            'method': method,
            'payload': payload,
          }),
        )
        .timeout(timeout)
        .whenComplete(client.close);
  }

  /// /api/respond 的 POST 腿：client-response 信封（type + rpcId + result）。
  Future<http.Response> _postRespond(HostSession session, String rpcId,
      {Map<String, dynamic>? value, bool cancel = false}) {
    final client = createHttpClient();
    final result = cancel
        ? {
            'ok': false,
            'error': {'code': 'cancelled', 'message': 'cancelled by user'},
          }
        : {'ok': true, 'value': value};
    return client
        .post(
          Uri.parse('${session.baseUrl}/api/respond'),
          headers: {...session.headers, 'content-type': 'application/json'},
          body: jsonEncode({'type': 'client-response', 'rpcId': rpcId, 'result': result}),
        )
        .timeout(const Duration(seconds: 15))
        .whenComplete(client.close);
  }
}
