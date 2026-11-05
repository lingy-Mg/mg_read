/// TV source selector sizing and discovery-tab remote traversal.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/app/app_tv_theme.dart';
import 'package:mg_read/features/discovery/presentation/discovery_page.dart';
import 'package:mg_read/features/discovery/presentation/discovery_composite_components.dart';
import 'package:mg_read/shared/presentation/tv_mode_scope.dart';
import 'package:mg_read/shared/presentation/widgets/tv_focusable.dart';
import 'package:mg_read/features/discovery/presentation/runtime_discovery_page.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

void main() {
  for (final size in [const Size(640, 360), const Size(1280, 720), const Size(1920, 1080)]) {
    testWidgets('TV nested category uses the available screen width at $size', (tester) async {
      await tester.binding.setSurfaceSize(size);
      if (size.width == 640) {
        tester.platformDispatcher.textScaleFactorTestValue = 1.6;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      }
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _host(
          RuntimeDiscoveryPage(
            result: PluginDiscoveryDocumentResult(
              pluginId: 'sakura-category',
              sourceName: '樱花动漫',
              document: PluginDiscoveryDocument(
                components: [
                  PluginDiscoveryCategoryCollectionComponent(
                    id: 'genres',
                    layout: PluginDiscoveryCategoryLayout.chips,
                    categories: List.generate(
                      16,
                      (i) => PluginDiscoveryCategory(id: 'genre-$i', title: '动漫分类 $i', target: 'genre:$i', count: null, url: null),
                    ),
                  ),
                ],
              ),
            ),
            onDestinationRequested: (_) {},
            onSourcePressed: () {},
            onTabSelected: (_) {},
            onCategorySelected: (_) {},
            onContentPressed: (_) {},
            onRefreshRequested: () {},
            onLoadMore: (_) {},
            canNavigateBack: true,
            onBackRequested: () {},
            loadingCollectionId: null,
            navigationDepth: 1,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final header = find.byKey(const Key('runtime-discovery-nested-header'));
      final headerTop = tester.getTopLeft(header);
      final category = find.byType(DiscoveryCategoryCollection);
      final rect = tester.getRect(category);
      expect(rect.width, greaterThan(size.width * .85));
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(size.width));
      final first = find.byKey(const ValueKey('runtime-discovery-category-genre-0'));
      final action = find.descendant(of: first, matching: find.byType(TvFocusable)).first;
      tester.widget<Focus>(find.descendant(of: action, matching: find.byType(Focus)).first).focusNode!.requestFocus();
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<TvFocusable>(), isNotNull);
      for (var i = 0; i < 12; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
      }
      expect(tester.getTopLeft(header), headerTop);
      expect(find.byKey(const Key('runtime-discovery-back')).hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('TV horizontal discovery tabs scroll by remote through offscreen items', (tester) async {
    var selected = '';
    await tester.pumpWidget(
      _host(
        RuntimeDiscoveryPage(
          result: PluginDiscoveryDocumentResult(
            pluginId: 'video',
            sourceName: '影视测试源',
            document: PluginDiscoveryDocument(
              components: [
                PluginDiscoveryTabsComponent(
                  id: 'tabs',
                  selectedTabId: '0',
                  tabs: List.generate(30, (i) => PluginDiscoveryTab(id: '$i', label: '分类 $i', target: '$i')),
                ),
              ],
            ),
          ),
          onDestinationRequested: (_) {},
          onSourcePressed: () {},
          onTabSelected: (value) => selected = value,
          onCategorySelected: (_) {},
          onContentPressed: (_) {},
          onRefreshRequested: () {},
          onLoadMore: (_) {},
          canNavigateBack: false,
          navigationDepth: 0,
          onBackRequested: () {},
          loadingCollectionId: null,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final first = find.byKey(const ValueKey('runtime-discovery-tab-0'));
    final focus = tester.widget<Focus>(find.descendant(of: first, matching: find.byType(Focus)).first);
    focus.focusNode!.requestFocus();
    await tester.pumpAndSettle();
    for (var i = 0; i < 29; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
    }
    expect(FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<TvFocusable>(), isNotNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(selected, '29');
    expect(tester.takeException(), isNull);
  });

  testWidgets('TV source and category controls keep enlarged labels inside their targets', (tester) async {
    await tester.pumpWidget(
      _host(
        Column(
          children: [
            DiscoverySourceSelector(sourceName: '影视数据源', onPressed: () {}),
            DiscoveryComponentChip(label: '电影分类', onPressed: () {}),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(const Key('discovery-source-selector'))).height, greaterThanOrEqualTo(52));
    final chip = tester.getRect(find.byType(DiscoveryComponentChip));
    final label = tester.getRect(find.text('电影分类'));
    expect(label.top, greaterThanOrEqualTo(chip.top));
    expect(label.bottom, lessThanOrEqualTo(chip.bottom));
    expect(chip.height, greaterThanOrEqualTo(52));
  });

  testWidgets('TV top bar separates a long title, source selector and actions', (tester) async {
    await tester.binding.setSurfaceSize(const Size(640, 360));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _host(
        DiscoveryTopBar(
          title: '电影与电视剧分类',
          sourceName: '影视数据源',
          onSourcePressed: () {},
          onToggleTheme: () {},
          onSearchPressed: () {},
          onRefreshPressed: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    final title = tester.getRect(find.text('电影与电视剧分类'));
    final selector = tester.getRect(find.byKey(const Key('discovery-source-selector')));
    expect(title.overlaps(selector), isFalse);
    expect(tester.takeException(), isNull);
  });
}

Widget _host(Widget child) => MaterialApp(
  theme: appTvTheme(AppTheme.dark()),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.6)),
    child: TvModeScope(
      enabled: true,
      onChanged: (_) {},
      child: TvRemoteShortcuts(child: child!),
    ),
  ),
  home: Scaffold(body: child),
);
