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
/// A newly added title persists its first remote catalog page before the
/// reader asks for text. This makes that page's chapter identities available
/// to the app-owned body cache on the first read and on later launches.
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
    if (catalog.isEmpty ||
        catalog.any((entry) => !entry.hasExplicitRemoteIdentity)) {
      // Legacy snapshots did not persist the remote chapter ID separately
      // from the binding key. Refresh them before constructing the reader so
      // a source ID containing ':' cannot reach the reader truncated.
      return _launchLiveSession(item, source, observer);
    }
    final localCatalog = _asSourceCatalog(
      source,
      item.sourceName ?? '书架缓存',
      catalog,
    );
    final detail = await _resolveDetail(
      item,
      source,
      chapterCount: catalog.length,
    );
    final chapterAccess = _CachedNovelChapterAccess(
      library: _library,
      gateway: _gateway,
      item: item,
      source: source,
      catalog: catalog,
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
    final detail = await _resolveDetail(
      item,
      source,
      chapterCount:
          firstCatalogPage.totalCount ?? firstCatalogPage.items.length,
    );
    final catalog = await _library.syncNovelCatalog(
      itemId: item.id,
      chapters: firstCatalogPage.items
          .map(
            (chapter) => SourceNovelCatalogChapter(
              remoteIdentity: chapter.id,
              title: chapter.title,
              index: chapter.order,
              wordCount: chapter.wordCount,
            ),
          )
          .toList(growable: false),
    );
    final chapterAccess = _CachedNovelChapterAccess(
      library: _library,
      gateway: _gateway,
      item: item,
      source: source,
      catalog: catalog,
    );
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
      loadChapterContent: chapterAccess.load,
      bookId: item.id.value,
    );
    return session.createLaunchRequest(
      initialChapterId: firstCatalogPage.items.first.id,
      observer: _TimedReaderObserver(stateStore, observer),
      stateStore: stateStore,
      extensions: ReaderExtensions(chapterStateCapability: chapterAccess),
    );
  }

  Future<PluginContentDetail> _resolveDetail(
    LibraryItem item,
    LibraryItemSource source, {
    required int chapterCount,
  }) async {
    final fallback = _localDetail(item, source, chapterCount: chapterCount);
    try {
      final remote = await _gateway.getDetail(
        pluginId: source.pluginId,
        id: source.remoteContentId,
      );
      final summary = remote.summary;
      return PluginContentDetail(
        pluginId: remote.pluginId,
        sourceName: remote.sourceName.isEmpty
            ? fallback.sourceName
            : remote.sourceName,
        summary: PluginContentSummary(
          id: summary.id,
          title: summary.title.isEmpty ? fallback.summary.title : summary.title,
          contentKind: summary.contentKind,
          author: summary.author ?? fallback.summary.author,
          url: summary.url,
          coverUrl: summary.coverUrl ?? fallback.summary.coverUrl,
          description: summary.description,
          language: summary.language,
          status: summary.status,
          access: summary.access,
          wordCount: summary.wordCount,
          chapterCount: summary.chapterCount ?? chapterCount,
          publishedAt: summary.publishedAt,
          updatedAt: summary.updatedAt,
          latestChapter: summary.latestChapter,
          categories: summary.categories,
          tags: summary.tags,
          attributes: summary.attributes,
        ),
        aliases: remote.aliases,
        catalogUrl: remote.catalogUrl ?? summary.url,
      );
    } on Object {
      // A shelf must remain readable when refreshing optional presentation
      // metadata fails; the local projection still carries title and source.
      return fallback;
    }
  }

  PluginContentDetail _localDetail(
    LibraryItem item,
    LibraryItemSource source, {
    required int chapterCount,
  }) => PluginContentDetail(
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
      chapterCount: chapterCount,
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
    required List<CatalogEntry> catalog,
  }) : _entryByRemoteId = Map<String, CatalogEntry>.unmodifiable({
         for (final entry in catalog) entry.remoteIdentity: entry,
       });

  final ContentLibrary library;
  final SourceContentGateway gateway;
  final LibraryItem item;
  final LibraryItemSource source;
  final Map<String, CatalogEntry> _entryByRemoteId;
  final Set<String> _readChapterIds = <String>{};
  final Set<String> _cachedChapterIds = <String>{};
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
    final entry = _entryByRemoteId[chapterId];
    if (entry == null) {
      throw ArgumentError.value(chapterId, 'chapterId', 'Unknown chapter.');
    }
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
        _cachedChapterIds.add(chapterId);
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
    final progress = await library.readingProgress.load(item.id);
    return <String, ReaderChapterState>{
      for (final chapterId in chapterIds)
        if (_entryByRemoteId[chapterId] case final entry?)
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
    if (entry.contentStatus == 'ready' ||
        _cachedChapterIds.contains(entry.remoteIdentity)) {
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
