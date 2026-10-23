/// Widget tests for explicit source replacement and collection selection.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/plugins/application/source_collection_import.dart';
import 'package:mg_read/features/plugins/presentation/source_collection_import_sheet.dart';

void main() {
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
    expect((newSource.subtitle! as Text).data, contains('可用版本 v1.0.0'));
    final installedSource = tester.widget<CheckboxListTile>(find.byKey(const Key('source-collection-org.example.same')));
    expect((installedSource.subtitle! as Text).data, contains('当前 v1.0.0 → 可用 v1.0.0'));
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
