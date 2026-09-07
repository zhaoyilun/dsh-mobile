// 数据层探针：直接驱动 JoinService 复现加入报错（不走 UI 框架）
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:dsh_mobile/federation/join_service.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  test('join 数据层探针', () async {
    final code = const String.fromEnvironment('PAIRING_CODE');
    final svc = JoinService(rootAddress: 'example.com');
    try {
      final out = await svc.join(code: code, name: 'probe-join');
      // ignore: avoid_print
      print('JOIN_OK appId=${out.identity.deviceId} dsh=${out.dsh.name} broker=${out.brokerUrl}');
    } catch (e) {
      // ignore: avoid_print
      print('JOIN_FAIL: $e');
    }
  });
}
