import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';
import 'package:mg_read/features/plugins/presentation/plugin_runtime_status_page.dart';
import 'package:mg_read/features/plugins/presentation/plugin_runtime_source_detail_page.dart';
import 'package:mg_read/features/profile/presentation/profile_page.dart';

import '../../../app/mg_read_app_test_support.dart';
import '../../../core/diagnostics/diagnostics_testkit.dart';

void main() {
  test(
    'application port projects success with exactly one span terminal',
    () async {
      final diagnostics = DiagnosticsTestkit();
      addTearDown(diagnostics.dispose);
      final gateway = _FakePluginRuntimeGateway(_connected);
      final container = ProviderContainer(
        overrides: [
          diagnosticsManagerProvider.overrideWithValue(diagnostics.manager),
          pluginRuntimeGatewayProvider.overrideWithValue(gateway),
        ],
      );
      addTearDown(container.dispose);
      final subscription = container.listen(
        pluginRuntimeConnectionProvider,
        (_, _) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);

      final result = await container.read(
        pluginRuntimeConnectionProvider.future,
      );

      expect(result.runtimeVersion, '0.2.0-standard.2');
      expect(result.plugins.single.id, 'org.example.fixture');
      expect(gateway.calls, 1);
      expect(
        diagnostics.sink.events
            .where(
              (event) => event.eventName.startsWith('runtime.facade.call.'),
            )
            .map((event) => event.eventName),
        <String>['runtime.facade.call.start', 'runtime.facade.call.complete'],
      );
    },
  );

  test(
    'application port normalizes failure and records one error terminal',
    () async {
      final diagnostics = DiagnosticsTestkit();
      addTearDown(diagnostics.dispose);
      final container = ProviderContainer(
        overrides: [
          diagnosticsManagerProvider.overrideWithValue(diagnostics.manager),
          pluginRuntimeGatewayProvider.overrideWithValue(
            _FailingPluginRuntimeGateway(),
          ),
        ],
      );
      addTearDown(container.dispose);
      final terminal = Completer<AsyncValue<PluginRuntimeConnection>>();
      final subscription = container.listen(pluginRuntimeConnectionProvider, (
        _,
        next,
      ) {
        if (next.hasError && !terminal.isCompleted) terminal.complete(next);
      }, fireImmediately: true);
      addTearDown(subscription.close);

      final state = await terminal.future;
      expect(
        state.error,
        isA<AppError>().having(
          (error) => error.code,
          'code',
          AppErrorCode.runtimeUnavailable,
        ),
      );
      expect(
        diagnostics.sink.events
            .where(
              (event) => event.eventName.startsWith('runtime.facade.call.'),
            )
            .map((event) => event.eventName),
        <String>['runtime.facade.call.start', 'runtime.facade.call.error'],
      );
    },
  );

  test(
    'Runtime startup detail is normalized without retaining its message',
    () {
      const secretCanary = 'Bearer RUNTIME-SECRET-CANARY';
      final error = normalizePluginRuntimeError(
        const PluginRuntimeException(
          'runtime_node_executable_missing',
          secretCanary,
        ),
      );

      expect(error.code, AppErrorCode.runtimeStartFailed);
      expect(error.toString(), isNot(contains(secretCanary)));
    },
  );

  test('plugin response failures use the stable invalid-format UI code', () {
    final error = normalizePluginRuntimeError(
      const PluginRuntimeException(
        'plugin_invalid_response',
        'Plugin payload details must not escape.',
      ),
    );

    expect(error.code, AppErrorCode.invalidFormat);
    expect(error.toString(), isNot(contains('payload details')));
  });

  test(
    'source enable action persists then refreshes the Runtime projection',
    () async {
      final diagnostics = DiagnosticsTestkit();
      addTearDown(diagnostics.dispose);
      final gateway = _MutablePluginRuntimeGateway();
      final container = ProviderContainer(
        overrides: [
          diagnosticsManagerProvider.overrideWithValue(diagnostics.manager),
          pluginRuntimeGatewayProvider.overrideWithValue(gateway),
        ],
      );
      addTearDown(container.dispose);

      await container.read(pluginRuntimeConnectionProvider.future);
      await container
          .read(pluginRuntimeSourceActionProvider.notifier)
          .setEnabled(pluginId: 'org.example.mutable', enabled: false);

      final result = await container.read(
        pluginRuntimeConnectionProvider.future,
      );
      expect(gateway.setEnabledCalls, 1);
      expect(result.plugins.single.enabled, isFalse);
      expect(
        diagnostics.sink.events
            .where(
              (event) => event.eventName.startsWith('runtime.facade.call.'),
            )
            .map((event) => event.eventName),
        containsAllInOrder(<String>[
          'runtime.facade.call.start',
          'runtime.facade.call.complete',
        ]),
      );
    },
  );

  testWidgets('data-source page renders the Runtime source projection', (
    WidgetTester tester,
  ) async {
    final diagnostics = DiagnosticsTestkit();
    addTearDown(diagnostics.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          diagnosticsManagerProvider.overrideWithValue(diagnostics.manager),
          pluginRuntimeGatewayProvider.overrideWithValue(
            _FakePluginRuntimeGateway(_connected),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: PluginRuntimeStatusPage(
            onBackRequested: () {},
            onDestinationRequested: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('管理数据来源'), findsOneWidget);
    expect(find.text('我的数据来源'), findsOneWidget);
    expect(find.text('已启用 1/1'), findsOneWidget);
    expect(find.text('示例插件'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('data-source-org.example.fixture')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('data-source-add')), findsOneWidget);
  });

  testWidgets('add data source imports through the Runtime application port', (
    WidgetTester tester,
  ) async {
    final diagnostics = DiagnosticsTestkit();
    addTearDown(diagnostics.dispose);
    final gateway = _MutablePluginRuntimeGateway();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          diagnosticsManagerProvider.overrideWithValue(diagnostics.manager),
          pluginRuntimeGatewayProvider.overrideWithValue(gateway),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: PluginRuntimeStatusPage(
            onBackRequested: () {},
            onDestinationRequested: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('data-source-add')));
    await tester.pumpAndSettle();

    expect(gateway.importLocalPluginCalls, 1);
    expect(find.text('数据来源已添加。'), findsOneWidget);
  });

  testWidgets('source management opens the typed Runtime status route', (
    WidgetTester tester,
  ) async {
    await _setViewport(tester, const Size(390, 900));
    final settings = await createTestAppSettings();
    addTearDown(settings.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          pluginRuntimeGatewayProvider.overrideWithValue(
            _FakePluginRuntimeGateway(_connected),
          ),
        ],
        child: testMgReadApp(settings),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('app-nav-profile')));
    await tester.pumpAndSettle();
    expect(find.byType(ProfilePage), findsOneWidget);
    final profileContent = find.byKey(const Key('profile-page-content'));
    await tester.scrollUntilVisible(
      find.byKey(const Key('profile-setting-source-management')),
      220,
      scrollable: find.descendant(
        of: profileContent,
        matching: find.byType(Scrollable),
      ),
    );
    await tester.tap(
      find.byKey(const Key('profile-setting-source-management')),
    );
    await tester.pumpAndSettle();

    expect(find.byType(PluginRuntimeStatusPage), findsOneWidget);
    expect(find.text('管理数据来源'), findsOneWidget);
    expect(find.text('示例插件'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('data-source-org.example.fixture')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(PluginRuntimeSourceDetailPage), findsOneWidget);
    expect(find.text('查看数据源'), findsOneWidget);

    await tester.tap(find.byKey(const Key('data-source-detail-back')));
    await tester.pumpAndSettle();
    expect(find.byType(PluginRuntimeStatusPage), findsOneWidget);

    await tester.tap(find.byKey(const Key('profile-detail-back')));
    await tester.pumpAndSettle();
    expect(find.byType(ProfilePage), findsOneWidget);
  });

  testWidgets('app warms the shared plugin Runtime after its first frame', (
    WidgetTester tester,
  ) async {
    final settings = await createTestAppSettings();
    addTearDown(settings.close);
    final gateway = _FakePluginRuntimeGateway(_connected);

    await tester.pumpWidget(testMgReadApp(settings, runtimeGateway: gateway));
    await tester.pumpAndSettle();

    expect(gateway.calls, 1);
  });
}

Future<void> _setViewport(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pump();
}

const _connected = PluginRuntimeConnection(
  isHealthy: true,
  nodeVersion: '24.16.0',
  runtimeVersion: '0.2.0-standard.2',
  plugins: <PluginRuntimePlugin>[
    PluginRuntimePlugin(
      activeVersion: '1.0.0',
      contentKinds: <String>['novel'],
      displayName: '示例插件',
      enabled: true,
      id: 'org.example.fixture',
      name: '示例插件',
      pendingVersion: null,
      status: 'active',
    ),
  ],
);

final class _FakePluginRuntimeGateway implements PluginRuntimeGateway {
  _FakePluginRuntimeGateway(this.result);

  final PluginRuntimeConnection result;
  int calls = 0;

  @override
  Stream<RuntimeInitializationProgress> get initialization =>
      const Stream<RuntimeInitializationProgress>.empty();

  @override
  Future<PluginInstallationSize> inspectInstallationSize({
    required String pluginId,
    required PluginInstallationSizeScope scope,
  }) async => PluginInstallationSize(
    bytes: 0,
    fileCount: 0,
    pluginId: pluginId,
    scope: scope,
    version: 'test',
  );

  @override
  Future<bool> importLocalPlugin() async => false;

  @override
  Future<bool> selectDevelopmentDirectory() async => false;

  @override
  Future<PluginCodeDirectoryKind> openCodeDirectory({
    required String pluginId,
  }) async => PluginCodeDirectoryKind.installed;

  @override
  Future<void> openRuntimePrivateDirectory() async {}

  @override
  Future<PluginRuntimeConnection> inspect() async {
    calls += 1;
    return result;
  }

  @override
  Future<void> setEnabled({
    required String pluginId,
    required bool enabled,
  }) async {}
}

final class _FailingPluginRuntimeGateway implements PluginRuntimeGateway {
  @override
  Stream<RuntimeInitializationProgress> get initialization =>
      const Stream<RuntimeInitializationProgress>.empty();

  @override
  Future<PluginInstallationSize> inspectInstallationSize({
    required String pluginId,
    required PluginInstallationSizeScope scope,
  }) async => PluginInstallationSize(
    bytes: 0,
    fileCount: 0,
    pluginId: pluginId,
    scope: scope,
    version: 'test',
  );

  @override
  Future<bool> importLocalPlugin() {
    throw AppError.fromCode(AppErrorCode.runtimeUnavailable);
  }

  @override
  Future<bool> selectDevelopmentDirectory() {
    throw AppError.fromCode(AppErrorCode.runtimeUnavailable);
  }

  @override
  Future<PluginCodeDirectoryKind> openCodeDirectory({
    required String pluginId,
  }) {
    throw AppError.fromCode(AppErrorCode.runtimeUnavailable);
  }

  @override
  Future<void> openRuntimePrivateDirectory() {
    throw AppError.fromCode(AppErrorCode.runtimeUnavailable);
  }

  @override
  Future<PluginRuntimeConnection> inspect() async {
    await Future<void>.delayed(Duration.zero);
    throw AppError.fromCode(AppErrorCode.runtimeUnavailable);
  }

  @override
  Future<void> setEnabled({required String pluginId, required bool enabled}) {
    throw AppError.fromCode(AppErrorCode.runtimeUnavailable);
  }
}

final class _MutablePluginRuntimeGateway implements PluginRuntimeGateway {
  PluginRuntimeConnection _connection = const PluginRuntimeConnection(
    isHealthy: true,
    nodeVersion: '24.16.0',
    runtimeVersion: 'test-runtime',
    plugins: <PluginRuntimePlugin>[
      PluginRuntimePlugin(
        activeVersion: '1.0.0',
        contentKinds: <String>['novel'],
        displayName: '可切换数据源',
        enabled: true,
        id: 'org.example.mutable',
        name: 'mutable',
        pendingVersion: null,
        status: 'active',
      ),
    ],
  );

  int setEnabledCalls = 0;
  int importLocalPluginCalls = 0;

  @override
  Stream<RuntimeInitializationProgress> get initialization =>
      const Stream<RuntimeInitializationProgress>.empty();

  @override
  Future<PluginInstallationSize> inspectInstallationSize({
    required String pluginId,
    required PluginInstallationSizeScope scope,
  }) async => PluginInstallationSize(
    bytes: 0,
    fileCount: 0,
    pluginId: pluginId,
    scope: scope,
    version: 'test',
  );

  @override
  Future<bool> importLocalPlugin() async {
    importLocalPluginCalls += 1;
    return true;
  }

  @override
  Future<bool> selectDevelopmentDirectory() async => false;

  @override
  Future<PluginCodeDirectoryKind> openCodeDirectory({
    required String pluginId,
  }) async => PluginCodeDirectoryKind.installed;

  @override
  Future<void> openRuntimePrivateDirectory() async {}

  @override
  Future<PluginRuntimeConnection> inspect() async => _connection;

  @override
  Future<void> setEnabled({
    required String pluginId,
    required bool enabled,
  }) async {
    setEnabledCalls += 1;
    final PluginRuntimePlugin plugin = _connection.plugins.single;
    _connection = PluginRuntimeConnection(
      isHealthy: _connection.isHealthy,
      nodeVersion: _connection.nodeVersion,
      runtimeVersion: _connection.runtimeVersion,
      plugins: <PluginRuntimePlugin>[
        PluginRuntimePlugin(
          activeVersion: plugin.activeVersion,
          contentKinds: plugin.contentKinds,
          displayName: plugin.displayName,
          enabled: enabled,
          id: plugin.id,
          name: plugin.name,
          pendingVersion: plugin.pendingVersion,
          status: enabled ? 'active' : 'disabled',
        ),
      ],
    );
  }
}
