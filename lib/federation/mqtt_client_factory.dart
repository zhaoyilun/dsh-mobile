// dsh-federation — MQTT 客户端工厂（IO 实现）
// TCP 与 WebSocket 双模：MqttServerClient（dart:io）。
// useWebSocket 是 MqttServerClient 的专属开关，封装在这里，
// Web 侧（mqtt_client_factory_web.dart）用 MqttBrowserClient 替代。
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

MqttClient createMqttClient({
  required String server,
  required String clientId,
  required int port,
  required bool useWebSocket,
}) {
  final client = MqttServerClient.withPort(server, clientId, port);
  client.useWebSocket = useWebSocket;
  return client;
}
