/// Native debug previews use inspected snapshots and cancel when stopped or closed.
library;

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/discovery/presentation/source_debug_page.dart';
import 'package:mg_read/features/discovery/presentation/source_picker_sheet.dart';
import '../fixtures/source_debug_gateway.dart';

void main() {
  testWidgets('debug is left of search, ignores filtering and opens native detail without duplicate requests', (tester) async {
    final gateway = DebugTestGateway();
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  final result = await showDiscoverySourcePicker(context, sources: gateway.sources, selectedSourceId: 'a');
                  if (result is DiscoverySourceDebugRequested && context.mounted) {
                    await showSourceDebugPage(context, gateway: gateway, sources: gateway.sources);
                  }
                },
                child: const Text('选择源'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('选择源'));
    await tester.pumpAndSettle();
    expect(
      tester.getCenter(find.byKey(const Key('discovery-source-picker-debug'))).dx,
      lessThan(tester.getCenter(find.byKey(const Key('discovery-source-picker-search-toggle'))).dx),
    );
    await tester.tap(find.byKey(const Key('discovery-source-picker-search-toggle')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('discovery-source-picker-search')), '数据源 b');
    await tester.tap(find.byKey(const Key('discovery-source-picker-debug')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.text('1/3 · 数据源 a'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1300));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('首个资源 a'), findsWidgets);
    expect(find.text('测试作者'), findsWidgets);
    expect(gateway.calls.where((value) => value == 'a:detail:book-a').length, 1);
    expect(gateway.calls.where((value) => value == 'a:catalog:book-a').length, 1);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const Key('source-debug-stop')));
    await tester.pumpAndSettle();
    expect(find.text('检查已停止'), findsOneWidget);
    expect(find.byKey(const ValueKey('source-debug-result-a')), findsOneWidget);
    expect(gateway.calls.any((value) => value.startsWith('b:')), isFalse);
  });

  testWidgets('closing the debug route cancels in-flight work and ignores late errors', (tester) async {
    final pending = Completer<PluginDiscoverResult>();
    final gateway = DebugTestGateway()..discoverOverride = (_, _) => pending.future;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showSourceDebugPage(context, gateway: gateway, sources: gateway.sources),
              child: const Text('开始检查'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('开始检查'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(gateway.cancellations.first.isCancelled, isTrue);
    pending.completeError(StateError('late failure'));
    await tester.pump();
    expect(gateway.calls, ['a:discover:home']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty source list disables Debug', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDiscoverySourcePicker(context, sources: [], selectedSourceId: null),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(tester.widget<IconButton>(find.byKey(const Key('discovery-source-picker-debug'))).onPressed, isNull);
  });
}
