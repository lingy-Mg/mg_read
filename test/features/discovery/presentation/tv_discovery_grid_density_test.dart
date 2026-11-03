/// TV discovery density, bounded poster height and remote row traversal.
/// Uses the full page so header/footer space participates in the checks.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/app/app_tv_theme.dart';
import 'package:mg_read/features/discovery/presentation/runtime_discovery_page.dart';
import 'package:mg_read/features/discovery/presentation/widgets/discovery_book_cover.dart';
import 'package:mg_read/shared/presentation/tv_mode_scope.dart';
import 'package:mg_read/shared/presentation/widgets/tv_focusable.dart';
import 'package:mg_read/shared/presentation/widgets/app_bottom_navigation.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

void main() {
  setUpAll(() async {
    await (FontLoader(
      'packages/novel_reader_ui/MiSans',
    )..addFont(rootBundle.load('packages/novel_reader_ui/assets/fonts/MiSansVF.ttf'))).load();
    await (FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  for (final size in [const Size(960, 540), const Size(1280, 720)]) {
    for (final scale in [1.0, 1.6]) {
      testWidgets('TV posters fit more than four columns at $size text $scale and navigate by remote', (tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        String? selected;
        await tester.pumpWidget(_host(scale: scale, onPressed: (content) => selected = content.id));
        await tester.pumpAndSettle();

        final first = _tile(0);
        final firstRect = tester.getRect(first);
        final covers = find.byType(DiscoveryBookCover);
        final firstRow = covers.evaluate().where((element) => tester.getTopLeft(find.byWidget(element.widget)).dy == firstRect.top);
        final columns = firstRow.length;
        expect(columns, size.width == 960 ? 6 : 7);
        expect(firstRect.width, lessThanOrEqualTo(156));
        expect(tester.getSize(covers.first).height, lessThanOrEqualTo(216));
        expect(firstRect.top, greaterThanOrEqualTo(tester.getRect(find.byType(AppBottomNavigation)).bottom));
        expect(firstRect.bottom, lessThan(size.height));
        expect(tester.getTopLeft(_tile(columns)).dy, lessThan(size.height));
        if (size.width == 1280 && scale == 1) {
          await expectLater(find.byType(RuntimeDiscoveryPage), matchesGoldenFile('goldens/tv_discovery_compact_posters.png'));
        }

        final action = find.ancestor(of: first, matching: find.byType(TvFocusable)).first;
        tester.widget<Focus>(find.descendant(of: action, matching: find.byType(Focus)).first).focusNode!.requestFocus();
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        expect(selected, 'video-1');
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        expect(selected, 'video-${columns + 1}');
        expect(find.ancestor(of: _tile(columns + 1), matching: find.byType(TvFocusable)).first.hitTestable(), findsOneWidget);
        expect(tester.getRect(_tile(columns + 1)).bottom, lessThanOrEqualTo(size.height));
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('ordinary discovery keeps its four-column layout', (tester) async {
    await tester.binding.setSurfaceSize(const Size(960, 540));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_host(tvMode: false, scale: 1, onPressed: (_) {}));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(_tile(3)).dy, tester.getTopLeft(_tile(0)).dy);
    expect(tester.getTopLeft(_tile(4)).dy, greaterThan(tester.getTopLeft(_tile(0)).dy));
    expect(tester.takeException(), isNull);
  });
}

Finder _tile(int index) => find.byKey(ValueKey('runtime-discovery-cover-video-$index'));

Widget _host({bool tvMode = true, required double scale, required ValueChanged<PluginContentSummary> onPressed}) => ProviderScope(
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: tvMode ? appTvTheme(AppTheme.dark()) : AppTheme.dark(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
      child: TvModeScope(
        enabled: tvMode,
        onChanged: (_) {},
        child: TvRemoteShortcuts(child: child!),
      ),
    ),
    home: RuntimeDiscoveryPage(
      result: PluginDiscoveryDocumentResult(
        pluginId: 'video',
        sourceName: '影视测试源',
        document: PluginDiscoveryDocument(
          components: [
            PluginDiscoverySectionComponent(
              id: 'today',
              title: '今日更新',
              subtitle: '近期更新的影片',
              children: [
                PluginDiscoveryContentCollectionComponent(
                  id: 'posters',
                  layout: PluginDiscoveryContentLayout.coverGrid,
                  items: List.generate(
                    21,
                    (index) => PluginDiscoveryContentItem(
                      content: PluginContentSummary(
                        id: 'video-$index',
                        title: '影片 ${index + 1}',
                        contentKind: PluginContentKind.video,
                        author: null,
                        url: null,
                        coverUrl: null,
                        description: null,
                        language: null,
                        status: PluginContentStatus.ongoing,
                        access: PluginAccessKind.unknown,
                        wordCount: null,
                        chapterCount: null,
                        publishedAt: null,
                        updatedAt: null,
                        latestChapter: null,
                        categories: const [],
                        tags: const [],
                        attributes: const [],
                      ),
                      rank: null,
                      metric: null,
                      recommendation: null,
                    ),
                  ),
                  continuation: null,
                ),
              ],
            ),
          ],
        ),
      ),
      onDestinationRequested: (_) {},
      onSourcePressed: () {},
      onTabSelected: (_) {},
      onCategorySelected: (_) {},
      onContentPressed: onPressed,
      onRefreshRequested: () {},
      onLoadMore: (_) {},
      canNavigateBack: false,
      onBackRequested: () {},
      loadingCollectionId: null,
    ),
  ),
);
