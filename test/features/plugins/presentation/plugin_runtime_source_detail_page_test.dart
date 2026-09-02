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
  testWidgets('keeps the shared header visible while detail is loading', (WidgetTester tester) async {
    final completer = Completer<PluginRuntimeConnection>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [pluginRuntimeConnectionProvider.overrideWith((Ref ref) => completer.future)],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: PluginRuntimeSourceDetailPage(pluginId: 'org.example.loading', onBackRequested: () {}),
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

  testWidgets('distinguishes a live development source from an installed source', (WidgetTester tester) async {
    final gateway = _DirectoryGateway(_developmentConnection);
    await tester.pumpWidget(_host(gateway, 'org.example.live-source'));
    await tester.pumpAndSettle();

    expect(find.text('开发数据源插件（即时生效）'), findsOneWidget);
    expect(find.text('工作区开发数据源插件'), findsOneWidget);
    expect(find.text('开发中（即时生效）'), findsOneWidget);
    if (Platform.isWindows) {
      await tester.scrollUntilVisible(find.byKey(const Key('data-source-detail-open-directory')), 200, scrollable: find.byType(Scrollable));
      expect(find.byKey(const Key('data-source-detail-package-development')), findsOneWidget);
      expect(find.text('打开开发项目文件夹'), findsOneWidget);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('data-source-detail-open-directory')));
      await tester.pumpAndSettle();
      expect(gateway.openedPluginIds, <String>['org.example.live-source']);
      expect(find.textContaining('下一次数据源调用时生效'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('data-source-detail-package-development')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('data-source-detail-package-development')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(gateway.packagedPluginIds, <String>['org.example.live-source']);
    }
  });

  testWidgets('labels installed source code as a non-live Runtime copy', (WidgetTester tester) async {
    final gateway = _DirectoryGateway(_installedConnection);
    String? verifiedPluginId;
    await tester.pumpWidget(_host(gateway, 'org.example.installed', onVerificationRequested: (pluginId) => verifiedPluginId = pluginId));
    await tester.pumpAndSettle();

    expect(find.text('已安装数据源插件'), findsOneWidget);
    expect(find.text('数据源简介'), findsOneWidget);
    expect(find.text('已安装数据源简介。'), findsOneWidget);
    expect(find.text('Runtime 已安装数据源插件'), findsOneWidget);
    expect(find.text('已启用'), findsOneWidget);
    expect(find.byKey(const Key('data-source-installation-size-card')), findsOneWidget);
    expect(find.text('安装后大小'), findsOneWidget);
    expect(find.textContaining('整个数据源插件：0 B'), findsOneWidget);
    expect(find.textContaining('原始安装包'), findsOneWidget);
    expect(find.textContaining('数据文件'), findsOneWidget);
    expect(find.textContaining('npm 包'), findsOneWidget);
    await tester.scrollUntilVisible(find.byKey(const Key('data-source-detail-verify')), 200, scrollable: find.byType(Scrollable));
    expect(find.byKey(const Key('data-source-detail-verify')), findsOneWidget);
    await tester.tap(find.byKey(const Key('data-source-detail-verify')));
    expect(verifiedPluginId, 'org.example.installed');
    await tester.drag(find.byKey(const Key('data-source-detail-content')), const Offset(0, -400));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('data-source-detail-remove')));
    await tester.pumpAndSettle();
    expect(find.text('删除数据源？'), findsOneWidget);
    await tester.tap(find.byKey(const Key('data-source-detail-remove-confirm')));
    await tester.pumpAndSettle();
    expect(gateway.scheduledUninstallPluginIds, <String>['org.example.installed']);
    expect(find.textContaining('已安排删除'), findsOneWidget);
    if (Platform.isWindows) {
      await tester.drag(find.byKey(const Key('data-source-detail-content')), const Offset(0, -400));
      await tester.pumpAndSettle();
      expect(find.text('打开已安装源码文件夹'), findsOneWidget);
    }
  });

  testWidgets('uses the Runtime icon URL on the secondary detail page', (WidgetTester tester) async {
    final gateway = _DirectoryGateway(_iconConnection);
    await tester.pumpWidget(_host(gateway, 'org.example.with-icon'));
    await tester.pumpAndSettle();

    final Image image = tester.widget<Image>(find.byKey(const Key('source-icon-network-org.example.with-icon')));
    expect(
      image.image,
      isA<NetworkImage>().having((NetworkImage provider) => provider.url, 'url', 'http://127.0.0.1:1/v1/plugin-icon/detail-test-token'),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('keeps long metadata values readable on a phone-width viewport', (WidgetTester tester) async {
    final gateway = _DirectoryGateway(_longMetadataConnection);
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(_host(gateway, 'org.mgread.discovery-demo'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('0.1.3-devsync.1787755401237'), findsOneWidget);
    expect(find.text('org.mgread.discovery-demo'), findsOneWidget);
    expect(tester.getSize(find.text('0.1.3-devsync.1787755401237')).height, lessThan(64));
  });
}

Widget _host(_DirectoryGateway gateway, String pluginId, {ValueChanged<String>? onVerificationRequested}) => ProviderScope(
  overrides: [
    pluginRuntimeGatewayProvider.overrideWithValue(gateway),
    pluginRuntimeConnectionProvider.overrideWith((Ref ref) async => gateway.connection),
  ],
  child: MaterialApp(
    theme: AppTheme.light(),
    home: PluginRuntimeSourceDetailPage(pluginId: pluginId, onBackRequested: () {}, onVerificationRequested: onVerificationRequested),
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
      description: '即时开发数据源插件简介。',
      displayName: '即时数据源',
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
      description: '已安装数据源简介。',
      displayName: '已安装数据源',
      enabled: true,
      id: 'org.example.installed',
      name: '@example/installed',
      pendingVersion: null,
      status: 'active',
    ),
  ],
);

const _longMetadataConnection = PluginRuntimeConnection(
  isHealthy: true,
  nodeVersion: '24.16.0',
  runtimeVersion: 'test',
  plugins: <PluginRuntimePlugin>[
    PluginRuntimePlugin(
      activeVersion: '0.1.3-devsync.1787755401237',
      contentKinds: <String>['novel'],
      description: '长文本布局测试。',
      displayName: '发现组件演示',
      enabled: true,
      id: 'org.mgread.discovery-demo',
      name: '@mgread/discovery-demo',
      pendingVersion: null,
      status: 'active',
    ),
  ],
);

const _iconConnection = PluginRuntimeConnection(
  isHealthy: true,
  nodeVersion: '24.16.0',
  runtimeVersion: 'test',
  plugins: <PluginRuntimePlugin>[
    PluginRuntimePlugin(
      activeVersion: '1.0.0',
      contentKinds: <String>['novel'],
      description: '带图标的数据源。',
      displayName: '带图数据源',
      enabled: true,
      iconUrl: 'http://127.0.0.1:1/v1/plugin-icon/detail-test-token',
      id: 'org.example.with-icon',
      name: '@example/with-icon',
      pendingVersion: null,
      status: 'active',
    ),
  ],
);

final class _DirectoryGateway implements PluginRuntimeGateway {
  _DirectoryGateway(this.connection);

  final PluginRuntimeConnection connection;
  final List<String> openedPluginIds = <String>[];
  final List<String> packagedPluginIds = <String>[];
  final List<String> scheduledUninstallPluginIds = <String>[];

  @override
  Stream<RuntimeInitializationProgress> get initialization => const Stream<RuntimeInitializationProgress>.empty();

  @override
  Future<PluginInstallationSize> inspectInstallationSize({required String pluginId, required PluginInstallationSizeScope scope}) async =>
      PluginInstallationSize(bytes: 0, fileCount: 0, pluginId: pluginId, scope: scope, version: 'test');

  @override
  Future<PluginRuntimeConnection> inspect() async => connection;

  @override
  Future<bool> importLocalPlugin() async => false;

  @override
  Future<String?> packageDevelopmentPlugin({required String pluginId}) async {
    packagedPluginIds.add(pluginId);
    return '$pluginId-0.1.0.mgplugin.js';
  }

  @override
  Future<PluginCodeDirectoryKind> openCodeDirectory({required String pluginId}) async {
    openedPluginIds.add(pluginId);
    return connection.plugins.single.status == 'development' ? PluginCodeDirectoryKind.development : PluginCodeDirectoryKind.installed;
  }

  @override
  Future<void> openRuntimePrivateDirectory() async {}

  @override
  Future<PluginRuntimeDebugHttp> setDebugHttpEnabled(bool enabled) async => const PluginRuntimeDebugHttp.disabled();

  @override
  Future<PluginRuntimeDebugHttp> inspectDebugHttp() async => const PluginRuntimeDebugHttp.disabled();

  @override
  Future<bool> selectDevelopmentDirectory() async => false;

  @override
  Future<void> setEnabled({required String pluginId, required bool enabled}) async {}

  @override
  Future<void> scheduleUninstall({required String pluginId}) async {
    scheduledUninstallPluginIds.add(pluginId);
  }

  @override
  Future<void> controlSourceWebView({
    required String pluginId,
    required String pluginName,
    required PluginWebViewDebugAction action,
  }) async {}
}
