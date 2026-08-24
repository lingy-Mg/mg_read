import 'dart:async';

import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';

/// Warms the app-owned source data immediately after a book is added.
///
/// The first catalog page is committed before the first chapter is cached, so
/// a user can open the shelf while the remaining catalog pages are still
/// downloading. All failures are isolated to this best-effort background
/// task; the shelf mutation itself has already committed successfully.
final class ContentLibrarySourcePrefetcher {
  ContentLibrarySourcePrefetcher(
    this._library,
    this._gateway, {
    this._diagnostics,
  });

  final ContentLibrary _library;
  final SourceContentGateway _gateway;
  final DiagnosticsManager? _diagnostics;
  final Map<String, Future<void>> _active = <String, Future<void>>{};

  /// Starts one deduplicated warm-up without blocking the add-to-shelf UI.
  void start(LibraryItem item) {
    final source = item.source;
    if (source == null || item.kind != ContentKind.novel) return;
    final key = item.id.value;
    if (_active.containsKey(key)) return;
    final task = _run(item, source);
    _active[key] = task;
    unawaited(
      task.then<void>(
        (_) => _active.remove(key),
        onError: (Object error, StackTrace stack) {
          _active.remove(key);
        },
      ),
    );
  }

  /// Waits for an already-started warm-up, mainly for host lifecycle tests.
  Future<void> waitFor(String libraryItemId) =>
      _active[libraryItemId] ?? Future<void>.value();

  Future<void> _run(LibraryItem item, LibraryItemSource source) async {
    final diagnostics = _diagnostics;
    final span = diagnostics?.startSpan(
      AppDiagnosticEvents.readerPrefetch,
      attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
        'contentKind': DiagnosticValue.string(ContentKind.novel.code),
        'resultState': DiagnosticValue.string('started'),
      }),
    );
    var catalogCount = 0;
    var cachedChapterCount = 0;
    try {
      final detailFuture = _loadDetail(source);
      final firstPage = await _gateway.getChapters(
        pluginId: source.pluginId,
        id: source.remoteContentId,
        pageSize: _pageSize,
      );
      if (firstPage.items.isEmpty) {
        span?.complete(
          attributes: _attributes(
            catalogCount: 0,
            cachedChapterCount: 0,
            resultState: 'empty',
          ),
        );
        return;
      }

      final firstCatalog = _toCatalog(firstPage.items);
      // If the source already returned the complete catalog, wait for the
      // single page and persist it once. Persisting firstPage and then the
      // same complete page doubles JSON encoding and metadata writes for large
      // books such as sources that ignore the requested page size.
      if (firstPage.nextCursor != null) {
        await _library.syncNovelCatalog(
          itemId: item.id,
          chapters: firstCatalog,
        );
      }

      final firstContent = _gateway.getContent(
        pluginId: source.pluginId,
        id: source.remoteContentId,
        chapterId: firstPage.items.first.id,
      );
      final allPages = _loadAllPages(source, firstPage);

      try {
        final content = await firstContent;
        if (content.contentKind == PluginContentKind.novel &&
            content.text != null &&
            content.text!.isNotEmpty) {
          await _library.cacheNovelChapter(
            itemId: item.id,
            remoteChapterId: firstPage.items.first.id,
            text: content.text!,
          );
          cachedChapterCount = 1;
        }
      } on Object {
        // The reader can retry a missing first chapter on demand.
      }

      final allChapters = await allPages;
      catalogCount = allChapters.length;
      await _library.syncNovelCatalog(
        itemId: item.id,
        chapters: _toCatalog(allChapters),
      );

      final detail = await detailFuture;
      if (detail != null) {
        await _library.bookshelf.addFromSource(
          BookshelfAddRequest(
            title: detail.summary.title.isEmpty
                ? item.title
                : detail.summary.title,
            author: detail.summary.author ?? item.author,
            kind: ContentKind.novel,
            pluginId: source.pluginId,
            pluginVersion: source.pluginVersion,
            remoteContentId: source.remoteContentId,
            coverUrl: detail.summary.coverUrl ?? item.coverUrl,
            sourceName: detail.sourceName.isEmpty
                ? item.sourceName
                : detail.sourceName,
          ),
        );
      }
      span?.complete(
        attributes: _attributes(
          catalogCount: catalogCount,
          cachedChapterCount: cachedChapterCount,
          resultState: 'complete',
        ),
      );
    } on Object {
      span?.fail(
        attributes: _attributes(
          catalogCount: catalogCount,
          cachedChapterCount: cachedChapterCount,
          resultState: catalogCount == 0 ? 'failed' : 'partial',
          errorCode: 'prefetch_failed',
        ),
      );
      // This is intentionally best effort. A later reader launch retries the
      // source and preserves whatever catalog/body data already committed.
    }
  }

  Future<PluginContentDetail?> _loadDetail(LibraryItemSource source) async {
    try {
      return await _gateway.getDetail(
        pluginId: source.pluginId,
        id: source.remoteContentId,
      );
    } on Object {
      return null;
    }
  }

  Future<List<PluginChapterSummary>> _loadAllPages(
    LibraryItemSource source,
    PluginChaptersResult firstPage,
  ) async {
    final chapters = <PluginChapterSummary>[...firstPage.items];
    var cursor = firstPage.nextCursor;
    final seenCursors = <String>{};
    while (cursor != null) {
      if (!seenCursors.add(cursor)) {
        throw StateError('The source returned a repeated catalog cursor.');
      }
      final page = await _gateway.getChapters(
        pluginId: source.pluginId,
        id: source.remoteContentId,
        cursor: cursor,
        pageSize: _pageSize,
      );
      if (page.items.isEmpty) {
        throw StateError('The source returned an empty catalog page.');
      }
      chapters.addAll(page.items);
      cursor = page.nextCursor;
    }
    final seenChapterIds = <String>{};
    for (final chapter in chapters) {
      if (!seenChapterIds.add(chapter.id)) {
        throw StateError('The source returned a duplicate chapter ID.');
      }
    }
    return chapters;
  }

  List<SourceNovelCatalogChapter> _toCatalog(
    Iterable<PluginChapterSummary> chapters,
  ) => [
    for (var index = 0; index < chapters.length; index += 1)
      SourceNovelCatalogChapter(
        remoteIdentity: chapters.elementAt(index).id,
        title: chapters.elementAt(index).title,
        index: index,
        wordCount: chapters.elementAt(index).wordCount,
      ),
  ];

  DiagnosticObjectValue _attributes({
    required int catalogCount,
    required int cachedChapterCount,
    required String resultState,
    String? errorCode,
  }) => DiagnosticObjectValue(<String, DiagnosticValue>{
    'contentKind': DiagnosticValue.string(ContentKind.novel.code),
    'chapterCount': DiagnosticValue.int64(catalogCount),
    'cachedChapterCount': DiagnosticValue.int64(cachedChapterCount),
    'resultState': DiagnosticValue.string(resultState),
    if (errorCode != null) 'errorCode': DiagnosticValue.string(errorCode),
  });

  static const int _pageSize = 50;
}
