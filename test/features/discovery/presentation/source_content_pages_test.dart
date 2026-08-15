import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/discovery/presentation/discovery_destination_page.dart';
import 'package:mg_read/features/discovery/presentation/search_page.dart';

void main() {
  testWidgets('search renders actual zero values and omits explicit nulls', (
    tester,
  ) async {
    final gateway = _FixedSourceGateway(
      searchResult: PluginSearchResult(
        pluginId: 'org.example.source',
        sourceName: '示例书源',
        items: <PluginContentSummary>[
          _summary(
            id: 'book-1',
            title: '零值契约测试',
            author: null,
            wordCount: 0,
            url: Uri.parse('https://example.com/books/1'),
          ),
        ],
        nextCursor: null,
        totalCount: null,
      ),
      discoveryResult: _discoveryResult(),
      detailResult: PluginContentDetail(
        pluginId: 'org.example.source',
        sourceName: '示例书源',
        summary: _summary(
          id: 'book-1',
          title: '零值契约测试',
          author: null,
          wordCount: 0,
          url: Uri.parse('https://example.com/books/1'),
        ),
        aliases: const <String>[],
        catalogUrl: null,
      ),
      chaptersResult: PluginChaptersResult(
        pluginId: 'org.example.source',
        sourceName: '示例书源',
        items: <PluginChapterSummary>[
          PluginChapterSummary(
            id: 'chapter-1',
            title: '第一章',
            order: 0,
            url: null,
            volumeTitle: null,
            wordCount: 0,
            updatedAt: null,
            isLocked: null,
            attributes: const <PluginContentAttribute>[],
          ),
        ],
        nextCursor: null,
        totalCount: 1,
      ),
      contentResult: PluginChapterContent(
        pluginId: 'org.example.source',
        sourceName: '示例书源',
        contentKind: PluginContentKind.novel,
        chapterId: 'chapter-1',
        title: null,
        updatedAt: null,
        text: '这是插件返回的正文。',
        pages: const <PluginMangaPage>[],
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sourceContentGatewayProvider.overrideWithValue(gateway)],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: SearchPage(onDestinationRequested: (_) {}),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('source-search-query')), '测试');
    await tester.tap(find.byKey(const Key('source-search-submit')));
    await tester.pumpAndSettle();

    expect(find.text('零值契约测试'), findsOneWidget);
    expect(find.text('字数：0'), findsOneWidget);
    expect(find.text('https://example.com/books/1'), findsOneWidget);
    expect(find.textContaining('作者：'), findsNothing);
    expect(find.textContaining('更新时间：'), findsNothing);
    expect(find.textContaining('最新章节：'), findsNothing);
    expect(find.text('状态：未知'), findsOneWidget);
    expect(find.text('访问：未知'), findsOneWidget);

    await tester.tap(find.byKey(const Key('search-result-book-1')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('source-content-detail-sheet')),
      findsOneWidget,
    );
    expect(find.text('字数：0'), findsWidgets);
    expect(find.text('第一章'), findsOneWidget);
    expect(gateway.detailCalls, 1);
    expect(gateway.chapterCalls, 1);

    await tester.tap(find.byKey(const Key('source-chapter-chapter-1')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('source-chapter-content-sheet')),
      findsOneWidget,
    );
    expect(find.text('这是插件返回的正文。'), findsOneWidget);
    expect(gateway.contentCalls, 1);
  });

  testWidgets('discovery uses plugin source, tab and section labels', (
    tester,
  ) async {
    final gateway = _FixedSourceGateway(
      searchResult: PluginSearchResult(
        pluginId: 'org.example.source',
        sourceName: '示例书源',
        items: const <PluginContentSummary>[],
        nextCursor: null,
        totalCount: 0,
      ),
      discoveryResult: _discoveryResult(),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sourceContentGatewayProvider.overrideWithValue(gateway)],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: DiscoveryDestinationPage(onDestinationRequested: (_) {}),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('示例书源'), findsOneWidget);
    expect(find.text('最新推荐'), findsOneWidget);
    expect(find.text('插件精选'), findsOneWidget);
    expect(find.text('真实发现书籍'), findsAtLeastNWidgets(1));
    expect(find.text('第二分区书籍'), findsAtLeastNWidgets(1));
    expect(find.textContaining('null'), findsNothing);
  });

  testWidgets('category-only discovery is content and preserves zero counts', (
    tester,
  ) async {
    final gateway = _FixedSourceGateway(
      searchResult: PluginSearchResult(
        pluginId: 'org.example.source',
        sourceName: '示例书源',
        items: const <PluginContentSummary>[],
        nextCursor: null,
        totalCount: 0,
      ),
      discoveryResult: PluginDiscoverResult(
        pluginId: 'org.example.source',
        sourceName: '示例书源',
        tabs: const <PluginDiscoveryTab>[],
        selectedTabId: null,
        sections: <PluginDiscoverySection>[
          PluginDiscoverySection(
            id: 'categories',
            title: '纯分类',
            subtitle: null,
            layout: PluginDiscoveryLayout.categories,
            items: const <PluginDiscoveryContentItem>[],
            categories: const <PluginDiscoveryCategory>[
              PluginDiscoveryCategory(
                id: 'empty-category',
                title: '零本分类',
                target: 'category:empty',
                count: 0,
                url: null,
              ),
            ],
          ),
        ],
        nextCursor: null,
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sourceContentGatewayProvider.overrideWithValue(gateway)],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: DiscoveryDestinationPage(onDestinationRequested: (_) {}),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('discovery-empty')), findsNothing);
    expect(find.text('纯分类'), findsOneWidget);
    expect(find.text('零本分类'), findsOneWidget);
    expect(find.text('0 本'), findsOneWidget);

    await tester.tap(
      find.byKey(const Key('runtime-discovery-category-empty-category')),
    );
    await tester.pumpAndSettle();

    expect(gateway.discoverTargets, <String?>[null, 'category:empty']);
  });

  testWidgets('discovery picker opens the Runtime-owned source manager', (
    tester,
  ) async {
    final gateway = _FixedSourceGateway(
      searchResult: PluginSearchResult(
        pluginId: 'org.example.source',
        sourceName: '示例书源',
        items: const <PluginContentSummary>[],
        nextCursor: null,
        totalCount: 0,
      ),
      discoveryResult: _discoveryResult(),
    );
    var managementRequested = false;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sourceContentGatewayProvider.overrideWithValue(gateway)],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: DiscoveryDestinationPage(
            onDestinationRequested: (_) {},
            onSourceManagementRequested: () => managementRequested = true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('discovery-source-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('discovery-source-picker-manage')));
    await tester.pumpAndSettle();

    expect(managementRequested, isTrue);
  });
}

PluginDiscoverResult _discoveryResult() {
  final item = PluginDiscoveryContentItem(
    content: _summary(
      id: 'discover-1',
      title: '真实发现书籍',
      author: null,
      wordCount: null,
      url: null,
    ),
    rank: null,
    metric: null,
    recommendation: null,
  );
  return PluginDiscoverResult(
    pluginId: 'org.example.source',
    sourceName: '示例书源',
    tabs: const <PluginDiscoveryTab>[
      PluginDiscoveryTab(id: 'latest', label: '最新推荐', target: 'latest'),
    ],
    selectedTabId: 'latest',
    sections: <PluginDiscoverySection>[
      PluginDiscoverySection(
        id: 'featured',
        title: '插件精选',
        subtitle: null,
        layout: PluginDiscoveryLayout.featured,
        items: <PluginDiscoveryContentItem>[item],
        categories: const <PluginDiscoveryCategory>[],
      ),
      PluginDiscoverySection(
        id: 'more',
        title: '更多内容',
        subtitle: null,
        layout: PluginDiscoveryLayout.list,
        items: <PluginDiscoveryContentItem>[
          PluginDiscoveryContentItem(
            content: _summary(
              id: 'discover-2',
              title: '第二分区书籍',
              author: '第二作者',
              wordCount: 0,
              url: null,
            ),
            rank: null,
            metric: null,
            recommendation: null,
          ),
        ],
        categories: const <PluginDiscoveryCategory>[],
      ),
    ],
    nextCursor: null,
  );
}

PluginContentSummary _summary({
  required String id,
  required String title,
  required String? author,
  required int? wordCount,
  required Uri? url,
}) {
  return PluginContentSummary(
    id: id,
    title: title,
    contentKind: PluginContentKind.novel,
    author: author,
    url: url,
    coverUrl: null,
    description: null,
    language: null,
    status: PluginContentStatus.unknown,
    access: PluginAccessKind.unknown,
    wordCount: wordCount,
    chapterCount: null,
    publishedAt: null,
    updatedAt: null,
    latestChapter: null,
    categories: const <String>[],
    tags: const <String>[],
    attributes: const <PluginContentAttribute>[],
  );
}

final class _FixedSourceGateway implements SourceContentGateway {
  _FixedSourceGateway({
    required this.searchResult,
    required this.discoveryResult,
    this.detailResult,
    this.chaptersResult,
    this.contentResult,
  });

  final PluginSearchResult searchResult;
  final PluginDiscoverResult discoveryResult;
  final PluginContentDetail? detailResult;
  final PluginChaptersResult? chaptersResult;
  final PluginChapterContent? contentResult;

  int detailCalls = 0;
  int chapterCalls = 0;
  int contentCalls = 0;
  final List<String?> discoverTargets = <String?>[];

  @override
  Future<List<PluginSourceDescriptor>> listSources() async {
    return <PluginSourceDescriptor>[
      PluginSourceDescriptor(
        id: 'org.example.source',
        displayName: '示例书源',
        contentKinds: const <PluginContentKind>[PluginContentKind.novel],
      ),
    ];
  }

  @override
  Future<PluginSearchResult> search({
    required String pluginId,
    required String query,
    String? cursor,
    int pageSize = 20,
  }) async => searchResult;

  @override
  Future<PluginDiscoverResult> discover({
    required String pluginId,
    String? target,
    String? cursor,
    int pageSize = 20,
  }) async {
    discoverTargets.add(target);
    return discoveryResult;
  }

  @override
  Future<PluginContentDetail> getDetail({
    required String pluginId,
    required String id,
  }) async {
    detailCalls += 1;
    return detailResult ?? (throw UnimplementedError());
  }

  @override
  Future<PluginChaptersResult> getChapters({
    required String pluginId,
    required String id,
    String? cursor,
    int pageSize = 50,
  }) async {
    chapterCalls += 1;
    return chaptersResult ?? (throw UnimplementedError());
  }

  @override
  Future<PluginChapterContent> getContent({
    required String pluginId,
    required String id,
    required String chapterId,
  }) async {
    contentCalls += 1;
    return contentResult ?? (throw UnimplementedError());
  }
}
