/// Classification and explicit online R18 disclosure across desktop/mobile/TV.
/// Checks actual submitted artifacts, including bulk selection and filter changes.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/app/app_tv_theme.dart';
import 'package:mg_read/features/plugins/application/source_collection_import.dart';
import 'package:mg_read/features/plugins/presentation/source_collection_import_sheet.dart';
import 'package:mg_read/shared/presentation/tv_mode_scope.dart';

void main() {
  for (final tv in [false, true]) {
    for (final online in [false, true]) {
      testWidgets('filters every type and submits only visible selections (TV=$tv, online=$online)', (tester) async {
        SourceCollectionSelection? selection;
        await _open(tester, tv: tv, online: online, onSelected: (value) => selection = value);
        for (final (kind, ids) in [
          ('novel', ['novel']),
          ('manga', ['manga', 'mixed']),
          ('video', ['video', 'mixed']),
          ('audio', ['audio']),
        ]) {
          await _activate(tester, 'source-collection-kind-$kind', tv);
          for (final id in ['novel', 'manga', 'video', 'audio', 'mixed']) {
            expect(find.byKey(Key('source-collection-$id')), ids.contains(id) ? findsOneWidget : findsNothing);
          }
        }
        await _activate(tester, tv ? 'source-collection-select-all' : null, tv, text: '全选可导入');
        await _activate(tester, 'source-collection-import-selected', tv);
        expect(selection!.artifacts.map((item) => item.artifact.pluginId), ['audio']);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('online R18 is explicit, clears hidden selections and resets when reopened (TV=$tv)', (tester) async {
      SourceCollectionSelection? selection;
      await _open(tester, tv: tv, online: true, onSelected: (value) => selection = value);
      expect(find.byKey(const Key('source-collection-adult')), findsNothing);
      expect(find.byKey(const Key('source-collection-legacy')), findsNothing);
      await _activate(tester, tv ? 'source-collection-select-all' : null, tv, text: '全选可导入');
      expect(find.text('导入 5 项'), findsOneWidget);
      await _activate(tester, 'source-collection-show-r18', tv);
      // Revealing R18 does not automatically select additional sources.
      expect(find.text('导入 5 项'), findsOneWidget);
      await _activate(tester, tv ? 'source-collection-select-all' : null, tv, text: '全选可导入');
      expect(find.text('导入 7 项'), findsOneWidget);
      await _activate(tester, 'source-collection-show-r18', tv);
      expect(find.text('导入 5 项'), findsOneWidget);
      await _activate(tester, 'source-collection-import-selected', tv);
      expect(selection!.artifacts.map((item) => item.artifact.pluginId), ['novel', 'manga', 'video', 'audio', 'mixed']);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('source-collection-adult')), findsNothing);
      expect(find.byKey(const Key('source-collection-legacy')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('explicit R18 opt-in allows importing an R18 source (TV=$tv)', (tester) async {
      SourceCollectionSelection? selection;
      await _open(tester, tv: tv, online: true, onSelected: (value) => selection = value);
      await _activate(tester, 'source-collection-kind-novel', tv);
      await _activate(tester, 'source-collection-show-r18', tv);
      await _activate(tester, tv ? 'source-collection-clear' : null, tv, text: '全不选');
      await _activate(tester, 'source-collection-adult', tv);
      await _activate(tester, 'source-collection-import-selected', tv);
      expect(selection!.artifacts.single.artifact.pluginId, 'adult');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('online filters and confirmation fit a narrow large-text viewport', (tester) async {
    await _open(tester, tv: false, online: true, size: const Size(320, 640), textScale: 2);
    expect(find.byKey(const Key('source-collection-import-selected')).hitTestable(), findsOneWidget);
    await _activate(tester, 'source-collection-kind-audio', false);
    expect(find.byKey(const Key('source-collection-audio')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _open(
  WidgetTester tester, {
  required bool tv,
  required bool online,
  ValueChanged<SourceCollectionSelection?>? onSelected,
  Size size = const Size(1100, 800),
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: tv ? appTvTheme(AppTheme.light()) : AppTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: TvModeScope(enabled: tv, onChanged: (_) {}, child: child!),
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              final result = await showSourceCollectionImportSheet(context, _candidates, onlineRepository: online);
              onSelected?.call(result);
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Future<void> _activate(WidgetTester tester, String? key, bool tv, {String? text}) async {
  final finder = key == null ? find.text(text!) : find.byKey(Key(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  if (tv) {
    final focus = find.descendant(of: finder, matching: find.byType(Focus)).first;
    tester.widget<Focus>(focus).focusNode!.requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
  } else {
    await tester.tap(finder);
  }
  await tester.pumpAndSettle();
}

final _candidates = [
  for (final (id, kinds, r18) in <(String, List<String>, bool?)>[
    ('novel', ['novel'], false),
    ('manga', ['manga'], false),
    ('video', ['video'], false),
    ('audio', ['audio'], false),
    ('mixed', ['manga', 'video'], false),
    ('adult', ['novel'], true),
    ('legacy', [], null),
  ])
    SourceCollectionCandidate(
      plugin: SourceCollectionPlugin(
        id: id,
        name: id,
        version: '1.0.0',
        format: 'singleFile',
        byteLength: 3,
        checksum: '00000000',
        contentKinds: kinds,
        r18: r18,
        openBytes: () => Stream.value([1, 2, 3]),
      ),
      plan: PluginTransferPlanItem(action: PluginTransferPlanAction.missing, pluginId: id, version: '1.0.0', receiverVersion: null),
    ),
];
