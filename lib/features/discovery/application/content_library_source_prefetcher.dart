import 'dart:async';

import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';

/// Warms the app-owned source data immediately after a book is added.
///
/// The complete catalog is committed atomically before the first chapter is
/// cached. All failures are isolated to this best-effort background task; the
/// shelf mutation itself has already committed successfully.
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
      final catalogResult = await _gateway.getChapters(
        pluginId: source.pluginId,
        id: source.remoteContentId,
      );
      if (catalogResult.items.isEmpty) {
        span?.complete(
          attributes: _attributes(
            catalogCount: 0,
            cachedChapterCount: 0,
            resultState: 'empty',
          ),
        );
        return;
      }

      final firstContent = _gateway.getContent(
        pluginId: source.pluginId,
        id: source.remoteContentId,
        chapterId: catalogResult.items.first.id,
      );
      final catalog = await _library.syncNovelCatalog(
        itemId: item.id,
        chapters: _toCatalog(catalogResult.items),
      );
      catalogCount = catalog.length;

      try {
        final content = await firstContent;
        if (content.contentKind == PluginContentKind.novel &&
            content.text != null &&
            content.text!.isNotEmpty) {
          await _library.cacheNovelChapter(
            itemId: item.id,
            remoteChapterId: catalogResult.items.first.id,
            text: content.text!,
          );
          cachedChapterCount = 1;
        }
      } on Object {
        // The reader can retry a missing first chapter on demand.
      }

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
}
