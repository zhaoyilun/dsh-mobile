// 自驱 UI 全流程：真实页面 + 真实平台通道，自动填根地址/配对码、点按钮、等待结果（不需要人操作）
// 配对码从环境变量 PAIRING_CODE 读（dsh 桌面端 POST /v1/pairing/code 生成），未设置则 skip。
// 跑法：PAIRING_CODE=XXXX-XXXX flutter test integration_test/join_ui_probe_test.dart -d macos
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:dsh_mobile/main.dart';
import 'package:dsh_mobile/federation/federation_home_page.dart';
import 'package:dsh_mobile/federation/federation_state.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('自驱加入：填根地址+配对码 → 加入 → 连接 + pairings', (tester) async {
    final code = Platform.environment['PAIRING_CODE'];
    if (code == null || code.isEmpty) {
      markTestSkipped('PAIRING_CODE 未设置 — skip join 流程探针');
      return;
    }
    await tester.pumpWidget(const DshMobileApp(home: FederationHomePage()));
    // 等待 init()（身份恢复/首帧）落定；已有身份时无 join 卡片，直接 skip
    await tester.pump(const Duration(seconds: 2));
    if (FederationState.instance.identity != null) {
      // 旧身份多为已被吊销的测试身份（authn 会拒）：清掉重走 join 流程
      // ignore: avoid_print
      print('[probe] 清理既有身份（${FederationState.instance.identity!.deviceId}）');
      await FederationState.instance.clearIdentity();
      await tester.pumpWidget(const DshMobileApp(home: FederationHomePage()));
      await tester.pump(const Duration(seconds: 1));
    }

    final rootField = find.widgetWithText(TextField, '根地址');
    expect(rootField, findsOneWidget, reason: '未加入状态应显示加入卡片');
    await tester.enterText(rootField, 'example.com');
    await tester.enterText(find.widgetWithText(TextField, '配对码'), code);
    await tester.enterText(find.widgetWithText(TextField, '设备名'), 'probe-macos');
    await tester.pump();

    await tester.tap(find.text('加入'));
    // 真实 http/钥匙串/mqtt：混合真实时间等待 + 泵帧
    for (int i = 0; i < 20; i++) {
      await Future.delayed(const Duration(seconds: 1));
      await tester.pump();
    }
    final state = FederationState.instance;
    // ignore: avoid_print
    print('JOIN-PROBE phase=${state.phase} msg=${state.phaseMessage ?? "-"}');
    // ignore: avoid_print
    print('JOIN-PROBE joinedDsh=${state.joinedDsh?.name ?? "-"}(${state.joinedDsh?.deviceId ?? "-"}) pairings=${state.pairings.length}');
    // ignore: avoid_print
    print('JOIN-PROBE 设备: ${state.view.devices.map((d) => '${d.name}:${d.online}').join(', ')}');
    expect(state.identity, isNotNull, reason: 'join 应签发并落盘身份');
    expect(state.joinedDsh, isNotNull, reason: 'join 响应应带回配对的 dsh');
  });
}
