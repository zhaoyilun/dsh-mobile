// dsh-federation — HTTP client 工厂（IO 实现）：默认 client（dart:io 实现）
import 'package:http/http.dart' as http;

http.Client createHttpClient() => http.Client();
