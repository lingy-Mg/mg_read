/// TV picker layout, keyboard focus and remote selection with local descriptors.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/app/app_tv_theme.dart';
import 'package:mg_read/shared/presentation/tv_mode_scope.dart';
import 'package:mg_read/features/discovery/presentation/source_picker_sheet.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

void main() {
  testWidgets('pinning and unpinning keeps the same source control focused and visible', (tester) async {
    await tester.binding.setSurfaceSize(const Size(960, 540));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: appTvTheme(AppTheme.dark()),
        builder: (_, child) => TvModeScope(
          enabled: true,
          onChanged: (_) {},
          child: TvRemoteShortcuts(child: child!),
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () => showDiscoverySourcePicker(
                context,
                sources: [
                  for (var i = 0; i < 30; i++)
                    PluginSourceDescriptor(id: 'source-$i', displayName: '来源$i', contentKinds: const [PluginContentKind.video]),
                ],
                selectedSourceId: 'source-0',
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    final pin = find.byKey(const ValueKey('discovery-source-picker-pin-source-20'));
    await tester.scrollUntilVisible(
      pin,
      300,
      scrollable: find.descendant(of: find.byKey(const Key('tv-source-picker-scroll')), matching: find.byType(Scrollable)).first,
    );
    await tester.pumpAndSettle();
    Focus.of(tester.element(find.descendant(of: pin, matching: find.byType(Icon)))).requestFocus();
    await tester.pumpAndSettle();
    final focus = FocusManager.instance.primaryFocus;
    for (var i = 0; i < 2; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus, same(focus));
      expect(pin.hitTestable(), findsOneWidget);
      expect(tester.widget<IconButton>(pin).tooltip, i == 0 ? '取消置顶' : '置顶');
    }
    final menu = find.byKey(const ValueKey('discovery-source-picker-actions-source-20'));
    Focus.of(tester.element(find.descendant(of: menu, matching: find.byType(Icon)).first)).requestFocus();
    await tester.pumpAndSettle();
    final menuFocus = FocusManager.instance.primaryFocus;
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.text('置顶'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(tester.widget<IconButton>(pin).tooltip, '取消置顶');
    expect(FocusManager.instance.primaryFocus, same(menuFocus));
    expect(menu.hitTestable(), findsOneWidget);
  });

  setUpAll(() async {
    await (FontLoader(
      'packages/novel_reader_ui/MiSans',
    )..addFont(rootBundle.load('packages/novel_reader_ui/assets/fonts/MiSansVF.ttf'))).load();
    await (FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  for (final keyboardHeight in [0.0, 140.0]) {
    testWidgets('TV source picker keeps its list reachable with large text and keyboard=$keyboardHeight', (tester) async {
      DiscoverySourcePickerResult? selected;
      tester.view.physicalSize = const Size(640, 360);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: appTvTheme(AppTheme.dark()),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.6)),
            child: TvModeScope(
              enabled: true,
              onChanged: (_) {},
              child: TvRemoteShortcuts(child: child!),
            ),
          ),
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                autofocus: true,
                onPressed: () async {
                  selected = await showDiscoverySourcePicker(
                    context,
                    allowAllSources: true,
                    sources: [
                      PluginSourceDescriptor(
                        id: 'video',
                        displayName: '影视测试源',
                        description: '电影与电视剧',
                        contentKinds: const [PluginContentKind.video],
                      ),
                    ],
                    selectedSourceId: 'video',
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const Key('discovery-source-picker-search-toggle')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final field = find.byKey(const Key('discovery-source-picker-search'));
      await tester.enterText(field, '影视');
      tester.view.viewInsets = FakeViewPadding(bottom: keyboardHeight);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(tester.widget<EditableText>(find.descendant(of: field, matching: find.byType(EditableText))).focusNode.hasFocus, isFalse);
      final source = find.byKey(const ValueKey('discovery-source-picker-video'));
      for (var i = 0; i < 8; i++) {
        final focused = FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<InkWell>();
        if (focused?.key == const ValueKey('discovery-source-picker-video')) break;
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
      }
      expect(source.hitTestable(), findsOneWidget);
      expect(tester.getRect(source).bottom, lessThanOrEqualTo(360 - keyboardHeight));
      if (keyboardHeight == 0) {
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/tv_source_picker_short_large_text.png'));
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(selected, isA<DiscoverySourceSelected>().having((s) => s.sourceId, 'source', 'video'));
    });
  }
}
