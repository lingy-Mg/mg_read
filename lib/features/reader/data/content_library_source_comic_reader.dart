/// Content Library-backed comic catalog, manifest and image session adapter.
///
/// Runtime supplies catalogs and regenerable manifests; Content Library owns
/// the catalog, URL-safe manifest, progress, bookmarks, and persistent images.
/// Session resource state and request single-flights stay in this file. Live
/// manifests use a three-entry LRU so visiting chapters cannot grow session
/// memory without bound. An injected fetcher remains caller-owned; otherwise
/// the extracted HTTP transport is disposed with this data source.
/// Durable or still-valid refreshable manifests open locally; session-only or
/// expired manifests refresh through Runtime before their resources are used.
/// A dead worker or expired resource permits one manifest refresh for regenerable pages.
/// State and transport remain re-exported for existing app composition callers.
library;

import 'dart:typed_data';

import 'package:novel_reader_ui/novel_reader_ui.dart';

import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/discovery/application/source_manga_projection.dart';
import 'package:mg_read/features/reader/application/reader_launch_request.dart';
import 'package:mg_read/features/reader/data/bounded_reader_session_cache.dart';
import 'package:mg_read/features/reader/data/comic_image_transport.dart';

export 'comic_image_transport.dart';
export 'content_library_comic_reader_state_store.dart';

/// Content Library adapter for a source-backed comic session.
final class ContentLibraryComicReaderDataSource
    implements ComicReaderDataSource, ComicReaderImageCacheStateDataSource, DisposableReaderDataSource, ReaderCatalogRefreshDataSource {
  ContentLibraryComicReaderDataSource({
    required this.library,
    required this.gateway,
    required this.item,
    ComicImageFetcher? fetcher,
    ComicHttpClientFactory? httpClientFactory,
  }) : assert(fetcher == null || httpClientFactory == null),
       _externalFetcher = fetcher,
       _httpClientOwner = fetcher == null ? createComicImageHttpClientOwner(httpClientFactory) : null;

  static const _maximumImageBytes = 8 * 1024 * 1024;

  final ContentLibrary library;
  final SourceContentGateway gateway;
  LibraryItem item;
  final ComicImageFetcher? _externalFetcher;
  final ComicImageHttpClientOwner? _httpClientOwner;
  _CatalogSnapshot? _catalog;
  Future<_CatalogSnapshot>? _catalogLoading;
  final BoundedReaderSessionCache<String, _ChapterManifest> _manifests = BoundedReaderSessionCache<String, _ChapterManifest>(maxEntries: 3);
  final Map<String, Future<_ChapterManifest>> _runtimeManifestLoads = <String, Future<_ChapterManifest>>{};
  final Map<String, Future<Uint8List>> _imageLoads = <String, Future<Uint8List>>{};
  final Map<String, Uint8List> _preparedImages = <String, Uint8List>{};
  bool _usedNetwork = false;
  bool _disposed = false;

  /// Resolves the target manifest and first image before shelf navigation.
  Future<({int estimatedBytes, ReaderLaunchPreparationKind kind, Duration networkElapsed})> prepareFirstContent() async {
    _ensureActive();
    _usedNetwork = false;
    final stopwatch = Stopwatch()..start();
    final session = (await _ensureCatalog()).session;
    if (session == null) {
      stopwatch.stop();
      return (
        estimatedBytes: 0,
        kind: _usedNetwork ? ReaderLaunchPreparationKind.network : ReaderLaunchPreparationKind.persistent,
        networkElapsed: _usedNetwork ? stopwatch.elapsed : Duration.zero,
      );
    }
    final entry = session.initialChapter;
    final content = await loadChapterContent(item.id.value, entry.remoteIdentity);
    if (content.images.isEmpty) throw StateError('Source manga manifest is empty.');
    final first = content.images.first;
    final bytes = await loadImageBytes(item.id.value, entry.remoteIdentity, first.id);
    _preparedImages['${entry.remoteIdentity}\u0000${first.id}'] = bytes;
    stopwatch.stop();
    return (
      estimatedBytes: bytes.lengthInBytes,
      kind: _usedNetwork ? ReaderLaunchPreparationKind.network : ReaderLaunchPreparationKind.persistent,
      networkElapsed: _usedNetwork ? stopwatch.elapsed : Duration.zero,
    );
  }

  /// Warms only a fully local target manifest and first image.
  Future<int?> warmLocalFirstContent() async {
    _ensureActive();
    final session = await library.openMangaReaderSession(item.id);
    if (session == null) return null;
    _catalog = _CatalogSnapshot(session, synchronized: false);
    final entry = session.initialChapter;
    final stored = await session.readContent(entry);
    if (stored is! MangaChapterContent || stored.pages.isEmpty) return null;
    final manifest = _ChapterManifest(
      chapterId: entry.remoteIdentity,
      title: entry.title,
      pages: stored.pages,
      sessionOnlyUrls: const <String, Uri>{},
    );
    _manifests[entry.remoteIdentity] = manifest;
    final first = manifest.pages.first;
    final bytes = await _readCachedImage(entry.remoteIdentity, first);
    if (bytes == null) return null;
    _preparedImages['${entry.remoteIdentity}\u0000${first.pageId}'] = bytes;
    return bytes.lengthInBytes;
  }

  @override
  Future<ComicBookInfo> loadBookInfo(String bookId) async {
    _checkBook(bookId);
    return ComicBookInfo(
      id: item.id.value,
      title: item.title,
      author: item.author,
      description: item.description,
      sourceName: item.sourceName,
      sourceUrl: item.sourceUrl,
      sourceKind: ReaderBookSourceKind.remote,
    );
  }

  @override
  Future<void> refreshCatalog(String bookId) async {
    _checkBook(bookId);
    final active = _catalogLoading;
    if (active != null) {
      try {
        await active;
      } on Object {
        // Reopen the durable catalog below even when the prior load failed.
      }
    }
    _catalog = null;
    _catalogLoading = null;
    item = await library.getLibraryItem(item.id) ?? item;
  }

  @override
  Future<ComicChapterCatalogPage> loadChapterCatalog(String bookId, {String? cursor, int pageSize = 50}) async {
    _checkBook(bookId);
    final catalog = await _ensureCatalog();
    final session = catalog.session;
    if (session == null) {
      return ComicChapterCatalogPage(items: const <ComicChapterInfo>[], total: 0, hasMore: false);
    }
    final page = await session.page(after: cursor, limit: pageSize.clamp(1, 500));
    return ComicChapterCatalogPage(
      items: [for (final entry in page.items) _chapterInfo(entry)],
      total: session.catalogCount,
      hasMore: page.nextCursor != null,
      nextCursor: page.nextCursor,
    );
  }

  @override
  Future<ComicChapterInfo> loadChapterAtIndex(String bookId, int index) async {
    _checkBook(bookId);
    final session = (await _ensureCatalog()).session;
    if (session == null) throw RangeError.index(index, 0);
    final entry = await session.itemAtIndex(index);
    if (entry == null) throw RangeError.index(index, session.catalogCount);
    return _chapterInfo(entry);
  }

  @override
  Future<ComicChapterContent> loadChapterContent(String bookId, String chapterId) async {
    _checkBook(bookId);
    final persisted = await _persistedManifest(chapterId);
    if (persisted != null) return _readerContent(persisted);
    return _readerContent(await _runtimeManifest(chapterId));
  }

  @override
  Future<Uint8List> loadImageBytes(String bookId, String chapterId, String imageId) {
    _checkBook(bookId);
    final key = '$chapterId\u0000$imageId';
    final active = _imageLoads[key];
    if (active != null) return active;
    final task = _loadImageBytes(chapterId, imageId);
    _imageLoads[key] = task;
    return task.whenComplete(() {
      if (identical(_imageLoads[key], task)) _imageLoads.remove(key);
    });
  }

  @override
  Future<bool> isImagePersistentlyCached(String bookId, String chapterId, String imageId) async {
    _checkBook(bookId);
    final manifest = _manifests[chapterId] ?? await _persistedManifest(chapterId);
    final page = manifest?.page(imageId);
    if (page == null) return false;
    return await _readCachedImage(chapterId, page) != null;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _catalog = null;
    _catalogLoading = null;
    _manifests.clear();
    _runtimeManifestLoads.clear();
    _imageLoads.clear();
    _preparedImages.clear();
    await _httpClientOwner?.dispose();
  }

  Future<_CatalogSnapshot> _ensureCatalog({bool synchronize = false}) async {
    final current = _catalog;
    if (current != null && (!synchronize || current.synchronized)) return current;
    final active = _catalogLoading;
    if (active != null) {
      final loaded = await active;
      return synchronize && !loaded.synchronized ? _ensureCatalog(synchronize: true) : loaded;
    }
    final task = synchronize ? _syncCatalog() : _openOrSyncCatalog();
    _catalogLoading = task;
    try {
      return _catalog = await task;
    } finally {
      if (identical(_catalogLoading, task)) _catalogLoading = null;
    }
  }

  Future<_CatalogSnapshot> _openOrSyncCatalog() async {
    final session = await library.openMangaReaderSession(item.id);
    return session == null ? _syncCatalog() : _CatalogSnapshot(session, synchronized: false);
  }

  Future<_CatalogSnapshot> _syncCatalog() async {
    _usedNetwork = true;
    final source = _requireSource();
    final remote = await gateway.getChapters(pluginId: source.pluginId, id: source.remoteContentId);
    await library.syncMangaCatalog(
      itemId: item.id,
      chapters: [
        for (final chapter in remote.items)
          MangaChapterDescriptor(
            remoteIdentity: chapter.id,
            title: chapter.title,
            index: chapter.order,
            pages: const <MangaPageDescriptor>[],
          ),
      ],
    );
    if (remote.items.isEmpty) return const _CatalogSnapshot(null, synchronized: true);
    final session = await library.openMangaReaderSession(item.id);
    if (session == null) throw StateError('Content Library did not expose the synchronized manga catalog.');
    return _CatalogSnapshot(session, synchronized: true);
  }

  Future<_ChapterManifest> _runtimeManifest(String chapterId, {bool forceRefresh = false}) async {
    final cached = _manifests[chapterId];
    if (!forceRefresh && cached != null) return cached;
    final active = _runtimeManifestLoads[chapterId];
    if (active != null) return active;
    final task = _loadRuntimeManifest(chapterId);
    _runtimeManifestLoads[chapterId] = task;
    try {
      return await task;
    } finally {
      if (identical(_runtimeManifestLoads[chapterId], task)) _runtimeManifestLoads.remove(chapterId);
    }
  }

  Future<_ChapterManifest> _loadRuntimeManifest(String chapterId) async {
    final session = (await _ensureCatalog()).session;
    if (session == null) throw ArgumentError.value(chapterId, 'chapterId', 'Unknown chapter.');
    final entry = await session.itemByRemoteIdentity(chapterId);
    if (entry == null) throw ArgumentError.value(chapterId, 'chapterId', 'Unknown chapter.');
    final source = _requireSource();
    _usedNetwork = true;
    final remote = await gateway.getContent(pluginId: source.pluginId, id: source.remoteContentId, chapterId: chapterId);
    _ensureActive();
    final projection = projectSourceMangaChapter(remote, chapterId);
    var pages = _runtimePages(projection.descriptors);
    CatalogEntry? refreshedEntry;
    try {
      await library.cacheMangaChapter(entryId: entry.id, pages: projection.descriptors);
      refreshedEntry = await session.itemByRemoteIdentity(chapterId);
      final persisted = refreshedEntry == null ? null : await session.readContent(refreshedEntry);
      if (persisted is MangaChapterContent && persisted.pages.isNotEmpty) {
        pages = persisted.pages;
      }
    } on Object {
      // A persistence outage must not discard an already validated Runtime
      // manifest. The current session can still read it and retry caching later.
    }
    final manifest = _ChapterManifest(
      chapterId: chapterId,
      title: remote.title ?? refreshedEntry?.title ?? entry.title,
      pages: pages,
      sessionOnlyUrls: projection.sessionOnlyUrls,
    );
    _manifests[chapterId] = manifest;
    return manifest;
  }

  List<MangaPage> _runtimePages(Iterable<MangaPageDescriptor> descriptors) => [
    for (final descriptor in descriptors)
      MangaPage(
        pageId: descriptor.pageId,
        order: descriptor.order,
        resource: descriptor.resource,
        mimeType: descriptor.mimeType,
        width: descriptor.width,
        height: descriptor.height,
        byteLength: descriptor.byteLength,
        contentVersion: descriptor.contentVersion,
      ),
  ];

  Future<_ChapterManifest?> _persistedManifest(String chapterId) async {
    final existing = _manifests[chapterId];
    if (existing != null) return existing;
    final session = (await _ensureCatalog()).session;
    if (session == null) return null;
    final entry = await session.itemByRemoteIdentity(chapterId);
    if (entry == null) throw ArgumentError.value(chapterId, 'chapterId', 'Unknown chapter.');
    final content = await session.readContent(entry);
    if (content == null) return null;
    if (content is! MangaChapterContent || content.pages.isEmpty) {
      throw StateError('Content Library manga manifest is invalid.');
    }
    return _manifests[chapterId] = _ChapterManifest(
      chapterId: chapterId,
      title: entry.title,
      pages: content.pages,
      sessionOnlyUrls: const <String, Uri>{},
    );
  }

  Future<Uint8List> _loadImageBytes(String chapterId, String imageId) async {
    var manifest = await _persistedManifest(chapterId);
    manifest ??= await _runtimeManifest(chapterId);
    var page = manifest.page(imageId);
    if (page == null) throw StateError('Comic image is not in the chapter manifest.');

    final key = '$chapterId\u0000$imageId';
    final prepared = _preparedImages.remove(key);
    if (prepared != null) return prepared;
    final cached = await _readCachedImage(chapterId, page);
    if (cached != null) return cached;

    var uri = manifest.downloadUri(page);
    var refreshed = false;
    if (uri == null || manifest.needsRefresh(page)) {
      manifest = await _refreshRuntimeManifest(chapterId, manifest);
      refreshed = true;
      page = manifest.page(imageId);
      if (page == null) throw StateError('Comic image is not in the refreshed chapter manifest.');
      uri = manifest.downloadUri(page);
    }
    if (uri == null) throw StateError('Comic image URL is unavailable.');
    Uint8List bytes;
    try {
      _usedNetwork = true;
      bytes = await _fetchImage(uri);
    } on Object catch (error) {
      if (!refreshed &&
          shouldRefreshComicResourceAfterFailure(error, regenerable: page.resource.persistencePolicy != PersistencePolicy.durable)) {
        manifest = await _refreshRuntimeManifest(chapterId, manifest);
        page = manifest.page(imageId);
        if (page == null) throw StateError('Comic image is not in the refreshed chapter manifest.');
        uri = manifest.downloadUri(page);
        if (uri == null) throw StateError('Comic image URL is unavailable after refresh.');
        try {
          _usedNetwork = true;
          bytes = await _fetchImage(uri);
        } on Object catch (retryError) {
          throw _imageFailure(retryError);
        }
      } else {
        throw _imageFailure(error);
      }
    }
    if (bytes.isEmpty) throw StateError('Comic image is empty.');
    if (bytes.length > _maximumImageBytes) throw StateError('Comic image exceeds 8 MiB.');
    try {
      await library.saveMangaImage(
        itemId: item.id,
        chapterId: chapterId,
        pageId: page.pageId,
        contentVersion: page.contentVersion,
        bytes: bytes,
        mimeType: page.mimeType ?? 'image/unknown',
      );
    } on Object {
      // Validated network bytes remain readable when durable cache IO fails.
    }
    return bytes;
  }

  Future<Uint8List?> _readCachedImage(String chapterId, MangaPage page) async {
    try {
      final cached = await library.readMangaImage(
        itemId: item.id,
        chapterId: chapterId,
        pageId: page.pageId,
        contentVersion: page.contentVersion,
      );
      if (cached == null || cached.isEmpty || cached.length > _maximumImageBytes) return null;
      return Uint8List.fromList(cached);
    } on Object {
      // A corrupt or unavailable cache is a miss; the source remains usable.
      return null;
    }
  }

  Future<_ChapterManifest> _refreshRuntimeManifest(String chapterId, _ChapterManifest stale) {
    final current = _manifests[chapterId];
    if (current != null && !identical(current, stale)) return Future<_ChapterManifest>.value(current);
    return _runtimeManifest(chapterId, forceRefresh: true);
  }

  Future<Uint8List> _fetchImage(Uri uri) async {
    final current = await resolveSourceResource(gateway, uri);
    return _externalFetcher?.call(current) ?? _httpClientOwner!.fetch(current);
  }

  ReaderFailure _imageFailure(Object error) => ReaderFailure(
    ReaderFailureKind.image,
    '漫画图片下载失败，请检查网络后重试。',
    code: 'library_comic_image_download_failed',
    location: '下载漫画图片',
    cause: error,
  );

  ComicChapterInfo _chapterInfo(CatalogEntry entry) => ComicChapterInfo(
    id: entry.remoteIdentity,
    title: entry.title,
    index: entry.index,
    availability: entry.contentStatus == 'ready' ? ReaderChapterAvailability.unknown : ReaderChapterAvailability.notDownloaded,
    manifestCached: entry.contentStatus == 'ready',
  );

  ComicChapterContent _readerContent(_ChapterManifest manifest) => ComicChapterContent(
    chapterId: manifest.chapterId,
    title: manifest.title,
    contentVersion: '${manifest.pages.first.contentVersion}',
    images: [
      for (final page in manifest.pages)
        ComicImageInfo(
          id: page.pageId,
          index: page.order,
          width: page.width,
          height: page.height,
          contentType: page.mimeType,
          byteLength: page.byteLength,
          contentVersion: '${page.contentVersion}',
        ),
    ],
  );

  LibraryItemSource _requireSource() => item.source;
  void _checkBook(String bookId) {
    _ensureActive();
    if (bookId != item.id.value) throw ArgumentError.value(bookId, 'bookId');
  }

  void _ensureActive() {
    if (_disposed) throw StateError('Comic reader data source is disposed.');
  }
}

final class _CatalogSnapshot {
  const _CatalogSnapshot(this.session, {required this.synchronized});
  final MangaReaderSession? session;
  final bool synchronized;
}

final class _ChapterManifest {
  const _ChapterManifest({required this.chapterId, required this.title, required this.pages, required this.sessionOnlyUrls});
  final String chapterId;
  final String title;
  final List<MangaPage> pages;
  final Map<String, Uri> sessionOnlyUrls;

  MangaPage? page(String pageId) {
    for (final page in pages) {
      if (page.pageId == pageId) return page;
    }
    return null;
  }

  Uri? downloadUri(MangaPage page) => switch (page.resource.persistencePolicy) {
    PersistencePolicy.sessionOnly => sessionOnlyUrls[page.pageId],
    PersistencePolicy.refreshable || PersistencePolicy.durable => page.resource.url,
  };

  bool needsRefresh(MangaPage page) =>
      page.resource.persistencePolicy == PersistencePolicy.refreshable && !page.resource.expiresAtUtc!.isAfter(DateTime.now().toUtc());
}
