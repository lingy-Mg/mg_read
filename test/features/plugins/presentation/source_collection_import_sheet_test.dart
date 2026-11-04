/// Widget tests for explicit source replacement and collection selection.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/app/app_tv_theme.dart';
import 'package:mg_read/shared/presentation/tv_mode_scope.dart';
import 'package:mg_read/shared/presentation/widgets/tv_focusable.dart';
import 'package:mg_read/features/plugins/application/source_collection_import.dart';
import 'package:mg_read/features/plugins/presentation/source_collection_import_sheet.dart';

void main() {
  testWidgets('TV remote visits every source in a long catalog before reaching the footer', (tester) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final candidates = List.generate(
      30,
      (i) => SourceCollectionCandidate(
        plugin: SourceCollectionPlugin(
          id: 'source-$i',
          name: '数据源 $i',
          version: '1.0.0',
          format: 'singleFile',
          byteLength: 3,
          checksum: '00000000',
          openBytes: () => Stream.value([1, 2, 3]),
        ),
        plan: PluginTransferPlanItem(
          action: i == 15 ? PluginTransferPlanAction.receiverNewer : PluginTransferPlanAction.missing,
          pluginId: 'source-$i',
          receiverVersion: i == 15 ? '2.0.0' : null,
          version: '1.0.0',
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: appTvTheme(AppTheme.light()),
        builder: (_, child) => TvModeScope(enabled: true, onChanged: (_) {}, child: child!),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showSourceCollectionImportSheet(context, candidates, onlineRepository: true),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final visited = <String>{};
    for (var i = 0; i < 34; i++) {
      final key = FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<TvFocusable>()?.key;
      if (key is ValueKey<String> && key.value.startsWith('source-collection-source-')) visited.add(key.value);
      if (key == const Key('source-collection-source-15')) {
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await tester.pumpAndSettle();
        expect(tester.widget<TvFocusable>(find.byKey(key!)).selected, isFalse, reason: 'a blocked row is readable but never selectable');
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
    }
    expect(visited, hasLength(30));
    expect(find.byKey(const Key('source-collection-cancel')).hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('TV online selection scrolls by remote and keeps confirmation visible with large text', (tester) async {
    tester.view.physicalSize = const Size(640, 360);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    SourceCollectionSelection? selection;
    await tester.pumpWidget(
      MaterialApp(
        theme: appTvTheme(AppTheme.light()),
        builder: (_, child) => TvModeScope(onChanged: (_) async {}, enabled: true, child: child!),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async => selection = await showSourceCollectionImportSheet(context, _candidates(), onlineRepository: true),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    for (var i = 0; i < 8; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('source-collection-import-selected')).hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    final focused = FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<TvFocusable>();
    expect(focused?.key, anyOf(const Key('source-collection-cancel'), const Key('source-collection-import-selected')));
    if (focused?.key == const Key('source-collection-cancel')) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(selection, isNotNull);
    expect(selection!.artifacts.map((item) => item.artifact.pluginId), ['org.example.new']);
  });
  testWidgets('collection selector fits a narrow large-text viewport', (tester) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async => await showSourceCollectionImportSheet(context, _candidates()),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final same = tester.widget<CheckboxListTile>(find.byKey(const Key('source-collection-org.example.same')));
    expect(same.value, isFalse);
    expect(same.onChanged, isNotNull);
    expect(find.byKey(const Key('source-collection-import-selected')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('online catalog selector labels versions as install or update choices', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async => await showSourceCollectionImportSheet(context, _candidates(), onlineRepository: true),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('在线插件仓库'), findsOneWidget);
    final newSource = tester.widget<CheckboxListTile>(find.byKey(const Key('source-collection-org.example.new')));
    expect(((newSource.subtitle! as Padding).child as Text).data, '仓库版本 v1.0.0');
    final installedSource = tester.widget<CheckboxListTile>(find.byKey(const Key('source-collection-org.example.same')));
    expect(((installedSource.subtitle! as Padding).child as Text).data, contains('已是最新版本'));
    expect(find.text('有更新'), findsOneWidget);
    expect(find.text('未安装'), findsOneWidget);
    expect(find.textContaining('devsync'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('update confirmation lists old and new versions and waits for acceptance', (tester) async {
    var confirmed = false;
    final updates = sourceCollectionAvailableUpdates(_candidates());
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async => confirmed = await showSourceUpdatesConfirmationDialog(context, updates),
              child: const Text('check'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('check'));
    await tester.pumpAndSettle();

    expect(find.text('发现 1 个数据源更新'), findsOneWidget);
    expect(find.text('org.example.upgrade  v1.0.0 → v2.0.0'), findsOneWidget);
    expect(confirmed, isFalse);
    await tester.tap(find.byKey(const Key('source-updates-confirm-overwrite')));
    await tester.pumpAndSettle();
    expect(confirmed, isTrue);
    expect(tester.takeException(), isNull);
  });
}

List<SourceCollectionCandidate> _candidates() {
  final bytes = Uint8List.fromList(<int>[1, 2, 3]);
  SourceCollectionPlugin plugin(String id, String version) => SourceCollectionPlugin(
    id: id,
    name: id,
    version: version,
    format: 'singleFile',
    byteLength: bytes.length,
    checksum: '00000000',
    openBytes: () => Stream<List<int>>.value(bytes),
  );
  return <SourceCollectionCandidate>[
    SourceCollectionCandidate(
      plugin: plugin('org.example.new', '1.0.0'),
      plan: const PluginTransferPlanItem(
        action: PluginTransferPlanAction.missing,
        pluginId: 'org.example.new',
        receiverVersion: null,
        version: '1.0.0',
      ),
    ),
    SourceCollectionCandidate(
      plugin: plugin('org.example.same', '1.0.0'),
      plan: const PluginTransferPlanItem(
        action: PluginTransferPlanAction.same,
        pluginId: 'org.example.same',
        receiverVersion: '1.0.0',
        version: '1.0.0',
      ),
      installedName: 'same',
    ),
    SourceCollectionCandidate(
      plugin: plugin('org.example.upgrade', '2.0.0-devsync.1790432259114.6a91949aea'),
      plan: const PluginTransferPlanItem(
        action: PluginTransferPlanAction.upgrade,
        pluginId: 'org.example.upgrade',
        receiverVersion: '1.0.0',
        version: '2.0.0-devsync.1790432259114.6a91949aea',
      ),
      installedName: 'upgrade',
    ),
    SourceCollectionCandidate(
      plugin: plugin('org.example.old', '1.0.0'),
      plan: const PluginTransferPlanItem(
        action: PluginTransferPlanAction.receiverNewer,
        pluginId: 'org.example.old',
        receiverVersion: '2.0.0',
        version: '1.0.0',
      ),
      installedName: 'old',
    ),
  ];
}
