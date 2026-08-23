import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';
import 'package:mg_read/features/plugins/presentation/plugin_runtime_source_detail_page.dart';

void main() {
  testWidgets('keeps the shared header visible while detail is loading', (
    WidgetTester tester,
  ) async {
    final completer = Completer<PluginRuntimeConnection>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          pluginRuntimeConnectionProvider.overrideWith(
            (Ref ref) => completer.future,
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: PluginRuntimeSourceDetailPage(
            pluginId: 'org.example.loading',
            onBackRequested: () {},
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('data-source-detail-top-bar')), findsOneWidget);
    expect(find.byKey(const Key('data-source-detail-back')), findsOneWidget);
    expect(find.text('正在读取数据源信息。'), findsOneWidget);

    completer.complete(_installedConnection);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('data-source-detail-top-bar')), findsOneWidget);
  });

  testWidgets(
    'distinguishes a live development source from an installed source',
    (WidgetTester tester) async {
      final gateway = _DirectoryGateway(_developmentConnection);
      await tester.pumpWidget(_host(gateway, 'org.example.live-source'));
      await tester.pumpAndSettle();

      expect(find.text('开源开发源（即时生效）'), findsOneWidget);
      expect(find.text('工作区开源书源'), findsOneWidget);
      expect(find.text('开发中（即时生效）'), findsOneWidget);
      if (Platform.isWindows) {
        expect(find.text('打开开发项目文件夹'), findsOneWidget);
        await tester.tap(
          find.byKey(const Key('data-source-detail-open-directory')),
        );
        await tester.pumpAndSettle();
        expect(gateway.openedPluginIds, <String>['org.example.live-source']);
        expect(find.textContaining('下一次来源调用时生效'), findsOneWidget);
      }
    },
  );

  testWidgets('labels installed source code as a non-live Runtime copy', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _host(_DirectoryGateway(_installedConnection), 'org.example.installed'),
    );
    await tester.pumpAndSettle();

    expect(find.text('已安装数据源'), findsOneWidget);
    expect(find.text('Runtime 已安装版本'), findsOneWidget);
    expect(find.text('已启用'), findsOneWidget);
    expect(find.byKey(const Key('data-source-installation-size-card')), findsOneWidget);
    expect(find.text('安装后大小'), findsOneWidget);
    expect(find.textContaining('整个书源：0 B'), findsOneWidget);
    expect(find.textContaining('数据文件'), findsOneWidget);
    expect(find.textContaining('npm 包'), findsOneWidget);
    if (Platform.isWindows) {
      await tester.drag(
        find.byKey(const Key('data-source-detail-content')),
        const Offset(0, -400),
      );
      await tester.pumpAndSettle();
      expect(find.text('打开已安装源码文件夹'), findsOneWidget);
    }
  });
}

Widget _host(_DirectoryGateway gateway, String pluginId) => ProviderScope(
  overrides: [pluginRuntimeGatewayProvider.overrideWithValue(gateway)],
  child: MaterialApp(
    theme: AppTheme.light(),
    home: PluginRuntimeSourceDetailPage(
      pluginId: pluginId,
      onBackRequested: () {},
    ),
  ),
);

const _developmentConnection = PluginRuntimeConnection(
  isHealthy: true,
  nodeVersion: '24.16.0',
  runtimeVersion: 'test',
  plugins: <PluginRuntimePlugin>[
    PluginRuntimePlugin(
      activeVersion: '0.1.0',
      contentKinds: <String>['novel'],
      displayName: '即时书源',
      enabled: true,
      id: 'org.example.live-source',
      name: '@example/live-source',
      pendingVersion: null,
      status: 'development',
    ),
  ],
);

const _installedConnection = PluginRuntimeConnection(
  isHealthy: true,
  nodeVersion: '24.16.0',
  runtimeVersion: 'test',
  plugins: <PluginRuntimePlugin>[
    PluginRuntimePlugin(
      activeVersion: '1.0.0',
      contentKinds: <String>['novel'],
      displayName: '已安装书源',
      enabled: true,
      id: 'org.example.installed',
      name: '@example/installed',
      pendingVersion: null,
      status: 'active',
    ),
  ],
);

final class _DirectoryGateway implements PluginRuntimeGateway {
  _DirectoryGateway(this.connection);

  final PluginRuntimeConnection connection;
  final List<String> openedPluginIds = <String>[];

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
  Future<PluginRuntimeConnection> inspect() async => connection;

  @override
  Future<bool> importLocalPlugin() async => false;

  @override
  Future<PluginCodeDirectoryKind> openCodeDirectory({
    required String pluginId,
  }) async {
    openedPluginIds.add(pluginId);
    return connection.plugins.single.status == 'development'
        ? PluginCodeDirectoryKind.development
        : PluginCodeDirectoryKind.installed;
  }

  @override
  Future<bool> selectDevelopmentDirectory() async => false;

  @override
  Future<void> setEnabled({
    required String pluginId,
    required bool enabled,
  }) async {}
}
