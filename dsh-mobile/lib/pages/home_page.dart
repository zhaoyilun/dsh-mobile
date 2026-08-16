import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../config_store.dart';
import '../pairing_url.dart';
import '../reconnect_policy.dart';
import '../retry_schedule.dart';
import '../system_notifications.dart';
import '../theme.dart';
import '../widgets/dsh_brand_mark.dart';
import 'settings_page.dart';

/// WebView 连接状态,驱动 AppBar 状态指示。
enum _ConnStatus { loading, online, reconnecting, error }

/// 主页:WebView 加载配对 URL,此后同源 cookie 会话维持登录。
///
/// - 配对契约:公网加载 `<server>/m/?pass=<phone-pass>`,局域网加载
///   `<server>/pair?token=<token>&next=/m/`,服务端校验后设 HttpOnly cookie
///   并 302 到移动壳 `/m/`,WebView 自动携带 cookie(见 DESIGN.md §6);
/// - 导航策略:只放行与配置服务器同源的导航(含配对入口),外链/未知域
///   一律阻止,防止凭据被带到第三方站点;
/// - 自动重连:只有"主文档级"的失败才触发。触发后按 2s/4s/8s 最多自动
///   重试 3 次,优先软恢复(reload 当前页),重试耗尽 → 错误覆盖层;
///   同一故障的 `onWebResourceError` 与 `onHttpError` 会连发,内部按
///   「已有重试等待」去重,避免一次断网吃掉多次预算;
/// - 系统返回键:WebView 有历史记录先回 WebView,没有才退出 App,避免
///   按返回键直接从 App 里掉出来;
/// - 手动重试走完整配对 URL(冷启动路径)。
class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.config,
    required this.onConfigChanged,
    required this.onConfigCleared,
  });

  final AppConfig config;

  /// 设置页保存新配置后回调(根路由以新配置重建整个页面)。
  final ValueChanged<AppConfig> onConfigChanged;

  /// 设置页清除配置后回调(根路由回到首次配置页)。
  final VoidCallback onConfigCleared;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  late final WebViewController _controller;
  Timer? _retryTimer;

  _ConnStatus _status = _ConnStatus.loading;

  /// 本次故障已发起的自动重试次数(0..[maxRetryAttempts]),成功后清零。
  int _retryAttempt = 0;

  /// 非 null = 自动重试已耗尽,显示错误覆盖层。
  String? _errorMessage;

  /// 主文档当前 URL(软恢复 reload 的目标);由 onPageStarted 跟踪。
  String? _documentUrl;

  /// 首次 onPageFinished 之后才隐藏全屏加载页,避免 WebView 白屏/黑屏
  /// 直接暴露给用户。
  bool _hasLoadedOnce = false;

  DateTime? _lastBlockedNoticeAt;

  /// 切到后台的时刻;回前台时按停留时长决定是否刷新页面。
  DateTime? _pausedAt;

  /// cookie 失效后正在回退配对,避免 401 反复触发配对循环。
  bool _pairingFallback = false;

  /// 后台停留超过该时长后,回前台主动 reload,让会话/任务状态刷新。
  static const _backgroundRefreshThreshold = Duration(minutes: 1);

  bool get _inErrorOverlay => _errorMessage != null;

  /// 与配置服务器同源(scheme/host/port 一致)的导航才放行。
  bool _isSameOrigin(String url) => isSameOriginUrl(url, widget.config.baseUrl);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Android 前台保活服务:切后台后进程不会被轻易回收,WebSocket 与
    // WebView 通知桥可以继续工作。
    unawaited(SystemNotifications.startKeepAlive());
    _initController();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _retryTimer?.cancel();
    unawaited(SystemNotifications.stopKeepAlive());
    super.dispose();
  }

  void _initController() {
    // 冷启动优先直接进 /m/(会话凭据已在 HttpOnly cookie 里),收到
    // 401/403 再回退到配对 URL;已配对手机不需要每次打开都重新校验口令。
    final initialUrl = buildMobileUrl(widget.config);
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      // WebView 首帧前用原生壳底色,避免 Android 上先闪一帧刺眼白屏。
      ..setBackgroundColor(DshTokens.iceWhite)
      // 移动 Web 端设置页通过该通道打开原生设置;主页不再显示顶部 AppBar。
      ..addJavaScriptChannel(
        'DshShell',
        onMessageReceived: (message) {
          if (message.message == 'openSettings') {
            unawaited(_openSettings());
          }
        },
      )
      // 移动 Web 端通过该通道请求系统通知(审批/提问/任务完成)。
      ..addJavaScriptChannel(
        'DshNotify',
        onMessageReceived: (message) {
          unawaited(SystemNotifications.showFromWeb(message.message));
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            if (_isSameOrigin(request.url)) {
              return NavigationDecision.navigate;
            }
            // 外链/未知域:阻止,凭据绝不发给第三方。
            _notifyBlockedNavigation();
            return NavigationDecision.prevent;
          },
          onPageStarted: (url) {
            _documentUrl = url;
            // 错误覆盖层展示期间忽略页面事件,避免误清错误态。
            if (_inErrorOverlay || !mounted) {
              return;
            }
            setState(() => _status = _ConnStatus.loading);
          },
          onPageFinished: (url) {
            _pairingFallback = false;
            if (_inErrorOverlay || !mounted) {
              return;
            }
            // 重连等待期间的 finish 往往是失败页/错误页的 finish,不能据此
            // 清零重试预算或取消定时器;否则一次失败会被重复当作「第一次」。
            if (_status == _ConnStatus.reconnecting) {
              setState(() => _hasLoadedOnce = true);
              return;
            }
            _retryTimer?.cancel();
            setState(() {
              _hasLoadedOnce = true;
              _status = _ConnStatus.online;
              _retryAttempt = 0; // 加载成功,重试计数清零。
            });
          },
          onWebResourceError: (error) {
            // 只有主文档的网络级失败才是"断联";子资源失败(图标/预取等)
            // 不构成页面级故障。WebView 切后台再回前台时平台会补发历史
            // 错误,须以错误类型过滤,避免唤醒即误判断联。
            if (error.isForMainFrame == true && _isNetworkError(error)) {
              // 只展示错误码,不拼 description:平台错误串可能带请求 URL,
              // 首次配对 URL 里含 pass/token,不能把它显示在错误页上。
              _onLoadFailed('网络连接失败(${error.errorCode})');
            }
          },
          onHttpError: (error) {
            final status = error.response?.statusCode;
            final uri = error.request?.uri;
            final isDocument = uri == null
                ? _documentUrl != null
                : (_documentUrl != null && uri.toString() == _documentUrl);
            final sameOrigin = uri == null || _isSameOrigin(uri.toString());
            // 401/403 表示 cookie 缺失或失效:先回退配对一次;配对 URL
            // 本身再失败才判定为凭据错误。
            if (isDocument && sameOrigin && (status == 401 || status == 403)) {
              _onAuthRequired();
              return;
            }
            final serverLevel = status == null || status == 0 || status >= 500;
            if (isDocument && serverLevel && sameOrigin) {
              _onLoadFailed('服务器错误(HTTP ${status ?? 0})');
            }
          },
        ),
      )
      ..loadRequest(initialUrl);
  }

  /// 加载失败统一入口:还有剩余自动重试 → 排程重连;耗尽 → 错误页。
  ///
  /// 同一个主文档失败在 Android 上会先后触发 `onWebResourceError` 与
  /// `onHttpError`;只要已有一次失败在等待重试,后续重复事件直接忽略,
  /// 保证 2s/4s/8s 三次预算是三次真实故障,而不是三次回调。
  void _onLoadFailed(String message) {
    if (!mounted || _inErrorOverlay || _status == _ConnStatus.reconnecting) {
      return;
    }
    if (_retryAttempt < maxRetryAttempts) {
      _retryAttempt += 1;
      setState(() => _status = _ConnStatus.reconnecting);
      final delayMs = retryDelayMs(_retryAttempt);
      _retryTimer?.cancel();
      _retryTimer = Timer(Duration(milliseconds: delayMs!), _softRecover);
    } else {
      setState(() {
        _status = _ConnStatus.error;
        _errorMessage = message;
      });
    }
  }

  /// 当前主文档 URL 是否携带配对凭据(pass/token)。配对 URL 自己返回
  /// 401/403 时不再尝试回退,直接判定为凭据错误。
  bool _urlHasCredential(String? url) {
    final uri = Uri.tryParse(url ?? '');
    if (uri == null) {
      return false;
    }
    return uri.queryParameters.containsKey('pass') ||
        uri.queryParameters.containsKey('token');
  }

  /// cookie 缺失/失效(401/403)时的回退:
  /// 1. 普通 /m/ 页面 → 用配对 URL 重新拿一次会话;
  /// 2. 配对 URL 本身 → 手机口令/配对令牌错误,展示错误页。
  void _onAuthRequired() {
    if (!mounted || _inErrorOverlay) {
      return;
    }
    if (_pairingFallback) {
      return;
    }
    final doc = _documentUrl;
    if (_urlHasCredential(doc)) {
      setState(() {
        _status = _ConnStatus.error;
        _errorMessage = '配对失败:手机口令或配对令牌不正确';
      });
      return;
    }
    _pairingFallback = true;
    setState(() => _status = _ConnStatus.loading);
    _controller.loadRequest(buildPairingUrl(widget.config)).catchError((_) {
      if (mounted) {
        _onLoadFailed('无法发起配对');
      }
    });
  }

  /// 后台停留超过阈值后回前台:reload 当前 /m/ 页面,让 SPA 重新拉取
  /// 会话/任务状态。页面本身无凭据参数,reload 不会重复校验口令。
  Future<void> _refreshAfterBackground() async {
    if (!mounted || _inErrorOverlay) {
      return;
    }
    final doc = _documentUrl;
    try {
      if (doc != null && !_urlHasCredential(doc)) {
        await _controller.reload();
      } else {
        await _controller.loadRequest(buildMobileUrl(widget.config));
      }
    } catch (_) {
      // 刷新失败保持旧页面;WebView 的网络错误回调会接管重连。
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _pausedAt ??= DateTime.now();
      return;
    }
    if (state != AppLifecycleState.resumed) {
      return;
    }
    final pausedAt = _pausedAt;
    _pausedAt = null;
    if (pausedAt == null ||
        DateTime.now().difference(pausedAt) < _backgroundRefreshThreshold) {
      return;
    }
    unawaited(_refreshAfterBackground());
  }

  /// 判定 WebResourceError 是否网络级(连接类)失败。
  bool _isNetworkError(WebResourceError error) => isNetworkLevelError(error);

  /// 自动重试的恢复路径:优先软恢复(reload 当前文档,保留 SPA 状态与滚动
  /// 位置);没有文档 URL(极早期失败)才退回配对 URL 冷启动。
  Future<void> _softRecover() async {
    _retryTimer?.cancel();
    _retryTimer = null;
    if (!mounted) {
      return;
    }
    setState(() {
      _errorMessage = null;
      _status = _ConnStatus.loading;
    });
    final doc = _documentUrl;
    try {
      if (doc != null) {
        await _controller.reload();
      } else {
        await _controller.loadRequest(buildPairingUrl(widget.config));
      }
    } catch (_) {
      if (mounted) {
        _onLoadFailed('重新加载失败');
      }
    }
  }

  /// 手动重试:冷启动路径(配对 URL),同时重置重试计数与页面状态。
  Future<void> _retryManually() async {
    _retryAttempt = 0;
    _retryTimer?.cancel();
    _retryTimer = null;
    if (!mounted) {
      return;
    }
    setState(() {
      _errorMessage = null;
      _status = _ConnStatus.loading;
      _documentUrl = null;
      _hasLoadedOnce = false; // 冷启动会离开旧页面,重新显示加载遮罩。
    });
    try {
      await _controller.loadRequest(buildPairingUrl(widget.config));
    } catch (_) {
      if (mounted) {
        _onLoadFailed('无法发起连接');
      }
    }
  }

  /// 拦截外链后的轻提示;连续拦截合并为一条,不刷屏。
  void _notifyBlockedNavigation() {
    final now = DateTime.now();
    if (_lastBlockedNoticeAt != null &&
        now.difference(_lastBlockedNoticeAt!) < const Duration(seconds: 2)) {
      return;
    }
    _lastBlockedNoticeAt = now;
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('已阻止跳转到外部链接,凭据不会离开当前服务器')));
  }

  /// 配置清除或变更前清空 WebView 会话数据。Cookie 值是服务端签发的
  /// 会话凭据,只删 secure_storage 不等于登出;这里把 localStorage、
  /// cache 与所有 WebView cookie 一并清掉。
  Future<void> _clearWebViewData() async {
    // 三项独立清理:任一失败都不影响其余清理与配置变更。
    try {
      await _controller.clearLocalStorage();
    } catch (_) {}
    try {
      await _controller.clearCache();
    } catch (_) {}
    try {
      await WebViewCookieManager().clearCookies();
    } catch (_) {}
  }

  Future<void> _openSettings() async {
    final result = await Navigator.of(context).push<SettingsResult>(
      MaterialPageRoute(builder: (_) => SettingsPage(initial: widget.config)),
    );
    if (result == null || !mounted) {
      return;
    }
    await _clearWebViewData();
    if (!mounted) {
      return;
    }
    if (result.cleared) {
      widget.onConfigCleared();
    } else if (result.config != null) {
      widget.onConfigChanged(result.config!);
    }
  }

  /// Android 系统返回键:优先退 WebView 历史,没有历史才退出 App。
  /// Android 系统返回键:优先退 WebView 历史;主页根路由吞掉返回,
  /// 避免左缘系统返回手势与 Web 内容滑动太接近而误关 App。
  Future<void> _handleSystemBack() async {
    try {
      final canGoBack = await _controller.canGoBack();
      if (!mounted) {
        return;
      }
      if (canGoBack) {
        await _controller.goBack();
      }
    } catch (_) {
      // canGoBack/goBack 探测失败时也吞掉返回,不让主页因此退出。
    }
  }

  @override
  Widget build(BuildContext context) {
    final error = _errorMessage;
    final retryDelay = _status == _ConnStatus.reconnecting
        ? retryDelayMs(_retryAttempt)
        : null;
    final showFirstLoadOverlay =
        !_hasLoadedOnce && _status == _ConnStatus.loading;

    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          return;
        }
        unawaited(_handleSystemBack());
      },
      child: Scaffold(
        // WebView 及其覆盖层整体避开状态栏/手势条;状态栏底色由 Scaffold
        // 提供,顶部不再出现 Web 内容与系统状态条叠在一起的情况。
        body: SafeArea(
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 填满剩余空间:WebView 直接铺底。
              WebViewWidget(controller: _controller),
              // 首次加载遮罩:在 WebView 首帧/配对 302 完成前显示品牌加载页,
              // 而不是让用户看 WebView 的白屏或错误中间态。
              if (showFirstLoadOverlay) _LoadingOverlay(config: widget.config),
              // 自动重连横幅:仅重连等待期间显示。
              if (_status == _ConnStatus.reconnecting)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: _ReconnectBanner(
                    attempt: _retryAttempt,
                    delayMs: retryDelay!,
                  ),
                ),
              if (error != null)
                _ErrorOverlay(
                  message: error,
                  config: widget.config,
                  onRetry: _retryManually,
                  onChangeConfig: _openSettings,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 自动重连横幅:显示第几次与下次重试秒数。
class _ReconnectBanner extends StatelessWidget {
  const _ReconnectBanner({required this.attempt, required this.delayMs});

  final int attempt;
  final int delayMs;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: DshTokens.warning,
      padding: const EdgeInsets.symmetric(
        vertical: 7,
        horizontal: DshTokens.space3,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.white,
            ),
          ),
          const SizedBox(width: DshTokens.space2),
          Flexible(
            child: Text(
              '连接断开,第 $attempt/$maxRetryAttempts 次自动重连,'
              '约 ${delayMs ~/ 1000} 秒后重试…',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

/// 首次加载遮罩:品牌标 + 连接目标(仅 origin,无凭据)+ 进度指示。
class _LoadingOverlay extends StatelessWidget {
  const _LoadingOverlay({required this.config});

  final AppConfig config;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ColoredBox(
      color: theme.scaffoldBackgroundColor,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(DshTokens.space6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const DshBrandMark(size: 64),
              const SizedBox(height: DshTokens.space4),
              Text(
                'DSH Mobile',
                style: theme.textTheme.titleLarge?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: DshTokens.space2),
              Text(
                '正在连接 ${config.displayOrigin}',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: DshTokens.space1),
              Text(
                '${config.modeLabel} · 首次进入会先完成安全配对',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: DshTokens.space5),
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.4),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 加载失败覆盖层(自动重试耗尽):错误信息 + 重试 + 改配置。
class _ErrorOverlay extends StatelessWidget {
  const _ErrorOverlay({
    required this.message,
    required this.config,
    required this.onRetry,
    required this.onChangeConfig,
  });

  final String message;
  final AppConfig config;
  final VoidCallback onRetry;
  final VoidCallback onChangeConfig;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ColoredBox(
      color: theme.scaffoldBackgroundColor,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(DshTokens.space5),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.cloud_off,
                  size: 56,
                  color: DshTokens.inkMuted,
                ),
                const SizedBox(height: DshTokens.space3),
                Text(
                  '无法连接服务器',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: DshTokens.space2),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: DshTokens.space4),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: DshTokens.space4,
                    vertical: DshTokens.space3,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface,
                    border: Border.all(color: theme.dividerColor),
                    borderRadius: BorderRadius.circular(DshTokens.radiusM),
                  ),
                  child: Column(
                    children: [
                      Text('连接目标', style: theme.textTheme.bodySmall),
                      const SizedBox(height: 2),
                      Text(
                        '${config.modeLabel} · ${config.displayOrigin}',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: DshTokens.space5),
                FilledButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('重试'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: DshTokens.space5,
                      vertical: DshTokens.space3,
                    ),
                  ),
                ),
                const SizedBox(height: DshTokens.space2),
                TextButton.icon(
                  onPressed: onChangeConfig,
                  icon: const Icon(Icons.settings_outlined),
                  label: const Text('改配置'),
                ),
                const SizedBox(height: DshTokens.space2),
                Text(
                  '自动重试已停止;手动重试会重新走安全配对。',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
