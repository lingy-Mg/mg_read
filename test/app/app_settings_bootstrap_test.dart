/// 应用启动组合测试。
///
/// 职责：
/// - 验证共享持久化、设置和诊断注入边界。
/// - 验证慢速首次初始化不会阻止启动界面先挂载。
///
/// 注意：
/// - 测试只替换组合依赖，不启动真实 Runtime 或平台窗口。
///
/// TODO:
/// - 无。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_settings_lifecycle.dart';
import 'package:mg_read/app/bootstrap.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/core/persistence/persistence.dart';
import 'package:mg_read/core/settings/settings.dart';

import '../core/diagnostics/diagnostics_testkit.dart';
import '../core/settings/settings_testkit.dart';

void main() {
  test('default composition opens one shared app persistence', () async {
    final root = await Directory.systemTemp.createTemp(
      'mg-read-bootstrap-shared-persistence-',
    );
    addTearDown(() => root.delete(recursive: true));
    var openCalls = 0;
    Widget? mounted;

    await bootstrapMgReadApp(
      diagnosticsServiceFactory: null,
      dataRootResolver: () async => root,
      appPersistenceFactory: (dataRoot, diagnostics) {
        openCalls += 1;
        return AppPersistence.open(
          dataRoot: dataRoot,
          registry: RecordDocumentRegistry(<RecordDocumentCodec>[
            ...contentLibraryRecordDocumentCodecs,
            ...settingsRecordDocumentCodecs(
              AppSettingKeys.registry,
              scopeKind: 'app',
            ),
          ]),
          diagnostics: diagnostics,
        );
      },
      appRunner: (app) => mounted = app,
      child: const SizedBox.shrink(),
    );

    expect(openCalls, 1);
    final scope = mounted! as ProviderScope;
    final host = scope.child as AppSettingsLifecycleHost;
    expect(host.manager.state, SettingsState.ready);

    await host.manager.close();
    await host.closeContentLibrary?.call();
    host.disposeDiagnosticsBoundary?.call();
    await host.closeDiagnostics?.call();
  });

  testWidgets(
    'bootstrap mounts a startup surface before settings initialization completes',
    (WidgetTester tester) async {
      final store = FakeSettingsStore()..loadGate = Completer<void>();
      final manager = AppSettingsManager(
        store: store,
        registry: settingsTestRegistry,
      );
      Widget? mounted;
      final boot = bootstrapMgReadApp(
        settingsManager: manager,
        diagnosticsServiceFactory: null,
        contentLibraryFactory: null,
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
      expect(mounted, isNotNull);
      await tester.pumpWidget(mounted!);
      expect(find.text('正在启动…'), findsOneWidget);

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
      diagnosticsServiceFactory: null,
      contentLibraryFactory: null,
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

  test('bootstrap emits its span and injects diagnostics manager', () async {
    final diagnostics = DiagnosticsTestkit();
    final manager = AppSettingsManager(
      store: FakeSettingsStore(),
      registry: settingsTestRegistry,
    );
    Widget? mounted;

    await bootstrapMgReadApp(
      settingsManager: manager,
      diagnosticsManager: diagnostics.manager,
      diagnosticsServiceFactory: (_) async =>
          throw StateError('factory must not run for an injected manager'),
      contentLibraryFactory: null,
      appRunner: (app) => mounted = app,
      child: Consumer(
        builder: (context, ref, child) {
          return Text(
            '${identical(ref.watch(diagnosticsManagerProvider), diagnostics.manager)}',
            textDirection: TextDirection.ltr,
          );
        },
      ),
    );

    final scope = mounted! as ProviderScope;
    final host = scope.child as AppSettingsLifecycleHost;
    final container = ProviderContainer(overrides: scope.overrides);
    expect(
      identical(
        container.read(diagnosticsManagerProvider),
        diagnostics.manager,
      ),
      isTrue,
    );
    final bootstrapEvents = diagnostics.sink.events.where(
      (event) => event.eventName.startsWith('app.bootstrap.'),
    );
    expect(bootstrapEvents, hasLength(2));
    expect(bootstrapEvents.last.outcome, DiagnosticOutcome.success);

    container.dispose();
    host.disposeDiagnosticsBoundary?.call();
    await manager.close();
    await diagnostics.manager.close();
  });
}
