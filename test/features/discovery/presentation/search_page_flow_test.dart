import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/discovery/application/discovery_bookshelf_saver.dart';
import 'package:mg_read/features/discovery/application/bookshelf_membership.dart';
import 'package:mg_read/features/discovery/application/search_history_store.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/discovery/presentation/search_page.dart';

void main() {
  testWidgets('does not search until the user selects a history keyword', (
    tester,
  ) async {
    final gateway = _SearchGateway();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sourceContentGatewayProvider.overrideWithValue(gateway),
          searchHistoryStoreProvider.overrideWithValue(
            _MemorySearchHistoryStore(const <String>['诡秘之主']),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: SearchPage(onDestinationRequested: (_) {}),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(gateway.queries, isEmpty);
    expect(find.text('输入关键词开始搜索'), findsOneWidget);
    expect(find.text('真实搜索结果'), findsNothing);
    final historyScroll = tester.widget<SingleChildScrollView>(
      find.byKey(const Key('search-history-scroll')),
    );
    expect(historyScroll.scrollDirection, Axis.horizontal);

    await tester.tap(find.text('诡秘之主').first);
    await tester.pumpAndSettle();

    expect(gateway.queries, <String>['诡秘之主']);
    expect(find.text('真实搜索结果'), findsWidgets);
  });

  testWidgets('keeps the discovery source when opening search', (tester) async {
    final gateway = _SearchGateway(
      sources: <PluginSourceDescriptor>[
        _source('source.first', '第一个书源'),
        _source('source.second', '第二个书源'),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sourceContentGatewayProvider.overrideWithValue(gateway),
          searchHistoryStoreProvider.overrideWithValue(
            _MemorySearchHistoryStore(const <String>['诡秘之主']),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: SearchPage(
            initialSourceId: 'source.second',
            onDestinationRequested: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(gateway.pluginIds, isEmpty);
    expect(find.text('第二个书源'), findsOneWidget);
  });

  testWidgets(
    'uses the same-source same-title shelf state in list and detail',
    (tester) async {
      final gateway = _SearchGateway();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sourceContentGatewayProvider.overrideWithValue(gateway),
            searchHistoryStoreProvider.overrideWithValue(
              _MemorySearchHistoryStore(const <String>['诡秘之主']),
            ),
            bookshelfMembershipLoaderProvider.overrideWithValue(
              _MemoryMembershipLoader(const <BookshelfMembershipEntry>[
                BookshelfMembershipEntry(
                  pluginId: 'source.test',
                  title: '真实搜索结果',
                ),
              ]),
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: SearchPage(onDestinationRequested: (_) {}),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('诡秘之主').first);
      await tester.pumpAndSettle();
      expect(find.text('已在书架'), findsNothing);

      await tester.tap(find.text('真实搜索结果').first);
      await tester.pumpAndSettle();
      expect(find.text('已在书架'), findsOneWidget);
    },
  );

  testWidgets('shows Material search progress until results arrive', (
    tester,
  ) async {
    final completion = Completer<PluginSearchResult>();
    final gateway = _SearchGateway(searchCompletion: completion);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sourceContentGatewayProvider.overrideWithValue(gateway),
          searchHistoryStoreProvider.overrideWithValue(
            _MemorySearchHistoryStore(const <String>['诡秘之主']),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: SearchPage(onDestinationRequested: (_) {}),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('诡秘之主').first);
    await tester.pump();

    expect(
      find.byKey(const Key('source-search-field-progress')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('source-search-progress')), findsOneWidget);
    expect(find.text('正在搜索“诡秘之主”'), findsOneWidget);

    completion.complete(_searchResult('source.test'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('source-search-progress')), findsNothing);
    expect(find.text('真实搜索结果'), findsWidgets);
  });

  testWidgets(
    'uses the reader callback and selected source from search detail',
    (tester) async {
      final gateway = _SearchGateway();
      final saver = _RecordingBookshelfSaver();
      PluginContentDetail? requestedDetail;
      PluginChaptersResult? requestedCatalog;
      PluginChapterSummary? requestedChapter;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sourceContentGatewayProvider.overrideWithValue(gateway),
            searchHistoryStoreProvider.overrideWithValue(
              _MemorySearchHistoryStore(const <String>['诡秘之主']),
            ),
            discoveryBookshelfSaverProvider.overrideWithValue(saver),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: SearchPage(
              onDestinationRequested: (_) {},
              onTextChapterRequested:
                  ({
                    required detail,
                    required firstCatalogPage,
                    required chapter,
                  }) async {
                    requestedDetail = detail;
                    requestedCatalog = firstCatalogPage;
                    requestedChapter = chapter;
                  },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('诡秘之主').first);
      await tester.pumpAndSettle();

      await tester.tap(find.text('真实搜索结果').first);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('source-detail-add-shelf')));
      await tester.pumpAndSettle();
      expect(saver.source?.id, 'source.test');
      expect(saver.source?.pluginVersion, '1.2.3');
      expect(saver.content?.id, 'real-result');

      await tester.tap(find.byKey(const Key('source-detail-start-reading')));
      await tester.pumpAndSettle();
      expect(requestedDetail?.summary.id, 'real-result');
      expect(requestedCatalog?.items.single.id, 'chapter-1');
      expect(requestedChapter?.id, 'chapter-1');
      expect(
        find.byKey(const Key('source-chapter-content-sheet')),
        findsNothing,
      );
    },
  );
}

final class _MemorySearchHistoryStore implements SearchHistoryStore {
  _MemorySearchHistoryStore(Iterable<String> initial)
    : _history = List<String>.of(initial);

  final List<String> _history;

  @override
  Future<List<String>> load() async => List<String>.of(_history);

  @override
  Future<void> save(List<String> history) async {
    _history
      ..clear()
      ..addAll(history);
  }
}

final class _RecordingBookshelfSaver implements DiscoveryBookshelfSaver {
  PluginSourceDescriptor? source;
  PluginContentSummary? content;

  @override
  Future<void> save({
    required PluginSourceDescriptor source,
    required PluginContentSummary content,
  }) async {
    this.source = source;
    this.content = content;
  }
}

final class _MemoryMembershipLoader implements BookshelfMembershipLoader {
  const _MemoryMembershipLoader(this.entries);

  final List<BookshelfMembershipEntry> entries;

  @override
  Future<Iterable<BookshelfMembershipEntry>> load() async => entries;
}

final class _SearchGateway implements SourceContentGateway {
  _SearchGateway({List<PluginSourceDescriptor>? sources, this.searchCompletion})
    : sources =
          sources ?? <PluginSourceDescriptor>[_source('source.test', '测试书源')];

  final List<PluginSourceDescriptor> sources;
  final List<String> queries = <String>[];
  final List<String> pluginIds = <String>[];
  final Completer<PluginSearchResult>? searchCompletion;

  @override
  Future<List<PluginSourceDescriptor>> listSources() async => sources;

  @override
  Future<PluginSearchResult> search({
    required String pluginId,
    required String query,
    String? cursor,
    int pageSize = 20,
  }) async {
    queries.add(query);
    pluginIds.add(pluginId);
    return searchCompletion?.future ?? _searchResult(pluginId);
  }

  @override
  Future<PluginSearchSuggestionsResult> searchSuggestions({
    required String pluginId,
    String? cursor,
    int pageSize = 20,
  }) async => PluginSearchSuggestionsResult(
    pluginId: pluginId,
    sourceName: '测试书源',
    items: const <PluginSearchSuggestion>[
      PluginSearchSuggestion(query: '诡秘之主', metric: '12.3万'),
    ],
    nextCursor: null,
  );

  @override
  Future<PluginDiscoverResult> discover({
    required String pluginId,
    String? target,
    String? cursor,
    String? collectionId,
    int pageSize = 20,
  }) => throw UnimplementedError();

  @override
  Future<PluginContentDetail> getDetail({
    required String pluginId,
    required String id,
  }) async => PluginContentDetail(
    pluginId: pluginId,
    sourceName: '测试书源',
    summary: _content(id),
    aliases: const <String>[],
    catalogUrl: null,
  );

  @override
  Future<PluginChaptersResult> getChapters({
    required String pluginId,
    required String id,
  }) async => PluginChaptersResult(
    pluginId: pluginId,
    sourceName: '测试书源',
    items: <PluginChapterSummary>[
      PluginChapterSummary(
        id: 'chapter-1',
        title: '第一章',
        order: 0,
        url: null,
        volumeTitle: null,
        wordCount: null,
        updatedAt: null,
        isLocked: false,
        attributes: const <PluginContentAttribute>[],
      ),
    ],
  );

  @override
  Future<PluginChapterContent> getContent({
    required String pluginId,
    required String id,
    required String chapterId,
  }) => throw UnimplementedError();
}

PluginSearchResult _searchResult(String pluginId) => PluginSearchResult(
  pluginId: pluginId,
  sourceName: '测试书源',
  items: <PluginContentSummary>[
    PluginContentSummary(
      id: 'real-result',
      title: '真实搜索结果',
      contentKind: PluginContentKind.novel,
      author: null,
      url: null,
      coverUrl: null,
      description: null,
      language: null,
      status: PluginContentStatus.unknown,
      access: PluginAccessKind.unknown,
      wordCount: null,
      chapterCount: null,
      publishedAt: null,
      updatedAt: null,
      latestChapter: null,
      categories: const <String>[],
      tags: const <String>[],
      attributes: const <PluginContentAttribute>[],
    ),
  ],
  nextCursor: null,
  totalCount: 1,
);

PluginContentSummary _content(String id) => PluginContentSummary(
  id: id,
  title: '真实搜索结果',
  contentKind: PluginContentKind.novel,
  author: null,
  url: null,
  coverUrl: null,
  description: null,
  language: null,
  status: PluginContentStatus.unknown,
  access: PluginAccessKind.unknown,
  wordCount: null,
  chapterCount: 1,
  publishedAt: null,
  updatedAt: null,
  latestChapter: null,
  categories: const <String>[],
  tags: const <String>[],
  attributes: const <PluginContentAttribute>[],
);

PluginSourceDescriptor _source(String id, String displayName) =>
    PluginSourceDescriptor(
      id: id,
      displayName: displayName,
      pluginVersion: '1.2.3',
      contentKinds: const <PluginContentKind>[PluginContentKind.novel],
    );
