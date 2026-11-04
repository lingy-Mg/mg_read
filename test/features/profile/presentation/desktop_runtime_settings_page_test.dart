/// User-visible switch, pending state, rollback and restart failure behavior.
library;

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:mg_read/app/app_restart.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/profile/presentation/desktop_runtime_settings_page.dart';

void main() {
  late Directory root;
  late DesktopRuntimeSettings settings;
  var restarts = 0;
  var failRestart = false;

  Future<void> mount(WidgetTester tester, {bool bun = true}) async {
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('mgread-bun-page-');
      settings = DesktopRuntimeSettings.forTesting(preferenceFile: File('${root.path}/backend'), supportsBun: bun);
      await settings.initialize();
    });
    addTearDown(() => root.delete(recursive: true));
    restarts = 0;
    failRestart = false;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          desktopRuntimeSettingsProvider.overrideWithValue(settings),
          appRestartProvider.overrideWithValue(() async {
            restarts++;
            if (failRestart) throw StateError('restart failed');
          }),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: DesktopRuntimeSettingsPage(onBackRequested: () {}),
        ),
      ),
    );
  }

  Future<void> select(WidgetTester tester, DesktopRuntimeBackend backend) async {
    await tester.runAsync(() async {
      await tester.tap(find.byKey(Key('desktop-runtime-${backend.name}')));
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (settings.selected != backend && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(settings.selected, backend);
    });
    await tester.pumpAndSettle();
  }

  testWidgets('switch can be deferred and cancelled without changing the active host', (tester) async {
    await mount(tester);
    expect(find.text('JavaScript 运行时'), findsOneWidget);
    await select(tester, DesktopRuntimeBackend.bun);
    expect(find.text('重启后生效'), findsOneWidget);
    expect(settings.active, DesktopRuntimeBackend.node);
    await tester.tap(find.text('稍后重启'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('desktop-runtime-pending')), findsOneWidget);
    expect(restarts, 0);
    await select(tester, DesktopRuntimeBackend.node);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byKey(const Key('desktop-runtime-pending')), findsNothing);
  });

  testWidgets('immediate restart occurs only after the choice has been saved', (tester) async {
    await mount(tester);
    await select(tester, DesktopRuntimeBackend.bun);
    expect(restarts, 0);
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, '立即重启').last);
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    await tester.pump();
    expect(restarts, 1);
    expect(settings.selected, DesktopRuntimeBackend.bun);
  });

  testWidgets('failed restart keeps the pending choice and offers retry', (tester) async {
    await mount(tester);
    failRestart = true;
    await select(tester, DesktopRuntimeBackend.bun);
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, '立即重启').last);
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('desktop-runtime-error')), findsOneWidget);
    expect(settings.restartRequired, isTrue);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '立即重启')).onPressed, isNotNull);
  });

  testWidgets('incomplete installation explains why Bun cannot be selected', (tester) async {
    await mount(tester, bun: false);
    expect(tester.widget<ListTile>(find.byKey(const Key('desktop-runtime-bun'))).enabled, isFalse);
    expect(tester.widget<ListTile>(find.byKey(const Key('desktop-runtime-node'))).enabled, isTrue);
    expect(find.textContaining('当前安装包缺少 Bun'), findsOneWidget);
  });
}
