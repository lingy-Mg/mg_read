import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_startup.dart';
import 'package:mg_read/app/bootstrap.dart';
import 'package:mg_read/app/mg_read_app.dart';
import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/core/persistence/persistence.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';

import '../core/diagnostics/diagnostics_testkit.dart';
import 'mg_read_app_test_support.dart';
import '../core/settings/settings_testkit.dart';

void main() {
  test('bootstrap calls runApp exactly once', () async {
    final settings = AppSettingsManager(store: FakeSettingsStore(), registry: settingsTestRegistry);
    addTearDown(settings.close);
    var calls = 0;
    await bootstrapMgReadApp(
      settingsManager: settings,
      diagnosticsServiceFactory: null,
      contentLibraryFactory: null,
      appRunner: (_) => calls += 1,
      child: const SizedBox.shrink(),
    );
    expect(calls, 1);
  });

  test('startup retries are coalesced and failure is safe', () async {
    var calls = 0;
    final controller = AppStartupController(
      diagnostics: DiagnosticsManager(
        sink: const NoopDiagnosticEventSink(),
        registry: AppDiagnosticEvents.registry,
        source: DiagnosticSource.app,
      ),
      openResources: () async {
        calls += 1;
        if (calls == 1) {
          throw StateError('private path must not escape');
        }
        return const AppStartupResources();
      },
    );
    addTearDown(controller.close);

    await Future.wait(<Future<void>>[controller.start(), controller.start()]);
    expect(calls, 1);
    expect(controller.state.status, AppStartupStatus.retryableFailure);
    expect(controller.state.errorCode, isNot(contains('private')));

    await Future.wait(<Future<void>>[controller.retry(), controller.retry()]);
    expect(calls, 2);
    expect(controller.state.status, AppStartupStatus.ready);
  });

  testWidgets('delayed startup exposes one loading animation', (tester) async {
    final settings = await createTestAppSettings();
    addTearDown(settings.close);
    final gate = Completer<void>();
    late AppStartupController startup;
    startup = AppStartupController(
      ownsLoadingAnimation: true,
      diagnostics: DiagnosticsManager(
        sink: const NoopDiagnosticEventSink(),
        registry: AppDiagnosticEvents.registry,
        source: DiagnosticSource.app,
      ),
      openResources: () async {
        await gate.future;
        return const AppStartupResources();
      },
    );
    addTearDown(startup.close);
    final boot = startup.start();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appSettingsProvider.overrideWithValue(settings),
          appStartupControllerProvider.overrideWithValue(startup),
          pluginRuntimeGatewayProvider.overrideWithValue(const TestReadyPluginRuntimeGateway()),
        ],
        child: const MgReadApp(),
      ),
    );
    // The first shell frame is static. The gate can arm its one animation
    // only after that frame if startup is still blocked.
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    gate.complete();
    await boot;
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('ready before first pump does not render startup animation', (tester) async {
    final settings = await createTestAppSettings();
    addTearDown(settings.close);
    final startup = AppStartupController(
      ownsLoadingAnimation: true,
      diagnostics: DiagnosticsManager(
        sink: const NoopDiagnosticEventSink(),
        registry: AppDiagnosticEvents.registry,
        source: DiagnosticSource.app,
      ),
      openResources: () async => const AppStartupResources(),
    );
    addTearDown(startup.close);
    await startup.start();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appSettingsProvider.overrideWithValue(settings),
          appStartupControllerProvider.overrideWithValue(startup),
          pluginRuntimeGatewayProvider.overrideWithValue(const TestReadyPluginRuntimeGateway()),
        ],
        child: const MgReadApp(),
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  test('a real library keeps the gate locked until its terminal frame', () async {
    final root = await Directory.systemTemp.createTemp('mg-read-startup-library-');
    addTearDown(() => root.delete(recursive: true));
    final persistence = await AppPersistence.open(dataRoot: root, registry: RecordDocumentRegistry(contentLibraryRecordDocumentCodecs));
    final library = ContentLibrary.fromPersistence(persistence);
    final startup = AppStartupController(
      ownsLoadingAnimation: true,
      diagnostics: DiagnosticsManager(
        sink: const NoopDiagnosticEventSink(),
        registry: AppDiagnosticEvents.registry,
        source: DiagnosticSource.app,
      ),
      openResources: () async => AppStartupResources(contentLibrary: library, persistence: persistence),
    );
    addTearDown(startup.close);

    await startup.start();
    expect(startup.requiresLibraryFrame, isTrue);
    expect(startup.isInteractive, isFalse);
    startup.signalLibraryTerminalFrame(resultState: 'empty');
    expect(startup.hasLibraryTerminalFrame, isTrue);
    expect(startup.isInteractive, isTrue);
  });

  testWidgets('Runtime warmup completes before deferred maintenance', (tester) async {
    final settings = await createTestAppSettings();
    addTearDown(settings.close);
    final diagnostics = DiagnosticsTestkit();
    addTearDown(diagnostics.dispose);
    final startup = AppStartupController(diagnostics: diagnostics.manager, openResources: () async => const AppStartupResources());
    addTearDown(startup.close);
    await startup.start();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appSettingsProvider.overrideWithValue(settings),
          appStartupControllerProvider.overrideWithValue(startup),
          diagnosticsManagerProvider.overrideWithValue(diagnostics.manager),
          pluginRuntimeGatewayProvider.overrideWithValue(const TestReadyPluginRuntimeGateway()),
        ],
        child: const MgReadApp(),
      ),
    );
    for (var index = 0; index < 5; index += 1) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    final stages = diagnostics.sink.events
        .where((event) => event.eventName == 'app.startup.stage')
        .map((event) => event.attributes.values['stage'])
        .whereType<DiagnosticStringValue>()
        .map((value) => value.value)
        .toList(growable: false);
    expect(stages, containsAllInOrder(<String>['libraryFirstUsableFrame', 'runtimeReady', 'maintenanceComplete']));
  });
}
