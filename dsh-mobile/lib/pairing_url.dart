import 'config_store.dart';

/// 构造配对 URL,按连接模式分流:
///
/// - public:`<server>/m/?pass=<phone-pass>`——cloud-relay 校验手机口令后
///   Set-Cookie(HttpOnly)并 302 到同一路径剥掉查询串,落在 `/m/` 移动壳;
/// - lan:`<server>/pair?token=<token>&next=/m/`——DSH 校验配对令牌后设
///   cookie 并 302 到 `next`(`/m/` 移动壳,不再落桌面页)。
///
/// 凭据(query 参数)由 [Uri.replace] 负责百分号编码,含 `&`、`=`、`?`、
/// `#`、空格等特殊字符均安全;`next` 为同源相对路径,编码后由服务端解码。
Uri buildPairingUrl(AppConfig config) {
  final base = Uri.parse(config.baseUrl);
  switch (config.mode) {
    case ConnectionMode.public:
      return base.replace(path: '/m/', queryParameters: {'pass': config.token});
    case ConnectionMode.lan:
      return base.replace(
        path: '/pair',
        queryParameters: {'token': config.token, 'next': '/m/'},
      );
  }
}
