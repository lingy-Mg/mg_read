import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/discovery/presentation/source_content_detail_sheet.dart';
import 'package:mg_read/shared/presentation/widgets/async_book_cover_loader.dart';

import 'fixtures/alice_book_house_detail_fixture.dart';

void main() {
  testWidgets('detail forwards one typed shelf save while the request is active', (tester) async {
    var saveCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: _DetailHost(onAddToShelf: (_) async => saveCount++),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('source-detail-add-shelf')));
    await tester.tap(find.byKey(const Key('source-detail-add-shelf')));
    await tester.pumpAndSettle();

    expect(saveCount, 1);
    expect(find.text('已加入书架。'), findsOneWidget);
  });

  testWidgets('detail reports a shelf save failure', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: _DetailHost(onAddToShelf: (_) => Future<void>.error(StateError('save failed'))),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('source-detail-add-shelf')));
    await tester.pumpAndSettle();

    expect(find.text('暂时无法加入书架，请稍后重试。'), findsOneWidget);
  });

  testWidgets('detail translates the stable capacity failure for the user', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: _DetailHost(
          onAddToShelf: (_) =>
              Future<void>.error(const BookshelfCapacityExceededException(currentCount: bookshelfMaxItemCount, requestedNewItems: 1)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('source-detail-add-shelf')));
    await tester.pumpAndSettle();

    expect(find.text('书架已满，请先清理书籍。'), findsOneWidget);
  });

  testWidgets('shelf detail adapts the add action to an existing shelf item', (tester) async {
    await tester.pumpWidget(MaterialApp(theme: AppTheme.light(), home: _ShelfDetailHost()));
    await tester.pumpAndSettle();

    expect(find.text('已在书架'), findsOneWidget);
    await tester.tap(find.byKey(const Key('source-detail-add-shelf')));
    await tester.pumpAndSettle();
    expect(find.text('此书已在书架中。'), findsOneWidget);
  });

  testWidgets('shelf-owned detail uses one custom three-action bar', (tester) async {
    var startReadingCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: _ActionShelfDetailHost(onStartReading: () async => startReadingCount += 1),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('source-detail-privacy-action')), findsOneWidget);
    expect(find.byKey(const Key('source-detail-refresh-action')), findsOneWidget);
    expect(find.byKey(const Key('source-detail-delete-action')), findsOneWidget);
    expect(find.byKey(const Key('source-detail-start-reading')), findsOneWidget);
    expect(find.byKey(const Key('source-detail-add-shelf')), findsNothing);

    await tester.tap(find.byKey(const Key('source-detail-start-reading')));
    await tester.pumpAndSettle();
    expect(startReadingCount, 1);
  });

  testWidgets('shelf detail shows and clears the refresh animation', (tester) async {
    final Completer<void> refresh = Completer<void>();
    final List<SourceShelfAction> actions = <SourceShelfAction>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: _ActionShelfDetailHost(
          onStartReading: () async {},
          onShelfAction: (SourceShelfAction action) async {
            actions.add(action);
            await refresh.future;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('source-detail-refresh-action')));
    await tester.pump();

    expect(actions, <SourceShelfAction>[SourceShelfAction.refresh]);
    expect(find.text('刷新中'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    refresh.complete();
    await tester.pumpAndSettle();

    expect(find.text('刷新'), findsOneWidget);
    expect(find.text('刷新中'), findsNothing);
  });

  testWidgets('manga detail starts the comic reader callback instead of a URL list', (tester) async {
    var comicChapterCount = 0;
    List<int>? forwardedCoverBytes;
    BookCoverMemoryCache.write(
      BookCoverRequest(pluginId: 'org.example.manga', pluginVersion: 'unknown', remoteContentId: 'manga-1', coverUrl: _mangaCoverUrl),
      _mangaCoverBytes,
    );
    addTearDown(BookCoverMemoryCache.clear);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light(),
          home: _MangaDetailHost(
            onComicChapterRequested: ({required detail, required firstCatalogPage, required chapter, required entryCoverBytes}) async {
              comicChapterCount += 1;
              forwardedCoverBytes = entryCoverBytes;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('source-detail-start-reading')));
    await tester.pumpAndSettle();

    expect(comicChapterCount, 1);
    expect(forwardedCoverBytes, _mangaCoverBytes);
    expect(find.byKey(const Key('source-detail-start-reading')), findsNothing);
    expect(find.byKey(const Key('source-chapter-content-sheet')), findsNothing);
  });

  testWidgets('deferred shelf detail is visible before the local seed completes', (tester) async {
    final seed = Completer<SourceContentDetailSeed>();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: _DeferredShelfDetailHost(seed: seed.future),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('缓存书名'), findsWidgets);
    expect(find.text('565.2万'), findsWidgets);
    expect(find.byKey(const Key('source-detail-privacy-action')), findsOneWidget);
    expect(find.byKey(const Key('source-detail-delete-action')), findsOneWidget);
    expect(find.byKey(const Key('source-detail-start-reading')), findsOneWidget);

    seed.complete(
      SourceContentDetailSeed(
        pluginId: AliceBookHouseDetailFixture.pluginId,
        id: AliceBookHouseDetailFixture.bookId,
        initialContent: AliceBookHouseDetailFixture.detail.summary,
        initialCatalog: AliceBookHouseDetailFixture.firstCatalogPage,
        sourceName: AliceBookHouseDetailFixture.detail.sourceName,
      ),
    );
    await tester.pumpAndSettle();
  });
}

class _DetailHost extends StatefulWidget {
  const _DetailHost({required this.onAddToShelf});

  final SourceShelfSaveRequested onAddToShelf;

  @override
  State<_DetailHost> createState() => _DetailHostState();
}

class _DetailHostState extends State<_DetailHost> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        showSourceContentDetailSheet(
          context,
          gateway: _FixtureGateway(),
          pluginId: AliceBookHouseDetailFixture.pluginId,
          id: AliceBookHouseDetailFixture.bookId,
          onAddToShelf: widget.onAddToShelf,
          onExternalUrlRequested: (_) async => true,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold();
}

final class _FixtureGateway implements SourceContentGateway {
  @override
  Future<PluginContentDetail> getDetail({required String pluginId, required String id}) async => AliceBookHouseDetailFixture.detail;

  @override
  Future<PluginChaptersResult> getChapters({required String pluginId, required String id}) async =>
      AliceBookHouseDetailFixture.firstCatalogPage;

  @override
  Future<List<PluginSourceDescriptor>> listSources() => throw UnimplementedError();

  @override
  Future<PluginSearchResult> search({required String pluginId, required String query, String? cursor, int pageSize = 20}) =>
      throw UnimplementedError();

  @override
  Future<PluginSearchSuggestionsResult> searchSuggestions({required String pluginId, String? cursor, int pageSize = 20}) =>
      throw UnimplementedError();

  @override
  Future<PluginDiscoverResult> discover({
    required String pluginId,
    String? target,
    String? cursor,
    String? collectionId,
    int pageSize = 20,
  }) => throw UnimplementedError();

  @override
  Future<PluginChapterContent> getContent({required String pluginId, required String id, required String chapterId}) =>
      throw UnimplementedError();
}

class _ShelfDetailHost extends StatefulWidget {
  @override
  State<_ShelfDetailHost> createState() => _ShelfDetailHostState();
}

class _ShelfDetailHostState extends State<_ShelfDetailHost> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        showSourceContentDetailSheet(
          context,
          gateway: _FixtureGateway(),
          pluginId: AliceBookHouseDetailFixture.pluginId,
          id: AliceBookHouseDetailFixture.bookId,
          shelfState: SourceDetailShelfState.alreadyAdded,
          onExternalUrlRequested: (_) async => true,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold();
}

class _ActionShelfDetailHost extends StatefulWidget {
  const _ActionShelfDetailHost({required this.onStartReading, this.onShelfAction});

  final SourceStartReadingRequested onStartReading;
  final SourceShelfActionRequested? onShelfAction;

  @override
  State<_ActionShelfDetailHost> createState() => _ActionShelfDetailHostState();
}

class _MangaDetailHost extends StatefulWidget {
  const _MangaDetailHost({required this.onComicChapterRequested});

  final SourceComicChapterRequested onComicChapterRequested;

  @override
  State<_MangaDetailHost> createState() => _MangaDetailHostState();
}

class _MangaDetailHostState extends State<_MangaDetailHost> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        showSourceContentDetailSheet(
          context,
          gateway: _MangaGateway(),
          pluginId: 'org.example.manga',
          id: 'manga-1',
          initialContent: _mangaSummary,
          initialCatalog: _mangaChapters,
          initialSourceName: '示例漫画源',
          onComicChapterRequested: widget.onComicChapterRequested,
          onExternalUrlRequested: (_) async => true,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold();
}

final class _MangaGateway implements SourceContentGateway {
  @override
  Future<PluginContentDetail> getDetail({required String pluginId, required String id}) async => _mangaDetail;

  @override
  Future<PluginChaptersResult> getChapters({required String pluginId, required String id}) async => _mangaChapters;

  @override
  Future<PluginChapterContent> getContent({required String pluginId, required String id, required String chapterId}) async =>
      PluginChapterContent(
        pluginId: pluginId,
        sourceName: '示例漫画源',
        contentKind: PluginContentKind.manga,
        chapterId: chapterId,
        title: '第一章',
        updatedAt: null,
        text: null,
        pages: <PluginMangaPage>[
          PluginMangaPage(
            id: 'image-1',
            index: 0,
            url: Uri.parse('https://example.com/manga/image-1.png'),
            mimeType: 'image/png',
            width: 100,
            height: 200,
            resourcePolicy: PluginMangaPageResourcePolicy.sessionOnly,
            expiresAt: null,
          ),
        ],
      );

  @override
  Future<List<PluginSourceDescriptor>> listSources() => throw UnimplementedError();

  @override
  Future<PluginSearchResult> search({required String pluginId, required String query, String? cursor, int pageSize = 20}) =>
      throw UnimplementedError();

  @override
  Future<PluginSearchSuggestionsResult> searchSuggestions({required String pluginId, String? cursor, int pageSize = 20}) =>
      throw UnimplementedError();

  @override
  Future<PluginDiscoverResult> discover({
    required String pluginId,
    String? target,
    String? cursor,
    String? collectionId,
    int pageSize = 20,
  }) => throw UnimplementedError();
}

const _mangaCoverBytes = <int>[1, 2, 3, 4];
final _mangaCoverUrl = Uri.parse('https://example.com/manga-cover.png');

final _mangaSummary = PluginContentSummary(
  id: 'manga-1',
  title: '示例漫画',
  contentKind: PluginContentKind.manga,
  author: '示例作者',
  url: null,
  coverUrl: _mangaCoverUrl,
  description: '示例漫画简介',
  language: 'zh-CN',
  status: PluginContentStatus.ongoing,
  access: PluginAccessKind.free,
  wordCount: null,
  chapterCount: 1,
  publishedAt: null,
  updatedAt: null,
  latestChapter: null,
  categories: const <String>[],
  tags: const <String>[],
  attributes: const <PluginContentAttribute>[],
);

final _mangaChapters = PluginChaptersResult(
  pluginId: 'org.example.manga',
  sourceName: '示例漫画源',
  items: <PluginChapterSummary>[
    PluginChapterSummary(
      id: 'manga-chapter-1',
      title: '第一章',
      order: 0,
      url: null,
      volumeTitle: null,
      wordCount: null,
      updatedAt: null,
      isLocked: false,
      attributes: <PluginContentAttribute>[],
    ),
  ],
);

final _mangaDetail = PluginContentDetail(
  pluginId: 'org.example.manga',
  sourceName: '示例漫画源',
  summary: _mangaSummary,
  aliases: const <String>[],
  catalogUrl: null,
);

class _ActionShelfDetailHostState extends State<_ActionShelfDetailHost> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        showSourceContentDetailSheet(
          context,
          gateway: _FixtureGateway(),
          pluginId: AliceBookHouseDetailFixture.pluginId,
          id: AliceBookHouseDetailFixture.bookId,
          shelfState: SourceDetailShelfState.alreadyAdded,
          onShelfAction: widget.onShelfAction ?? (_) async {},
          onStartReading: widget.onStartReading,
          useModalBottomSheet: true,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold();
}

class _DeferredShelfDetailHost extends StatefulWidget {
  const _DeferredShelfDetailHost({required this.seed});

  final Future<SourceContentDetailSeed> seed;

  @override
  State<_DeferredShelfDetailHost> createState() => _DeferredShelfDetailHostState();
}

class _DeferredShelfDetailHostState extends State<_DeferredShelfDetailHost> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        showDeferredSourceContentDetailSheet(
          context,
          seed: widget.seed,
          previewContent: _cachedPreview,
          gateway: _FixtureGateway(),
          shelfState: SourceDetailShelfState.alreadyAdded,
          onShelfAction: (_) async {},
          onStartReading: () async {},
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold();
}

final PluginContentSummary _cachedPreview = PluginContentSummary(
  id: 'cached-book',
  title: '缓存书名',
  contentKind: PluginContentKind.novel,
  author: '缓存作者',
  url: null,
  coverUrl: null,
  description: '缓存简介',
  language: 'zh-CN',
  status: PluginContentStatus.ongoing,
  access: PluginAccessKind.free,
  wordCount: 5652000,
  chapterCount: 999,
  publishedAt: null,
  updatedAt: null,
  latestChapter: null,
  categories: const <String>['都市'],
  tags: const <String>[],
  attributes: const <PluginContentAttribute>[PluginContentAttribute(key: 'heat', label: '热度', value: '565.2万')],
);
