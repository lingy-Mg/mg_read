/// Responsive source installation acceptance using production sheets and themes.
/// Exercises phone gestures and TV-only remote traversal, with local PNG evidence.
/// Viewports simulate layouts; these tests do not claim physical-device acceptance.
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/app/app_tv_theme.dart';
import 'package:mg_read/features/plugins/application/source_collection_import.dart';
import 'package:mg_read/features/plugins/presentation/source_collection_import_sheet.dart';
import 'package:mg_read/shared/presentation/tv_mode_scope.dart';
import 'package:mg_read/shared/presentation/widgets/tv_focusable.dart';

import '../../../support/visual_evidence.dart' show loadVisualEvidenceFonts;

const _boundary = Key('source-install-evidence');
const _cases = <({String name, Size size, double scale, bool tv})>[
  (name: 'phone-small', size: Size(320, 568), scale: 1, tv: false),
  (name: 'phone-safe-area', size: Size(390, 844), scale: 1, tv: false),
  (name: 'phone-large-text', size: Size(320, 568), scale: 2, tv: false),
  (name: 'phone-landscape', size: Size(640, 360), scale: 2, tv: false),
  (name: 'tv-short-large-text', size: Size(640, 360), scale: 1.6, tv: true),
  (name: 'tv-960', size: Size(960, 540), scale: 1, tv: true),
  (name: 'tv-hd-dark', size: Size(1280, 720), scale: 1, tv: true),
  (name: 'tv-fhd', size: Size(1920, 1080), scale: 1, tv: true),
];

void main() {
  setUpAll(loadVisualEvidenceFonts);
  for (final scene in _cases) {
    for (final online in [false, true]) {
      testWidgets('${scene.name} source install (online=$online)', (tester) async {
        SourceCollectionSelection? selection;
        await _open(tester, scene, online, (value) => selection = value);
        if (online) await _capture(tester, '${scene.name}-default');
        _expectFooter(tester);
        if (scene.tv) {
          await _remoteTo(tester, 'source-collection-kind-all', LogicalKeyboardKey.arrowLeft);
          for (final kind in ['novel', 'manga', 'video', 'audio']) {
            await _remoteTo(tester, 'source-collection-kind-$kind', LogicalKeyboardKey.arrowDown);
            await _key(tester, LogicalKeyboardKey.select);
            expect(_focusedKey(), 'source-collection-kind-$kind', reason: 'Changing categories preserves remote focus.');
          }
          if (online) {
            await _remoteTo(tester, 'source-collection-show-r18', LogicalKeyboardKey.arrowDown);
            await _key(tester, LogicalKeyboardKey.select);
          }
          await _remoteTo(tester, 'source-collection-select-all', LogicalKeyboardKey.arrowDown);
          await _key(tester, LogicalKeyboardKey.select);
          if (online) await _capture(tester, '${scene.name}-music-r18');
          await _remoteTo(tester, 'source-collection-cancel', LogicalKeyboardKey.arrowDown);
          await _key(tester, LogicalKeyboardKey.arrowRight);
          expect(_focusedKey(), 'source-collection-import-selected');
          await _key(tester, LogicalKeyboardKey.arrowLeft);
          expect(_focusedKey(), 'source-collection-cancel');
          await _key(tester, LogicalKeyboardKey.arrowRight);
          expect(_focusedKey(), 'source-collection-import-selected');
          await _key(tester, LogicalKeyboardKey.select);
        } else {
          final horizontal = find.ancestor(
            of: find.byKey(const Key('source-collection-kind-audio')),
            matching: find.byType(SingleChildScrollView),
          );
          await tester.drag(horizontal, const Offset(-600, 0));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const Key('source-collection-kind-audio')));
          await tester.pumpAndSettle();
          if (online) await _phoneTap(tester, find.byKey(const Key('source-collection-show-r18')));
          await _phoneTap(tester, find.text('全选可导入'));
          final vertical = find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first;
          await tester.scrollUntilVisible(find.byKey(const Key('source-collection-source-39')), 120, scrollable: vertical, maxScrolls: 120);
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('source-collection-source-39')).hitTestable(), findsOneWidget);
          _expectFooter(tester);
          if (online) await _capture(tester, '${scene.name}-music-r18');
          await tester.tap(find.byKey(const Key('source-collection-import-selected')));
          await tester.pumpAndSettle();
        }
        expect(selection, isNotNull);
        expect(selection!.artifacts.map((item) => item.artifact.pluginId), [for (var i = 3; i < 40; i += 4) 'source-$i', 'adult']);
        expect(tester.takeException(), isNull);
      });
    }
  }
  testWidgets('phone double text keeps a three-digit import count on one line', (tester) async {
    await _open(tester, _cases[2], true, (_) {}, candidates: _catalog(256));
    _expectFooter(tester);
    expect(tester.getSize(find.text('导入 255 项')).height, lessThanOrEqualTo(tester.getSize(find.text('取消')).height + 1));
    await _capture(tester, 'phone-large-text-max-count');
  });

  testWidgets('short TV can opt in from an empty R18-hidden catalog without focusing disabled import', (tester) async {
    SourceCollectionSelection? selection;
    await _open(tester, _cases[4], true, (value) => selection = value, candidates: _catalog(1));
    expect(find.text('当前筛选下暂无数据源'), findsOneWidget);
    expect(find.byKey(const Key('source-collection-adult')), findsNothing);
    await _remoteTo(tester, 'source-collection-cancel', LogicalKeyboardKey.arrowDown);
    await _key(tester, LogicalKeyboardKey.arrowRight);
    expect(_focusedKey(), 'source-collection-cancel');
    await _remoteTo(tester, 'source-collection-show-r18', LogicalKeyboardKey.arrowUp);
    await _key(tester, LogicalKeyboardKey.select);
    await _remoteTo(tester, 'source-collection-select-all', LogicalKeyboardKey.arrowDown);
    await _key(tester, LogicalKeyboardKey.select);
    await _remoteTo(tester, 'source-collection-cancel', LogicalKeyboardKey.arrowDown);
    await _key(tester, LogicalKeyboardKey.arrowRight);
    expect(_focusedKey(), 'source-collection-import-selected');
    await _key(tester, LogicalKeyboardKey.select);
    expect(selection!.artifacts.single.artifact.pluginId, 'adult');
    expect(tester.takeException(), isNull);
  });
}

Future<void> _open(
  WidgetTester tester,
  ({String name, Size size, double scale, bool tv}) scene,
  bool online,
  ValueChanged<SourceCollectionSelection?> onSelected, {
  List<SourceCollectionCandidate>? candidates,
}) async {
  tester.view.physicalSize = scene.size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final safe = scene.name == 'phone-safe-area' ? const EdgeInsets.only(top: 44, bottom: 34) : EdgeInsets.zero;
  final base = scene.name.contains('dark') ? AppTheme.dark() : AppTheme.light();
  await tester.pumpWidget(
    RepaintBoundary(
      key: _boundary,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: scene.tv ? appTvTheme(base) : base,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scene.scale), padding: safe, viewPadding: safe),
          child: TvModeScope(enabled: scene.tv, onChanged: (_) {}, child: child!),
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async =>
                  onSelected(await showSourceCollectionImportSheet(context, candidates ?? _catalog(41), onlineRepository: online)),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}

void _expectFooter(WidgetTester tester) {
  final finder = find.byKey(const Key('source-collection-import-selected'));
  expect(finder.hitTestable(), findsOneWidget);
  final rect = tester.getRect(finder);
  expect(rect.top, greaterThanOrEqualTo(0));
  expect(rect.bottom, lessThanOrEqualTo(tester.view.physicalSize.height));
  expect(tester.takeException(), isNull);
}

Future<void> _phoneTap(WidgetTester tester, Finder finder) async {
  final vertical = find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first;
  await tester.scrollUntilVisible(finder, 80, scrollable: vertical, maxScrolls: 40);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

String? _focusedKey() =>
    (FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<TvFocusable>()?.key as ValueKey<String>?)?.value;

Future<void> _key(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
}

Future<void> _remoteTo(WidgetTester tester, String key, LogicalKeyboardKey direction) async {
  for (var i = 0; i < 50 && _focusedKey() != key; i++) {
    await _key(tester, direction);
  }
  expect(_focusedKey(), key);
  expect(find.byKey(Key(key)).hitTestable(), findsOneWidget, reason: 'Remote focus must reveal the control.');
  _expectFooter(tester);
}

Future<void> _capture(WidgetTester tester, String name) async {
  final error = tester.takeException();
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(_boundary));
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final file = File('.dart_tool/ai-checks/source-install-adaptive/$name${error == null ? '' : '.failed'}.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(data!.buffer.asUint8List());
  });
  expect(error, isNull);
}

List<SourceCollectionCandidate> _catalog(int count) => [
  for (var i = 0; i < count; i++)
    SourceCollectionCandidate(
      plugin: SourceCollectionPlugin(
        id: i == count - 1 ? 'adult' : 'source-$i',
        name: i == count - 1 ? '分级音乐数据源' : '数据源 $i · 用于验证长名称完整布局与分类安装',
        version: '2.0.0',
        format: 'singleFile',
        byteLength: 3,
        checksum: '00000000',
        contentKinds: [
          i == count - 1 ? 'audio' : ['novel', 'manga', 'video', 'audio'][i % 4],
        ],
        r18: i == count - 1,
        openBytes: () => Stream.value([1, 2, 3]),
      ),
      plan: PluginTransferPlanItem(
        action: PluginTransferPlanAction.missing,
        pluginId: i == count - 1 ? 'adult' : 'source-$i',
        version: '2.0.0',
        receiverVersion: null,
      ),
    ),
];
