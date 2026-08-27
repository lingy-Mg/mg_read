import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/discovery/presentation/discovery_composite_components.dart';
import 'package:mg_read/features/discovery/presentation/runtime_discovery_page.dart';

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

    await tester.tap(find.byKey(const ValueKey<String>('runtime-discovery-cover-book:1')).first);
    expect(selectedContent, 'book:1');
    await tester.tap(find.byKey(const ValueKey<String>('runtime-discovery-category-category:fantasy')));
    expect(selectedCategory, 'category:fantasy');
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/runtime_discovery_composite_wide_light.png'));
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
