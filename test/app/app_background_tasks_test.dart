/// Foreground checks must not depend on Runtime readiness or repaint loops.
library;

import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_background_tasks.dart';
import 'package:mg_read/app/app_startup.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/app_update/application/github_apk_update.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';
import '../core/diagnostics/diagnostics_testkit.dart';
import '../core/settings/settings_testkit.dart';

void main() {
  testWidgets('local frame unlocks checks despite stalled Runtime and resumes honor failure backoff', (tester) async {
    final diagnostics = DiagnosticsTestkit();
    final startup = AppStartupController(openResources: () async => const AppStartupResources(), diagnostics: diagnostics.manager);
    await startup.start();
    final settings = AppSettingsManager(store: FakeSettingsStore(), registry: AppSettingKeys.registry);
    await settings.initialize();
    await settings.set(AppSettingKeys.sourceAutoUpdateCheckEnabled, false);
    addTearDown(() async {
      await startup.close();
      await settings.close();
      await diagnostics.dispose();
    });
    var now = DateTime.utc(2026, 10, 28);
    var requests = 0;
    final updater = GitHubApkUpdateCoordinator(
      currentVersion: () async => throw StateError('HTTP fails first'),
      downloadAndInstall: (_, {onProgress}) async => fail('automatic checks cannot install'),
      supportDirectory: () async => throw StateError('no disk in this test'),
      httpClientFactory: () => _Client(() => requests++),
      clock: () => now,
      isAndroid: true,
    );
    final stalled = Completer<PluginRuntimeConnection>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appStartupControllerProvider.overrideWithValue(startup),
          appSettingsProvider.overrideWithValue(settings),
          githubApkUpdateCoordinatorProvider.overrideWithValue(updater),
          pluginRuntimeConnectionProvider.overrideWith((ref) => stalled.future),
        ],
        child: const MaterialApp(home: AppBackgroundTasks()),
      ),
    );
    await tester.pump();
    expect(requests, 0);
    startup.signalLibraryTerminalFrame();
    await tester.pumpAndSettle();
    expect(requests, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    now = now.add(const Duration(minutes: 1));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(requests, 2);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(requests, 2);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

final class _Client implements HttpClient {
  _Client(this.onRequest);
  final void Function() onRequest;
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    onRequest();
    return _Request();
  }

  @override
  void close({bool force = false}) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Request implements HttpClientRequest {
  @override
  HttpHeaders get headers => _Headers();
  @override
  Future<HttpClientResponse> close() async => _Response();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Headers implements HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Response implements HttpClientResponse {
  @override
  int get statusCode => HttpStatus.serviceUnavailable;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
