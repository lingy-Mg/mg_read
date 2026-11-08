import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/features/tv_companion/presentation/manual_tv_address_dialog.dart';

void main() {
  testWidgets('invalid address and port remain editable with inline validation', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(onPressed: () => showManualTvAddressDialog(context), child: const Text('连接')),
          ),
        ),
      ),
    );
    await tester.tap(find.text('连接'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('companion-manual-address')), '8.8.8.8');
    await tester.enterText(find.byKey(const Key('companion-manual-port')), '70000');
    await tester.tap(find.byKey(const Key('companion-manual-connect')));
    await tester.pumpAndSettle();
    expect(find.text('请输入有效的局域网 IPv4 地址'), findsOneWidget);
    expect(find.text('请输入 1–65535 之间的端口'), findsOneWidget);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keeps manual input controllers alive through the dialog exit animation', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 520));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    ManualTvAddress? selected;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(onPressed: () async => selected = await showManualTvAddressDialog(context), child: const Text('打开手动连接')),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开手动连接'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('companion-manual-address')), '192.168.50.200');
    await tester.enterText(find.byKey(const Key('companion-manual-port')), '43521');
    await tester.ensureVisible(find.byKey(const Key('companion-manual-connect')));
    await tester.tap(find.byKey(const Key('companion-manual-connect')));

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();

    expect(selected, (address: '192.168.50.200', port: 43521));
    expect(tester.takeException(), isNull);
  });
}
