import 'dart:async';

import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/features/discovery/application/persisted_source_detail.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';

/// Warms the app-owned source data immediately after a book is added.
///
/// Catalog commit and the first chapter request overlap. A validated first
/// body is exposed to a waiting reader immediately while its immutable object
/// write continues in the background.
final class ContentLibrarySourcePrefetcher {
  ContentLibrarySourcePrefetcher(this._library, this._gateway, {this._diagnostics});

  final ContentLibrary _library;
  final SourceContentGateway _gateway;
  final DiagnosticsManager? _diagnostics;
  final Map<String, Future<void>> _active = <String, Future<void>>{};
  final Map<String, Completer<void>> _readable = <String, Completer<void>>{};
  final Map<String, ContentLibraryPrefetchedNovelChapter> _prepared = <String, ContentLibraryPrefetchedNovelChapter>{};

  /// Starts one deduplicated warm-up without blocking the add-to-shelf UI.
  void start(LibraryItem item) {
    final source = item.source;
    if (item.kind != ContentKind.novel) return;
    final key = item.id.value;
    if (_active.containsKey(key)) return;
    final readable = Completer<void>();
    // A best-effort warm-up may fail before any reader is waiting. Keep the
    // error available to an explicit prepareForReading caller while handling
    // the otherwise-unobserved completer future.
    unawaited(readable.future.catchError((Object error, StackTrace stack) {}));
    _readable[key] = readable;
    final task = _run(item, source, readable);
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

  /// Reuses an in-flight add-to-shelf warm-up only until a readable body is
  /// available. Optional detail projection work continues in the background.
  Future<void> prepareForReading(LibraryItem item) {
    start(item);
    return _readable[item.id.value]?.future ?? Future<void>.value();
  }

  /// Takes a memory body prepared for the reader while persistence is pending.
  ContentLibraryPrefetchedNovelChapter? takePreparedChapter(String libraryItemId) => _prepared.remove(libraryItemId);

  bool hasInFlight(String libraryItemId) => _active.containsKey(libraryItemId) || _readable.containsKey(libraryItemId);

  /// Waits for an already-started warm-up, mainly for host lifecycle tests.
  Future<void> waitFor(String libraryItemId) => _active[libraryItemId] ?? Future<void>.value();

  Future<void> _run(LibraryItem item, LibraryItemSource source, Completer<void> readable) async {
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
      final catalogResult = await _gateway.getChapters(pluginId: source.pluginId, id: source.remoteContentId);
      if (catalogResult.items.isEmpty) {
        if (!readable.isCompleted) {
          readable.completeError(StateError('Source catalog is empty.'));
        }
        span?.complete(attributes: _attributes(catalogCount: 0, cachedChapterCount: 0, resultState: 'empty'));
        return;
      }

      final firstContent = _gateway.getContent(
        pluginId: source.pluginId,
        id: source.remoteContentId,
        chapterId: catalogResult.items.first.id,
      );
      final results = await Future.wait<Object>(<Future<Object>>[
        _library.syncNovelCatalog(itemId: item.id, chapters: _toCatalog(catalogResult.items)),
        firstContent,
      ]);
      catalogCount = results[0] as int;
      final content = results[1] as PluginChapterContent;
      if (content.contentKind == PluginContentKind.novel && content.text != null && content.text!.isNotEmpty) {
        final chapterId = catalogResult.items.first.id;
        final persistence = _library
            .cacheNovelChapter(itemId: item.id, remoteChapterId: chapterId, text: content.text!)
            .then<void>((_) {}, onError: (Object _, StackTrace stack) {});
        final prepared = ContentLibraryPrefetchedNovelChapter(chapterId: chapterId, text: content.text!, persistence: persistence);
        _prepared[item.id.value] = prepared;
        unawaited(
          persistence.whenComplete(() {
            if (identical(_prepared[item.id.value], prepared)) _prepared.remove(item.id.value);
          }),
        );
        cachedChapterCount = 1;
      }

      // Catalog and first body are the reading readiness boundary.  Detail is
      // a best-effort shelf projection and must not keep a shelf tap waiting
      // after the first readable chapter is already durable.
      if (!readable.isCompleted) readable.complete();

      final detail = await detailFuture;
      if (detail != null) {
        await _library.addLibraryItem(
          BookshelfAddRequest(
            title: detail.summary.title.isEmpty ? item.title : detail.summary.title,
            author: detail.summary.author ?? item.author,
            kind: ContentKind.novel,
            pluginId: source.pluginId,
            pluginVersion: source.pluginVersion,
            remoteContentId: source.remoteContentId,
            coverUrl: detail.summary.coverUrl ?? item.coverUrl,
            sourceName: detail.sourceName.isEmpty ? item.sourceName : detail.sourceName,
            sourceUrl: detail.catalogUrl ?? detail.summary.url ?? item.sourceUrl,
            description: detail.summary.description,
            language: detail.summary.language,
            accessCode: detail.summary.access.code,
            wordCount: detail.summary.wordCount,
            chapterCount: detail.summary.chapterCount,
            publishedAt: detail.summary.publishedAt,
            updatedAt: detail.summary.updatedAt,
            statusLabel: _statusLabel(detail.summary.status),
            latestChapterId: detail.summary.latestChapter?.id,
            latestChapterTitle: detail.summary.latestChapter?.title,
            latestChapterUrl: detail.summary.latestChapter?.url,
            latestChapterUpdatedAt: detail.summary.latestChapter?.updatedAt,
            categories: detail.summary.categories,
            tags: detail.summary.tags,
            attributes: <LibraryItemAttribute>[
              for (final attribute in detail.summary.attributes)
                LibraryItemAttribute(key: attribute.key, label: attribute.label, value: attribute.value),
            ],
            sourceDetail: encodePersistedSourceDetail(detail),
            labels: <String>[
              ...detail.summary.categories,
              ...detail.summary.tags,
              for (final attribute in detail.summary.attributes) attribute.value,
            ],
          ),
        );
      }
      span?.complete(
        attributes: _attributes(catalogCount: catalogCount, cachedChapterCount: cachedChapterCount, resultState: 'complete'),
      );
    } on Object {
      if (!readable.isCompleted) {
        readable.completeError(StateError('Reader preparation failed.'));
      }
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
    } finally {
      _readable.remove(item.id.value);
    }
  }

  Future<PluginContentDetail?> _loadDetail(LibraryItemSource source) async {
    try {
      return await _gateway.getDetail(pluginId: source.pluginId, id: source.remoteContentId);
    } on Object {
      return null;
    }
  }

  List<SourceNovelCatalogChapter> _toCatalog(Iterable<PluginChapterSummary> chapters) => [
    for (var index = 0; index < chapters.length; index += 1)
      SourceNovelCatalogChapter(
        remoteIdentity: chapters.elementAt(index).id,
        title: chapters.elementAt(index).title,
        index: index,
        wordCount: chapters.elementAt(index).wordCount,
        chapterUrl: chapters.elementAt(index).url,
      ),
  ];

  String? _statusLabel(PluginContentStatus status) => switch (status) {
    PluginContentStatus.ongoing => '连载',
    PluginContentStatus.completed => '已完结',
    PluginContentStatus.hiatus => '暂停更新',
    PluginContentStatus.unknown => null,
  };

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

/// One validated first chapter shared with a reader before its cache write ends.
final class ContentLibraryPrefetchedNovelChapter {
  const ContentLibraryPrefetchedNovelChapter({required this.chapterId, required this.text, required this.persistence});

  final String chapterId;
  final String text;
  final Future<void> persistence;
}
