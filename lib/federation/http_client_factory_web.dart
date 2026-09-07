// dsh-federation — HTTP client 工厂（Web 实现）：XHR 版（见 xhr_client.dart 头注释：
// http 包 BrowserClient 的 fetch 实现会破坏 Flutter Web 手势，E2E 实测以 XHR 替代）。
// withCredentials 保留：浏览器托管 cookie 的会话方案不变。
import 'package:http/http.dart' as http;

import 'xhr_client.dart';

http.Client createHttpClient() => XhrClient(withCredentials: true);
