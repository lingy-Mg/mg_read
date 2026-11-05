/// TV 搜索到详情、来源版本与长简介的遥控回归；固定本地网关，不访问网络或正式数据。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/app/app_tv_theme.dart';
import 'package:mg_read/features/discovery/application/batch_search.dart';
import 'package:mg_read/features/discovery/application/search_history_store.dart';
import 'package:mg_read/features/discovery/application/search_page_state.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/discovery/presentation/search_page.dart';
import 'package:mg_read/features/discovery/presentation/source_content_detail_sheet.dart';
import 'package:mg_read/features/discovery/presentation/source_content_detail_variant_picker.dart';
import 'package:mg_read/features/discovery/presentation/widgets/search_page_sections.dart';
import 'package:mg_read/features/discovery/presentation/widgets/tv_discovery_workspace.dart';
import 'package:mg_read/shared/presentation/tv_mode_scope.dart';
import 'package:mg_read/shared/presentation/widgets/tv_focusable.dart';
import '../../../support/tv_media_test_fixture.dart';

void main() {
  setUpAll(() async {
    await (FontLoader(
      'packages/novel_reader_ui/MiSans',
    )..addFont(rootBundle.load('packages/novel_reader_ui/assets/fonts/MiSansVF.ttf'))).load();
    await (FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  for (final size in [const Size(1280, 720), const Size(640, 360)]) {
    testWidgets('TV search opens detail and restores its result focus at $size', (tester) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final history = _History();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [sourceContentGatewayProvider.overrideWithValue(_Gateway()), searchHistoryStoreProvider.overrideWithValue(history)],
          child: _app(
            SearchPage(
              onDestinationRequested: (_) {},
              onVideoEpisodeRequested: ({required detail, required firstCatalogPage, required chapter}) async {},
            ),
            scale: size.width == 640 ? 1.6 : 1,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _activate(tester, find.byKey(const ValueKey('tv-search-history-电影')));
      expect(history.values.first, '电影');
      expect(find.byKey(const Key('source-search-results')), findsOneWidget);
      if (size.width == 1280) await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/tv_search_results_dark.png'));
      final card = find.byKey(const ValueKey('search-result-show-0'));
      await tester.ensureVisible(card);
      await _focus(tester, card);
      final focus = FocusManager.instance.primaryFocus;
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tv-detail-catalog-scroll')), findsOneWidget);
      if (size.width == 1280) await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/tv_content_detail_dark.png'));
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus, same(focus));
      expect(card.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('TV result sort, partial retry and paging use their existing callbacks', (tester) async {
    await tester.binding.setSurfaceSize(const Size(960, 540));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var retries = 0;
    var pages = 0;
    SearchResultSortOrder? sorted;
    final hit = SourceSearchHit(source: _source, content: _content(0), sourceIndex: 0, sourceRank: 0);
    final result = AggregatedSearchResult(
      query: '电影',
      items: [
        AggregatedSearchItem(key: 'show', primary: hit, variants: [hit], score: 1),
      ],
      sourceStates: [
        BatchSearchSourceState(source: _source, status: BatchSearchSourceStatus.success, hits: [hit], nextCursor: 'next', totalCount: 10),
        BatchSearchSourceState(
          source: _otherSource,
          status: BatchSearchSourceStatus.failure,
          hits: const [],
          nextCursor: null,
          totalCount: null,
        ),
      ],
    );
    await tester.pumpWidget(
      _app(
        Scaffold(
          body: SingleChildScrollView(
            child: SearchResultsSection(
              result: result,
              status: SearchPageStatus.loaded,
              query: '电影',
              error: null,
              sortOrder: SearchResultSortOrder.relevance,
              onSortOrderChanged: (value) => sorted = value,
              onContentPressed: (_) {},
              onRetry: () => retries++,
              onLoadMore: () => pages++,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _activate(tester, find.byKey(const Key('search-result-sort')));
    await _activate(tester, find.widgetWithText(TvFocusable, '文字排序'));
    expect(sorted, SearchResultSortOrder.title);
    await _activate(tester, find.byKey(const Key('tv-search-retry')));
    expect(retries, 1);
    final more = find.byKey(const Key('search-load-more'));
    await tester.ensureVisible(more);
    await _activate(tester, more);
    expect(pages, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('TV full description scrolls to the end and closes back to its launcher', (tester) async {
    await tester.binding.setSurfaceSize(const Size(640, 360));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => Scaffold(
            body: TvFocusable(
              autofocus: true,
              onPressed: () =>
                  showTvDiscoveryText(context, title: '完整简介', text: List.generate(40, (i) => '第 $i 段完整介绍，保留所有来源文字。').join('\n')),
              child: const Text('展开简介'),
            ),
          ),
        ),
        scale: 1.6,
      ),
    );
    await tester.pumpAndSettle();
    final before = FocusManager.instance.primaryFocus;
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.text('关闭').hitTestable(), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    for (var i = 0; i < 40; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
    }
    final scroll = tester.widget<SingleChildScrollView>(find.byKey(const Key('tv-discovery-reading-scroll'))).controller!;
    expect(scroll.offset, scroll.position.maxScrollExtent);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byType(TvDiscoveryDialog), findsNothing);
    expect(FocusManager.instance.primaryFocus, same(before));
    expect(tester.takeException(), isNull);
  });

  testWidgets('TV variant picker cancels current source and switches an alternative only on OK', (tester) async {
    SourceSearchHit? selected;
    final variants = [
      for (final source in [_source, _otherSource]) SourceSearchHit(source: source, content: _content(0), sourceIndex: 0, sourceRank: 0),
    ];
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => Scaffold(
            body: TvFocusable(
              autofocus: true,
              onPressed: () => showSourceContentVariantPicker(
                context,
                variants: variants,
                selectedPluginId: _source.id,
                selectedContentId: 'show-0',
                onSelected: (value) async => selected = value,
              ),
              child: const Text('切换来源'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(selected, isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(selected, isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(selected?.pluginId, _otherSource.id);
  });

  for (final kind in [PluginContentKind.novel, PluginContentKind.manga, PluginContentKind.audio, PluginContentKind.video]) {
    testWidgets('TV $kind detail keeps its reader callback and catalog', (tester) async {
      String? opened;
      final detail = PluginContentDetail(
        pluginId: _source.id,
        sourceName: _source.displayName,
        summary: _content(0, kind: kind),
        aliases: const [],
        catalogUrl: null,
      );
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => Scaffold(
              body: TvFocusable(
                autofocus: true,
                onPressed: () => showSourceContentDetailSheet(
                  context,
                  gateway: _Gateway(),
                  pluginId: _source.id,
                  id: detail.summary.id,
                  initialDetail: detail,
                  initialCatalog: tvCatalogFixture,
                  refreshInitialContent: false,
                  onShelfAction: kind == PluginContentKind.video ? (_) async {} : null,
                  onVideoEpisodeRequested: ({required detail, required firstCatalogPage, required chapter}) async => opened = chapter.id,
                  onTextChapterRequested:
                      ({required detail, required firstCatalogPage, required chapter, required entryCoverBytes}) async =>
                          opened = chapter.id,
                  onComicChapterRequested:
                      ({required detail, required firstCatalogPage, required chapter, required entryCoverBytes}) async =>
                          opened = chapter.id,
                  onAudioChapterRequested: ({required detail, required firstCatalogPage, required chapter, required pluginVersion}) async =>
                      opened = chapter.id,
                ),
                child: const Text('详情'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(opened, 'a-0');
      expect(find.byKey(const Key('tv-detail-catalog-scroll')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}

Widget _app(Widget home, {double scale = 1}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: appTvTheme(AppTheme.dark()),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: TvModeScope(
      enabled: true,
      onChanged: (_) {},
      child: TvRemoteShortcuts(child: child!),
    ),
  ),
  home: home,
);

Future<void> _focus(WidgetTester tester, Finder finder) async {
  Focus.of(tester.element(find.descendant(of: finder, matching: find.byType(Text)).first)).requestFocus();
  await tester.pumpAndSettle();
}

Future<void> _activate(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await _focus(tester, finder);
  await tester.sendKeyEvent(LogicalKeyboardKey.select);
  await tester.pumpAndSettle();
}

final _source = PluginSourceDescriptor(id: 'tv-fixture', displayName: '影视测试源', contentKinds: const [PluginContentKind.video]);
final _otherSource = PluginSourceDescriptor(id: 'other', displayName: '另一来源', contentKinds: const [PluginContentKind.video]);
PluginContentSummary _content(int index, {PluginContentKind kind = PluginContentKind.video}) => PluginContentSummary(
  id: 'show-$index',
  title: ['山海之间', '穿越星河', '漫长的旅途', '城市里的故事', '夏日回声', '远方的灯火'][index],
  contentKind: kind,
  author: null,
  url: null,
  coverUrl: null,
  description: '一段关于探索、相遇与归途的故事。使用遥控器选择线路和选集，也可以展开完整简介。',
  language: 'zh-CN',
  status: PluginContentStatus.ongoing,
  access: PluginAccessKind.free,
  wordCount: null,
  chapterCount: 24,
  publishedAt: null,
  updatedAt: null,
  latestChapter: null,
  categories: const ['剧情', '2026'],
  tags: const [],
  attributes: const [],
);

class _Gateway extends TvDetailFixtureGateway {
  @override
  Future<List<PluginSourceDescriptor>> listSources() async => [_source];
  @override
  Future<PluginSearchSuggestionsResult> searchSuggestions({required String pluginId, String? cursor, int pageSize = 20}) async =>
      PluginSearchSuggestionsResult(pluginId: pluginId, sourceName: _source.displayName, items: const [], nextCursor: null);
  @override
  Future<PluginSearchResult> search({required String pluginId, required String query, String? cursor, int pageSize = 20}) async =>
      PluginSearchResult(
        pluginId: pluginId,
        sourceName: _source.displayName,
        items: List.generate(6, _content),
        nextCursor: null,
        totalCount: 6,
      );
  @override
  Future<PluginContentDetail> getDetail({required String pluginId, required String id}) async => PluginContentDetail(
    pluginId: pluginId,
    sourceName: _source.displayName,
    summary: _content(int.parse(id.split('-').last)),
    aliases: const [],
    catalogUrl: null,
  );
}

class _History implements SearchHistoryStore {
  List<String> values = ['电影', '纪录片'];
  @override
  Future<List<String>> load() async => values;
  @override
  Future<void> save(List<String> history) async {
    values = history;
  }
}
