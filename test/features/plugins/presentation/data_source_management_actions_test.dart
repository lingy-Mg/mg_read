/// 管理页操作流程测试：面板路由、删除确认、导入互斥和窄屏可访问性。
/// 使用窄端口替身，不启动 Runtime 或文件选择器。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';
import 'package:mg_read/features/plugins/application/source_collection_import.dart';
import 'package:mg_read/features/plugins/application/source_plugin_transfer_gateway.dart';
import 'package:mg_read/features/plugins/presentation/data_source_management_sheets.dart';
import 'package:mg_read/features/plugins/presentation/plugin_runtime_help_page.dart';
import 'package:mg_read/features/plugins/presentation/plugin_runtime_status_page.dart';

import 'plugin_runtime_status_page_fixture.dart';

void main() {
  testWidgets('checks online source versions and waits for confirmation before replacing plugins', (tester) async {
    final gateway = _SourceTransferGateway(action: PluginTransferPlanAction.upgrade, receiverVersion: '1.0.0');
    final catalog = _CatalogReader(_catalog('1.1.0'));
    await tester.pumpWidget(_host(_Gateway(), catalog: catalog, sourceTransfers: gateway));
    await tester.pumpAndSettle();

    await _openTools(tester);
    expect(find.byKey(const Key('data-source-check-updates')), findsOneWidget);
    await tester.tap(find.byKey(const Key('data-source-check-updates')));
    await _pumpUntilVisible(tester, find.byKey(const Key('source-updates-confirm-overwrite')));

    expect(catalog.readCount, 1);
    expect(find.text('发现 1 个数据源更新'), findsOneWidget);
    expect(find.text('起点中文网  v1.0.0 → v1.1.0'), findsOneWidget);
    expect(gateway.importCalls, 0);
    await tester.tap(find.text('暂不更新'));
    await tester.pumpAndSettle();
    expect(gateway.importCalls, 0);

    await _openTools(tester);
    await tester.tap(find.byKey(const Key('data-source-check-updates')));
    await _pumpUntilVisible(tester, find.byKey(const Key('source-updates-confirm-overwrite')));
    await tester.tap(find.byKey(const Key('source-updates-confirm-overwrite')));
    await _pumpUntilVisible(tester, find.text('数据源更新完成'));

    expect(catalog.readCount, 2);
    expect(gateway.importCalls, 1);
    expect(gateway.forceUpgradePluginIds, <String>{'org.mgread.qidian'});
    expect(find.text('数据源更新完成'), findsOneWidget);
    expect(find.textContaining('已更新'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reports when all installed sources are current', (tester) async {
    final gateway = _SourceTransferGateway(action: PluginTransferPlanAction.same, receiverVersion: '1.0.0');
    final catalog = _CatalogReader(_catalog('1.0.0'));
    await tester.pumpWidget(_host(_Gateway(), catalog: catalog, sourceTransfers: gateway));
    await tester.pumpAndSettle();

    await _openTools(tester);
    await tester.tap(find.byKey(const Key('data-source-check-updates')));
    await tester.pumpAndSettle();

    expect(catalog.readCount, 1);
    expect(find.text('已检查，当前已安装的数据源均为最新版本。'), findsOneWidget);
    expect(find.byKey(const Key('source-updates-confirm-overwrite')), findsNothing);
    expect(gateway.importCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows Android Runtime failure code and stage when update planning fails', (tester) async {
    final gateway = _SourceTransferGateway(
      action: PluginTransferPlanAction.upgrade,
      receiverVersion: '1.0.0',
      planFailure: const PluginRuntimeException('runtime_unavailable', 'The Android Runtime is not attached.'),
    );
    await tester.pumpWidget(_host(_Gateway(), catalog: _CatalogReader(_catalog('1.1.0')), sourceTransfers: gateway));
    await tester.pumpAndSettle();

    await _openTools(tester);
    await tester.tap(find.byKey(const Key('data-source-check-updates')));
    await _pumpUntilVisible(tester, find.textContaining('错误代码：runtime_unavailable'));

    expect(find.textContaining('检查本机已安装版本'), findsOneWidget);
    expect(find.textContaining('The Android Runtime is not attached.'), findsOneWidget);
    expect(gateway.importCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tools route to diagnostics and help after closing the sheet', (tester) async {
    var diagnostics = 0;
    await tester.pumpWidget(_host(_Gateway(), onDiagnostics: () => diagnostics++));
    await tester.pumpAndSettle();
    await _openTools(tester);
    await tester.tap(find.byKey(const Key('data-source-runtime-status')));
    await tester.pumpAndSettle();
    expect(diagnostics, 1);
    expect(find.text('数据源工具'), findsNothing);
    await _openTools(tester);
    await tester.tap(find.byKey(const Key('data-source-management-help')));
    await tester.pumpAndSettle();
    expect(find.byType(PluginRuntimeHelpPage), findsOneWidget);
  });

  testWidgets('uninstall requires confirmation and blocks import while pending', (tester) async {
    final gateway = _Gateway();
    await tester.pumpWidget(_host(gateway));
    await tester.pumpAndSettle();
    await _openTools(tester);
    await tester.tap(find.byKey(const Key('data-source-clear-all')));
    await tester.pumpAndSettle();
    expect(find.textContaining('将删除 6 个'), findsOneWidget);
    expect(gateway.removals, 0);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(gateway.removals, 0);
    await _openTools(tester);
    await tester.tap(find.byKey(const Key('data-source-clear-all')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('data-source-clear-all-confirm')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(gateway.removals, 1);
    expect(tester.widget<TextButton>(find.byKey(const Key('data-source-add'))).onPressed, isNull);
    gateway.removal.complete();
    await tester.pumpAndSettle();
    expect(find.text('已卸载 6 个本地数据源。'), findsOneWidget);
    expect(tester.widget<TextButton>(find.byKey(const Key('data-source-add'))).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('import chooser cancellation is inert and pending import disables destructive actions', (tester) async {
    final gateway = _Gateway();
    await tester.pumpWidget(_host(gateway));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('data-source-add')));
    await tester.pumpAndSettle();
    expect(gateway.imports, 0);
    Navigator.of(tester.element(find.text('Node 数据源'))).pop();
    await tester.pumpAndSettle();
    expect(gateway.imports, 0);
    await tester.tap(find.byKey(const Key('data-source-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('data-source-add-node')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(gateway.imports, 1);
    expect(tester.widget<TextButton>(find.byKey(const Key('data-source-add'))).onPressed, isNull);
    await _openTools(tester, settling: false);
    expect(tester.widget<ListTile>(find.byKey(const Key('data-source-clear-all'))).onTap, isNull);
    expect(tester.widget<ListTile>(find.byKey(const Key('data-source-verify-all'))).onTap, isNull);
    gateway.importing.complete(false);
    await tester.pumpAndSettle();
    expect(tester.widget<ListTile>(find.byKey(const Key('data-source-clear-all'))).onTap, isNotNull);
    expect(tester.widget<ListTile>(find.byKey(const Key('data-source-verify-all'))).onTap, isNotNull);
    Navigator.of(tester.element(find.text('数据源工具'))).pop();
    await tester.pumpAndSettle();
    expect(find.text('数据源已添加。'), findsNothing);
    expect(tester.widget<TextButton>(find.byKey(const Key('data-source-add'))).onPressed, isNotNull);
  });

  testWidgets('native import choice returns the native intent', (tester) async {
    DataSourceImportChoice? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(onPressed: () async => result = await showDataSourceImportSheet(context), child: const Text('open')),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('data-source-add-native')));
    await tester.pumpAndSettle();
    expect(result, DataSourceImportChoice.native);
  });

  testWidgets('add-data-source chooser exposes Node collection import', (tester) async {
    DataSourceImportChoice? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(onPressed: () async => result = await showDataSourceImportSheet(context), child: const Text('open')),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('data-source-add-collection')), findsOneWidget);
    await tester.tap(find.byKey(const Key('data-source-add-collection')));
    await tester.pumpAndSettle();
    expect(result, DataSourceImportChoice.collection);
  });

  testWidgets('add-data-source chooser exposes the online plugin repository', (tester) async {
    DataSourceImportChoice? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(onPressed: () async => result = await showDataSourceImportSheet(context), child: const Text('open')),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('data-source-add-online-repository')));
    await tester.pumpAndSettle();
    expect(result, DataSourceImportChoice.onlineRepository);
  });

  testWidgets('320dp large text keeps header clear and all tools reachable', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(_host(_Gateway(), textScale: 2));
    await tester.pumpAndSettle();
    final title = tester.getRect(find.text('数据源'));
    expect(title.left, greaterThan(tester.getRect(find.byKey(const Key('profile-detail-back'))).right));
    expect(title.right, lessThan(tester.getRect(find.byKey(const Key('data-source-more'))).left));
    expect(tester.takeException(), isNull);
    await _openTools(tester);
    await tester.ensureVisible(find.byKey(const Key('data-source-clear-all')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('data-source-clear-all')).hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    Navigator.of(tester.element(find.text('数据源工具'))).pop();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('data-source-add')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('data-source-add-native')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('data-source-add-native')).hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _openTools(WidgetTester tester, {bool settling = true}) async {
  await tester.tap(find.byKey(const Key('data-source-more')));
  if (settling) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }
}

Future<void> _pumpUntilVisible(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; attempt < 40; attempt++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isNotEmpty) return;
  }
  fail('Timed out waiting for ${finder.toString()}.');
}

Widget _host(
  _Gateway gateway, {
  VoidCallback? onDiagnostics,
  double textScale = 1,
  OnlineSourceCatalogReader? catalog,
  SourcePluginTransferGateway? sourceTransfers,
}) => ProviderScope(
  overrides: [
    pluginRuntimeGatewayProvider.overrideWithValue(gateway),
    pluginRuntimeConnectionProvider.overrideWith((ref) async => dataSourceManagementFixture),
    if (catalog != null) onlineSourceCatalogServiceProvider.overrideWithValue(catalog),
    if (sourceTransfers != null) sourcePluginTransferGatewayProvider.overrideWithValue(sourceTransfers),
  ],
  child: MaterialApp(
    theme: AppTheme.light(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: PluginRuntimeStatusPage(
      onBackRequested: () {},
      onDestinationRequested: (_) {},
      onVerifyAllRequested: () {},
      onRuntimeStatusRequested: onDiagnostics,
    ),
  ),
);

class _Gateway implements PluginRuntimeGateway {
  int imports = 0;
  int removals = 0;
  final importing = Completer<bool>();
  final removal = Completer<void>();

  @override
  Stream<RuntimeInitializationProgress> get initialization => const Stream.empty();

  @override
  Future<bool> importLocalPlugin() {
    imports++;
    return importing.future;
  }

  @override
  Future<void> uninstallAll() {
    removals++;
    return removal.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CatalogReader implements OnlineSourceCatalogReader {
  _CatalogReader(this.collection);

  final SourceCollection collection;
  int readCount = 0;

  @override
  Future<SourceCollection> loadCatalog() async {
    readCount++;
    return collection;
  }
}

SourceCollection _catalog(String version) => SourceCollection(<SourceCollectionPlugin>[
  SourceCollectionPlugin(
    id: 'org.mgread.qidian',
    name: '起点中文网',
    version: version,
    format: 'singleFile',
    byteLength: 3,
    checksum: '00000000',
    openBytes: () => Stream<List<int>>.value(<int>[1, 2, 3]),
  ),
]);

class _SourceTransferGateway implements SourcePluginTransferGateway {
  _SourceTransferGateway({required this.action, required this.receiverVersion, this.planFailure});

  final PluginTransferPlanAction action;
  final String receiverVersion;
  final Object? planFailure;
  int importCalls = 0;
  Set<String> forceUpgradePluginIds = const <String>{};

  @override
  Future<List<PluginTransferPlanItem>> plan(List<PluginTransferArtifact> artifacts) async {
    if (planFailure != null) throw planFailure!;
    return <PluginTransferPlanItem>[
      for (final artifact in artifacts)
        PluginTransferPlanItem(action: action, pluginId: artifact.pluginId, receiverVersion: receiverVersion, version: artifact.version),
    ];
  }

  @override
  Future<List<PluginTransferImportResult>> importArtifacts(
    List<({PluginTransferArtifact artifact, Stream<List<int>> bytes})> artifacts, {
    Set<String> forceUpgradePluginIds = const <String>{},
  }) async {
    importCalls++;
    this.forceUpgradePluginIds = forceUpgradePluginIds;
    return <PluginTransferImportResult>[
      for (final item in artifacts)
        PluginTransferImportResult(
          pluginId: item.artifact.pluginId,
          status: PluginTransferImportStatus.installed,
          version: item.artifact.version,
        ),
    ];
  }
}
