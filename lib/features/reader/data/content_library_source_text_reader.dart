import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';

import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/reader/application/library_reader_launcher.dart';
import 'package:mg_read/features/reader/application/reader_launch_failure.dart';
import 'package:mg_read/features/reader/application/reader_launch_request.dart';
import 'package:mg_read/features/reader/data/content_library_text_reader_state_store.dart';
import 'package:mg_read/features/reader/data/transient_source_text_reader.dart';

/// Opens a shelf novel with app-owned reading state and a typed source gateway.
///
/// A newly added title starts from the first remote catalog page, just like
/// discovery. Existing app-owned catalog and body cache data remains readable
/// through the cached path without exposing Runtime transport to the reader.
final class ContentLibrarySourceTextReader implements LibraryReaderLauncher {
  const ContentLibrarySourceTextReader(this._library, this._gateway);

  final ContentLibrary _library;
  final SourceContentGateway _gateway;

  @override
  Future<ReaderLaunchRequest> launch(
    String libraryItemId, {
    ReaderObserver? observer,
  }) async {
    final item = await _library.getLibraryItem(LibraryItemId(libraryItemId));
    if (item == null) {
      throw _failure(
        ReaderLaunchFailureReason.shelfItemMissing,
        AppErrorCode.notFound,
      );
    }
    if (item.kind != ContentKind.novel) {
      throw _failure(
        ReaderLaunchFailureReason.unsupportedContentKind,
        AppErrorCode.unsupported,
      );
    }
    final source = item.source;
    if (source == null) {
      throw _failure(
        ReaderLaunchFailureReason.shelfSourceMissing,
        AppErrorCode.invalidFormat,
      );
    }

    final catalog = await _library.listAllCatalog(item.id);
    if (catalog.isEmpty) {
      return _launchLiveSession(item, source, observer);
    }
    final detail = await _loadDetailOrCachedFallback(item, source, catalog);
    if (detail.summary.contentKind != PluginContentKind.novel) {
      throw _failure(
        ReaderLaunchFailureReason.sourceContentKind,
        AppErrorCode.unsupported,
      );
    }
    final localCatalog = _asSourceCatalog(source, detail.sourceName, catalog);
    final chapterAccess = _CachedNovelChapterAccess(
      library: _library,
      gateway: _gateway,
      item: item,
      source: source,
    );
    final stateStore = ContentLibraryTextReaderStateStore(
      _library,
      itemId: item.id,
    );
    final session = TransientSourceTextReader(
      detail: detail,
      firstCatalogPage: localCatalog,
      loadChapterPage: ({String? cursor, int pageSize = _catalogPageSize}) {
        if (cursor != null) {
          throw StateError('Catalog is complete.');
        }
        return Future<PluginChaptersResult>.value(localCatalog);
      },
      loadChapterContent: chapterAccess.load,
      bookId: item.id.value,
    );
    return session.createLaunchRequest(
      initialChapterId: localCatalog.items.first.id,
      observer: _TimedReaderObserver(stateStore, observer),
      stateStore: stateStore,
      extensions: ReaderExtensions(chapterStateCapability: chapterAccess),
    );
  }

  /// A newly added shelf item has no local catalog yet.  Start it with the
  /// same first-page, paginated source session used by discovery instead of
  /// blocking on downloading and committing an entire catalog first.
  Future<ReaderLaunchRequest> _launchLiveSession(
    LibraryItem item,
    LibraryItemSource source,
    ReaderObserver? observer,
  ) async {
    final detail = await _resolve(
      ReaderLaunchFailureReason.sourceDetail,
      () => _gateway.getDetail(
        pluginId: source.pluginId,
        id: source.remoteContentId,
      ),
    );
    if (detail.summary.contentKind != PluginContentKind.novel) {
      throw _failure(
        ReaderLaunchFailureReason.sourceContentKind,
        AppErrorCode.unsupported,
      );
    }
    final firstCatalogPage = await _resolve(
      ReaderLaunchFailureReason.sourceCatalog,
      () => _gateway.getChapters(
        pluginId: source.pluginId,
        id: source.remoteContentId,
        pageSize: _catalogPageSize,
      ),
    );
    if (firstCatalogPage.items.isEmpty) {
      throw _failure(
        ReaderLaunchFailureReason.sourceCatalogEmpty,
        AppErrorCode.notFound,
      );
    }
    final stateStore = ContentLibraryTextReaderStateStore(
      _library,
      itemId: item.id,
    );
    final session = TransientSourceTextReader(
      detail: detail,
      firstCatalogPage: firstCatalogPage,
      loadChapterPage: ({String? cursor, int pageSize = _catalogPageSize}) {
        return _gateway.getChapters(
          pluginId: source.pluginId,
          id: source.remoteContentId,
          cursor: cursor,
          pageSize: pageSize.clamp(1, _catalogPageSize),
        );
      },
      loadChapterContent: (String chapterId) => _gateway.getContent(
        pluginId: source.pluginId,
        id: source.remoteContentId,
        chapterId: chapterId,
      ),
      bookId: item.id.value,
    );
    return session.createLaunchRequest(
      initialChapterId: firstCatalogPage.items.first.id,
      observer: _TimedReaderObserver(stateStore, observer),
      stateStore: stateStore,
    );
  }

  Future<PluginContentDetail> _loadDetailOrCachedFallback(
    LibraryItem item,
    LibraryItemSource source,
    List<CatalogEntry> catalog,
  ) async {
    try {
      return await _gateway.getDetail(
        pluginId: source.pluginId,
        id: source.remoteContentId,
      );
    } on Object {
      return PluginContentDetail(
        pluginId: source.pluginId,
        sourceName: item.sourceName ?? '书架缓存',
        summary: PluginContentSummary(
          id: source.remoteContentId,
          title: item.title,
          contentKind: PluginContentKind.novel,
          author: item.author,
          url: null,
          coverUrl: item.coverUrl,
          description: null,
          language: null,
          status: PluginContentStatus.unknown,
          access: PluginAccessKind.unknown,
          wordCount: null,
          chapterCount: catalog.length,
          publishedAt: null,
          updatedAt: null,
          latestChapter: null,
          categories: const <String>[],
          tags: const <String>[],
          attributes: const <PluginContentAttribute>[],
        ),
        aliases: const <String>[],
        catalogUrl: null,
      );
    }
  }

  PluginChaptersResult _asSourceCatalog(
    LibraryItemSource source,
    String sourceName,
    List<CatalogEntry> catalog,
  ) => PluginChaptersResult(
    pluginId: source.pluginId,
    sourceName: sourceName,
    items: <PluginChapterSummary>[
      for (final entry in catalog)
        PluginChapterSummary(
          id: entry.remoteIdentity,
          title: entry.title,
          order: entry.index,
          url: null,
          volumeTitle: null,
          wordCount: entry.wordCount,
          updatedAt: null,
          isLocked: null,
          attributes: const <PluginContentAttribute>[],
        ),
    ],
    nextCursor: null,
    totalCount: catalog.length,
  );

  static const int _catalogPageSize = 20;

  Future<T> _resolve<T>(
    ReaderLaunchFailureReason reason,
    Future<T> Function() action,
  ) async {
    try {
      return await action();
    } on ReaderLaunchFailure {
      rethrow;
    } on Object catch (error) {
      throw ReaderLaunchFailure(
        reason: reason,
        error: AppError.fromUnknown(error),
      );
    }
  }

  ReaderLaunchFailure _failure(
    ReaderLaunchFailureReason reason,
    AppErrorCode code,
  ) => ReaderLaunchFailure(reason: reason, error: AppError.fromCode(code));
}

/// Preserves host callbacks while synchronizing foreground reading duration.
final class _TimedReaderObserver extends ReaderObserver {
  const _TimedReaderObserver(this._stateStore, this._delegate);

  final ContentLibraryTextReaderStateStore _stateStore;
  final ReaderObserver? _delegate;

  @override
  Future<void> onSessionStarted(String bookId) async {
    await _delegate?.onSessionStarted(bookId);
  }

  @override
  Future<void> onSessionEnded(String bookId, ReaderProgress? progress) async {
    _stateStore.finishSession();
    await _delegate?.onSessionEnded(bookId, progress);
  }

  @override
  Future<void> onLifecycleChanged(
    ReaderLifecycleState state,
    ReaderProgress? progress,
  ) async {
    _stateStore.onLifecycleChanged(state);
    await _delegate?.onLifecycleChanged(state, progress);
  }

  @override
  Future<void> onChapterChanged(ReaderChapterInfo chapter) async {
    await _delegate?.onChapterChanged(chapter);
  }

  @override
  Future<void> onFailure(ReaderFailure failure) async {
    await _delegate?.onFailure(failure);
  }

  @override
  Future<void> onExitRequested(ReaderProgress? progress) async {
    await _delegate?.onExitRequested(progress);
  }
}

/// Host-side cache and mutable state exposed through the reader's public API.
final class _CachedNovelChapterAccess implements ReaderChapterStateCapability {
  _CachedNovelChapterAccess({
    required this.library,
    required this.gateway,
    required this.item,
    required this.source,
  });

  final ContentLibrary library;
  final SourceContentGateway gateway;
  final LibraryItem item;
  final LibraryItemSource source;
  final Set<String> _readChapterIds = <String>{};
  final Set<String> _failedChapterIds = <String>{};
  final Map<String, Future<PluginChapterContent>> _loading =
      <String, Future<PluginChapterContent>>{};

  Future<PluginChapterContent> load(String chapterId) {
    final active = _loading[chapterId];
    if (active != null) return active;
    final task = _loadAndCache(chapterId);
    _loading[chapterId] = task;
    return task.whenComplete(() => _loading.remove(chapterId));
  }

  Future<PluginChapterContent> _loadAndCache(String chapterId) async {
    final entries = await library.listAllCatalog(item.id);
    final matches = entries.where((entry) => entry.remoteIdentity == chapterId);
    if (matches.length != 1) {
      throw ArgumentError.value(chapterId, 'chapterId', 'Unknown chapter.');
    }
    final entry = matches.single;
    final cached = await library.openContent(entry.id);
    if (cached case NovelChapterContent(:final text)) {
      return PluginChapterContent(
        pluginId: source.pluginId,
        sourceName: item.sourceName ?? '书架缓存',
        contentKind: PluginContentKind.novel,
        chapterId: chapterId,
        title: entry.title,
        updatedAt: null,
        text: text,
        pages: const <PluginMangaPage>[],
      );
    }
    try {
      final remote = await gateway.getContent(
        pluginId: source.pluginId,
        id: source.remoteContentId,
        chapterId: chapterId,
      );
      if (remote.contentKind != PluginContentKind.novel ||
          remote.text == null) {
        throw StateError('The source chapter is not a text-reader chapter.');
      }
      // The validated remote text is already usable. A cache-write failure
      // must not turn it into a reader failure.
      try {
        await library.cacheNovelChapter(
          itemId: item.id,
          remoteChapterId: chapterId,
          text: remote.text!,
        );
      } on Object {
        // Keep reading; a later request can retry the cache write.
      }
      _failedChapterIds.remove(chapterId);
      return remote;
    } on Object {
      _failedChapterIds.add(chapterId);
      rethrow;
    }
  }

  @override
  Future<Map<String, ReaderChapterState>> loadChapterStates(
    String bookId,
    List<String> chapterIds,
  ) async {
    _requireBook(bookId);
    final entries = await library.listAllCatalog(item.id);
    final entryByRemoteId = <String, CatalogEntry>{
      for (final entry in entries) entry.remoteIdentity: entry,
    };
    final progress = await library.readingProgress.load(item.id);
    return <String, ReaderChapterState>{
      for (final chapterId in chapterIds)
        if (entryByRemoteId[chapterId] case final entry?)
          chapterId: ReaderChapterState(
            chapterId: chapterId,
            availability: _availability(entry),
            wordCount: entry.wordCount,
            hasBeenRead:
                _readChapterIds.contains(chapterId) ||
                (progress != null && entry.index <= progress.chapterIndex),
          ),
    };
  }

  @override
  Future<void> markRead(String bookId, String chapterId) async {
    _requireBook(bookId);
    _readChapterIds.add(chapterId);
  }

  ReaderChapterAvailability _availability(CatalogEntry entry) {
    if (entry.contentStatus == 'ready') {
      return ReaderChapterAvailability.downloaded;
    }
    if (_loading.containsKey(entry.remoteIdentity)) {
      return ReaderChapterAvailability.downloading;
    }
    if (_failedChapterIds.contains(entry.remoteIdentity)) {
      return ReaderChapterAvailability.failed;
    }
    return ReaderChapterAvailability.notDownloaded;
  }

  void _requireBook(String bookId) {
    if (bookId != item.id.value) {
      throw ArgumentError.value(bookId, 'bookId', 'Unexpected reader book ID.');
    }
  }
}
