import 'package:dsh_mobile/config_store.dart';
import 'package:dsh_mobile/theme.dart';
import 'package:dsh_mobile/widgets/connection_mode_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget buildHarness(ConnectionMode initialMode) {
    var mode = initialMode;
    return MaterialApp(
      theme: buildDshTheme(),
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) {
            return ConnectionModeSelector(
              value: mode,
              onChanged: (value) => setState(() => mode = value),
              publicFields: const Text('PUBLIC_FORM'),
              lanFields: const Text('LAN_FORM'),
            );
          },
        ),
      ),
    );
  }

  testWidgets('默认公网卡片展开,局域网卡片折叠', (tester) async {
    await tester.pumpWidget(buildHarness(ConnectionMode.public));
    await tester.pumpAndSettle();

    expect(find.text('PUBLIC_FORM'), findsOneWidget);
    expect(find.text('LAN_FORM'), findsNothing);
    expect(find.text('公网服务器(推荐)'), findsOneWidget);
    expect(find.text('局域网直连'), findsOneWidget);
    expect(find.text('推荐'), findsOneWidget);
  });

  testWidgets('点击局域网卡片后切换并展开对应表单', (tester) async {
    await tester.pumpWidget(buildHarness(ConnectionMode.public));
    await tester.pumpAndSettle();

    await tester.tap(find.text('局域网直连'));
    await tester.pumpAndSettle();

    expect(find.text('LAN_FORM'), findsOneWidget);
    expect(find.text('PUBLIC_FORM'), findsNothing);
  });

  testWidgets('点击公网卡片可切回公网模式', (tester) async {
    await tester.pumpWidget(buildHarness(ConnectionMode.lan));
    await tester.pumpAndSettle();

    expect(find.text('LAN_FORM'), findsOneWidget);

    await tester.tap(find.text('公网服务器(推荐)'));
    await tester.pumpAndSettle();

    expect(find.text('PUBLIC_FORM'), findsOneWidget);
    expect(find.text('LAN_FORM'), findsNothing);
  });
}
