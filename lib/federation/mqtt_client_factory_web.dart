// dsh-federation — MQTT 客户端工厂（Web 实现）
// 浏览器没有 dart:io socket，只能走 WebSocket：MqttBrowserClient（mqtt_client
// 官方浏览器实现）。[server] 必须是完整 ws/wss URI（连接层差异由调用方保证：
// websocket 模式下传 uri.raw）。
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_browser_client.dart';

MqttClient createMqttClient({
  required String server,
  required String clientId,
  required int port,
  required bool useWebSocket,
}) {
  if (!useWebSocket) {
    // 浏览器连不了裸 TCP broker（mqtt://1883 这类），给出明确错误而不是静默失败。
    throw StateError('浏览器端只能连接 ws/wss 协议的 broker，当前地址不是 WebSocket：$server');
  }
  return MqttBrowserClient.withPort(server, clientId, port);
}
