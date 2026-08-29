import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/discovery/presentation/discovery_composite_components.dart';
import 'package:mg_read/features/discovery/presentation/runtime_discovery_page.dart';
import 'package:mg_read/shared/presentation/widgets/async_book_cover_loader.dart';

void main() {
  setUpAll(() async {
    final miSans = FontLoader('packages/novel_reader_ui/MiSans')
      ..addFont(rootBundle.load('packages/novel_reader_ui/assets/fonts/MiSansVF.ttf'));
    final materialIcons = FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await Future.wait(<Future<void>>[miSans.load(), materialIcons.load()]);
  });

  testWidgets('renders source-composed discovery layouts and keeps actions typed', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    String? selectedCategory;
    String? selectedContent;

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        home: RuntimeDiscoveryPage(
          result: _result,
          onDestinationRequested: (_) {},
          onSourcePressed: () {},
          onTabSelected: (_) {},
          onCategorySelected: (value) => selectedCategory = value,
          onContentPressed: (value) => selectedContent = value.id,
          onRefreshRequested: () {},
          onLoadMore: (_) {},
          canNavigateBack: false,
          onBackRequested: () {},
          loadingCollectionId: null,
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('runtime-discovery-cover-grid')), findsOneWidget);
    expect(find.byKey(const Key('runtime-discovery-book-shelf')), findsOneWidget);
    expect(find.byKey(const Key('runtime-discovery-compact-list')), findsOneWidget);
    expect(find.byKey(const Key('runtime-discovery-category-chips')), findsOneWidget);
    expect(find.byIcon(Icons.today_rounded), findsOneWidget);
    expect(find.byIcon(Icons.date_range_rounded), findsOneWidget);
    expect(find.byIcon(Icons.calendar_month_rounded), findsOneWidget);
    expect(find.byIcon(Icons.emoji_events_rounded), findsOneWidget);
    expect(tester.getSize(find.byKey(const Key('runtime-discovery-book-shelf'))).height, AppSpacing.discoveryShelfHeight);
    expect(
      tester.getSize(find.byKey(const ValueKey<String>('runtime-discovery-compact-book:1'))).height,
      inInclusiveRange(AppSpacing.discoveryCompactRowMinHeight, AppSpacing.discoveryCompactRowMinHeight + 1),
    );
    final categoryChip = find.byKey(const ValueKey<String>('runtime-discovery-category-category:fantasy'));
    expect(tester.getSize(categoryChip).height, AppSpacing.minimumTouchTarget);
    expect(
      tester.getSize(find.descendant(of: categoryChip, matching: find.byType(ChoiceChip))).height,
      AppSpacing.discoveryChipVisualHeight,
    );
    final title = tester.widget<Text>(find.byKey(const ValueKey<String>('runtime-discovery-section-title-rankings')));
    final subtitle = tester.widget<Text>(find.byKey(const ValueKey<String>('runtime-discovery-section-subtitle-rankings')));
    expect(title.style?.fontSize, AppTypography.sectionTitle);
    expect(
      subtitle.style?.color,
      AppThemeTokens.of(tester.element(find.byKey(const ValueKey<String>('runtime-discovery-section-subtitle-rankings')))).mutedText,
    );

    await tester.tap(find.byKey(const ValueKey<String>('runtime-discovery-cover-book:1')).first);
    expect(selectedContent, 'book:1');
    await tester.tap(find.byKey(const ValueKey<String>('runtime-discovery-category-category:fantasy')));
    expect(selectedCategory, 'category:fantasy');
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/runtime_discovery_composite_wide_light.png'));
  });

  testWidgets('matches the unified compact discovery component rhythm', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        home: RuntimeDiscoveryPage(
          result: _result,
          onDestinationRequested: (_) {},
          onSourcePressed: () {},
          onTabSelected: (_) {},
          onCategorySelected: (_) {},
          onContentPressed: (_) {},
          onRefreshRequested: () {},
          onLoadMore: (_) {},
          canNavigateBack: false,
          onBackRequested: () {},
          loadingCollectionId: null,
        ),
      ),
    );
    await tester.pump();

    final compactList = tester.getRect(find.byKey(const Key('runtime-discovery-compact-list')));
    expect(compactList.left, AppSpacing.discoveryPagePadding);
    expect(390 - compactList.right, AppSpacing.discoveryPagePadding);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/runtime_discovery_composite_compact_light.png'));
  });

  testWidgets('passes the remote cover identity through the recommendation carousel', (tester) async {
    BookCoverRequest? request;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookCoverBytesLoaderProvider.overrideWithValue(_RecordingBookCoverLoader((value) => request = value))],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          home: RuntimeDiscoveryPage(
            result: _carouselResult,
            onDestinationRequested: (_) {},
            onSourcePressed: () {},
            onTabSelected: (_) {},
            onCategorySelected: (_) {},
            onContentPressed: (_) {},
            onRefreshRequested: () {},
            onLoadMore: (_) {},
            canNavigateBack: false,
            onBackRequested: () {},
            loadingCollectionId: null,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(request?.remoteContentId, 'novel:recommendation-1');
    expect(request?.coverUrl, Uri.parse('https://covers.example/recommendation-1.jpg'));
  });

  testWidgets('uses three cover columns on phones and four on wider layouts', (tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));

    Future<void> pumpAtWidth(double width) async {
      await tester.binding.setSurfaceSize(Size(width, 1000));
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: DiscoveryCoverGrid(
                items: <PluginDiscoveryContentItem>[for (var index = 1; index <= 6; index++) _item('book:$index', '第$index本书', index)],
                onPressed: (_) {},
                isInBookshelf: (_) => false,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    int columnCount() {
      final grid = tester.widget<GridView>(find.byKey(const Key('runtime-discovery-cover-grid')));
      return (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount).crossAxisCount;
    }

    await pumpAtWidth(390);
    expect(columnCount(), 3);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/runtime_discovery_cover_grid_phone_light.png'));

    await pumpAtWidth(760);
    expect(columnCount(), 4);
  });

  testWidgets('fills each category chip row with adaptive equal-width columns', (tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const categories = <PluginDiscoveryCategory>[
      PluginDiscoveryCategory(id: 'short', title: '科幻', target: 'short', count: null, url: null, icon: PluginDiscoveryIcon.scienceFiction),
      PluginDiscoveryCategory(id: 'medium', title: '经典', target: 'medium', count: null, url: null, icon: PluginDiscoveryIcon.classic),
      PluginDiscoveryCategory(id: 'long', title: '都市小说', target: 'long', count: null, url: null, icon: PluginDiscoveryIcon.urban),
      PluginDiscoveryCategory(id: 'fourth', title: '乡村', target: 'fourth', count: null, url: null, icon: PluginDiscoveryIcon.rural),
      PluginDiscoveryCategory(id: 'fifth', title: '奇幻小说', target: 'fifth', count: null, url: null, icon: PluginDiscoveryIcon.fantasy),
      PluginDiscoveryCategory(id: 'sixth', title: '历史', target: 'sixth', count: null, url: null, icon: PluginDiscoveryIcon.history),
    ];

    Future<void> pumpAtWidth(double width) async {
      await tester.binding.setSurfaceSize(Size(width, 600));
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(AppSpacing.discoveryPagePadding),
              child: DiscoveryCategoryCollection(categories: categories, layout: PluginDiscoveryCategoryLayout.chips, onSelected: (_) {}),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    Rect chipRect(String id) => tester.getRect(
      find.descendant(of: find.byKey(ValueKey<String>('runtime-discovery-category-$id')), matching: find.byType(ChoiceChip)),
    );

    await pumpAtWidth(390);
    final compact = <Rect>[chipRect('short'), chipRect('medium'), chipRect('long')];
    expect(compact.map((rect) => rect.width), everyElement(closeTo(compact.first.width, 0.01)));
    expect(compact.first.left, AppSpacing.discoveryPagePadding);
    expect(compact.last.right, closeTo(390 - AppSpacing.discoveryPagePadding, 0.01));
    expect(chipRect('fourth').top, greaterThan(compact.first.top));

    await pumpAtWidth(760);
    final wide = <Rect>[chipRect('short'), chipRect('medium'), chipRect('long'), chipRect('fourth')];
    expect(wide.map((rect) => rect.width), everyElement(closeTo(wide.first.width, 0.01)));
    expect(wide.first.left, AppSpacing.discoveryPagePadding);
    expect(wide.last.right, closeTo(760 - AppSpacing.discoveryPagePadding, 0.01));
    expect(chipRect('fifth').top, greaterThan(wide.first.top));
  });

  testWidgets('allows a mouse drag to scroll the horizontal shelf on desktop', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: DiscoveryBookShelf(
            items: <PluginDiscoveryContentItem>[for (var index = 1; index <= 8; index++) _item('book:$index', '第$index本书', index)],
            onPressed: (_) {},
            isInBookshelf: (_) => false,
          ),
        ),
      ),
    );
    await tester.pump();

    final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
    expect(scrollable.position.pixels, 0);
    await tester.dragFrom(const Offset(320, 100), const Offset(-180, 0), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();

    expect(scrollable.position.pixels, greaterThan(0));
  });
}

final PluginDiscoveryDocumentResult _result = PluginDiscoveryDocumentResult(
  pluginId: 'composite.source',
  sourceName: '组合书源',
  document: PluginDiscoveryDocument(
    components: <PluginDiscoveryComponent>[
      _section('covers', '封面精选', PluginDiscoveryContentLayout.coverGrid),
      _section('shelf', '横向书架', PluginDiscoveryContentLayout.shelf),
      PluginDiscoveryGroupComponent(
        id: 'overview',
        layout: PluginDiscoveryGroupLayout.vertical,
        children: <PluginDiscoveryComponent>[
          _section('compact', '紧凑榜单', PluginDiscoveryContentLayout.compact),
          PluginDiscoverySectionComponent(
            id: 'rankings',
            title: '热门榜单',
            subtitle: '按时段查看热度排行',
            icon: PluginDiscoveryIcon.ranking,
            children: <PluginDiscoveryComponent>[
              PluginDiscoveryCategoryCollectionComponent(
                id: 'ranking-grid',
                layout: PluginDiscoveryCategoryLayout.grid,
                categories: const <PluginDiscoveryCategory>[
                  PluginDiscoveryCategory(
                    id: 'ranking:day',
                    title: '本日排行',
                    target: 'ranking:day',
                    count: null,
                    url: null,
                    icon: PluginDiscoveryIcon.dailyRanking,
                  ),
                  PluginDiscoveryCategory(
                    id: 'ranking:week',
                    title: '本周排行',
                    target: 'ranking:week',
                    count: null,
                    url: null,
                    icon: PluginDiscoveryIcon.weeklyRanking,
                  ),
                  PluginDiscoveryCategory(
                    id: 'ranking:month',
                    title: '本月排行',
                    target: 'ranking:month',
                    count: null,
                    url: null,
                    icon: PluginDiscoveryIcon.monthlyRanking,
                  ),
                  PluginDiscoveryCategory(
                    id: 'ranking:total',
                    title: '总排行',
                    target: 'ranking:total',
                    count: null,
                    url: null,
                    icon: PluginDiscoveryIcon.allTimeRanking,
                  ),
                ],
              ),
            ],
          ),
          PluginDiscoverySectionComponent(
            id: 'categories',
            title: '题材',
            subtitle: null,
            icon: PluginDiscoveryIcon.category,
            children: <PluginDiscoveryComponent>[
              PluginDiscoveryCategoryCollectionComponent(
                id: 'category-chips',
                layout: PluginDiscoveryCategoryLayout.chips,
                categories: const <PluginDiscoveryCategory>[
                  PluginDiscoveryCategory(
                    id: 'category:fantasy',
                    title: '玄幻',
                    target: 'category:fantasy',
                    count: null,
                    url: null,
                    icon: PluginDiscoveryIcon.fantasy,
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    ],
  ),
);

PluginDiscoverySectionComponent _section(String id, String title, PluginDiscoveryContentLayout layout) => PluginDiscoverySectionComponent(
  id: id,
  title: title,
  subtitle: null,
  children: <PluginDiscoveryComponent>[
    PluginDiscoveryContentCollectionComponent(
      id: '$id-books',
      layout: layout,
      items: <PluginDiscoveryContentItem>[_item('book:1', '第一本书', 1), _item('book:2', '第二本书', 2)],
      continuation: null,
    ),
  ],
);

PluginDiscoveryContentItem _item(String id, String title, int rank) => PluginDiscoveryContentItem(
  content: PluginContentSummary(
    id: id,
    title: title,
    contentKind: PluginContentKind.novel,
    author: '作者',
    url: null,
    coverUrl: null,
    description: '简介',
    language: 'zh-CN',
    status: PluginContentStatus.ongoing,
    access: PluginAccessKind.free,
    wordCount: null,
    chapterCount: null,
    publishedAt: null,
    updatedAt: null,
    latestChapter: null,
    categories: const <String>['玄幻'],
    tags: const <String>[],
    attributes: const <PluginContentAttribute>[],
  ),
  rank: rank,
  metric: const PluginDiscoveryMetric(label: '热度', value: '1万'),
  recommendation: null,
);

final PluginDiscoveryDocumentResult _carouselResult = PluginDiscoveryDocumentResult(
  pluginId: 'carousel.source',
  sourceName: '轮播书源',
  document: PluginDiscoveryDocument(
    components: <PluginDiscoveryComponent>[
      PluginDiscoverySectionComponent(
        id: 'featured',
        title: '重磅推荐',
        subtitle: null,
        children: <PluginDiscoveryComponent>[
          PluginDiscoveryContentCollectionComponent(
            id: 'featured-books',
            layout: PluginDiscoveryContentLayout.carousel,
            items: <PluginDiscoveryContentItem>[
              PluginDiscoveryContentItem(
                content: PluginContentSummary(
                  id: 'novel:recommendation-1',
                  title: '有真实封面的推荐书',
                  contentKind: PluginContentKind.novel,
                  author: '推荐作者',
                  url: null,
                  coverUrl: Uri.parse('https://covers.example/recommendation-1.jpg'),
                  description: '推荐简介',
                  language: 'zh-CN',
                  status: PluginContentStatus.ongoing,
                  access: PluginAccessKind.free,
                  wordCount: null,
                  chapterCount: null,
                  publishedAt: null,
                  updatedAt: null,
                  latestChapter: null,
                  categories: const <String>['玄幻'],
                  tags: const <String>[],
                  attributes: const <PluginContentAttribute>[],
                ),
                rank: null,
                metric: null,
                recommendation: null,
              ),
            ],
            continuation: null,
          ),
        ],
      ),
    ],
  ),
);

final class _RecordingBookCoverLoader implements BookCoverBytesLoader {
  const _RecordingBookCoverLoader(this.onRequest);

  final void Function(BookCoverRequest request) onRequest;

  @override
  Future<List<int>?> resolve(BookCoverRequest request) async {
    onRequest(request);
    return null;
  }
}
