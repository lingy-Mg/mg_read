import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_settings_lifecycle.dart';
import 'package:mg_read/app/bootstrap.dart';
import 'package:mg_read/core/settings/settings.dart';

import '../core/settings/settings_testkit.dart';

void main() {
  testWidgets(
    'bootstrap awaits initialize and injects the manager explicitly',
    (WidgetTester tester) async {
      final store = FakeSettingsStore()..loadGate = Completer<void>();
      final manager = AppSettingsManager(
        store: store,
        registry: settingsTestRegistry,
      );
      Widget? mounted;
      final boot = bootstrapMgReadApp(
        settingsManager: manager,
        appRunner: (app) => mounted = app,
        child: Consumer(
          builder: (context, ref, child) => Text(
            ref.watch(appSettingsProvider).state.name,
            textDirection: TextDirection.ltr,
          ),
        ),
      );

      await tester.pump();
      expect(manager.state, SettingsState.loading);
      expect(mounted, isNull);

      store.loadGate!.complete();
      await boot;
      expect(manager.state, SettingsState.ready);
      expect(mounted, isNotNull);

      await tester.pumpWidget(mounted!);
      expect(find.text('ready'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await manager.close();
    },
  );

  testWidgets('bootstrap still exposes an explicit failed state', (
    WidgetTester tester,
  ) async {
    final store = FakeSettingsStore()..failLoads = true;
    final manager = AppSettingsManager(
      store: store,
      registry: settingsTestRegistry,
    );
    Widget? mounted;

    await bootstrapMgReadApp(
      settingsManager: manager,
      appRunner: (app) => mounted = app,
      child: Consumer(
        builder: (context, ref, child) => Text(
          ref.watch(appSettingsProvider).state.name,
          textDirection: TextDirection.ltr,
        ),
      ),
    );

    expect(manager.state, SettingsState.failed);
    await tester.pumpWidget(mounted!);
    expect(find.text('failed'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await manager.close();
  });

  testWidgets('paused lifecycle forces pending settings to flush', (
    WidgetTester tester,
  ) async {
    final store = FakeSettingsStore();
    final manager = AppSettingsManager(
      store: store,
      registry: settingsTestRegistry,
      policy: const SettingsPersistencePolicy(debounce: Duration(hours: 1)),
    );
    await manager.initialize();
    await manager.set(themeKey, 'dark');

    await tester.pumpWidget(
      AppSettingsLifecycleHost(
        manager: manager,
        child: const SizedBox.shrink(),
      ),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    await waitUntil(() => store.writeCalls == 1);

    expect(manager.status.isPersisted, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await manager.close();
  });
}
