/// Content Library-backed comic reader adapters.
///
/// Runtime supplies catalogs and regenerable manifests; Content Library owns
/// the synchronized snapshot, URL-safe manifest, progress, and bookmarks.
/// Encoded image bytes stay in the reader's bounded memory cache; this adapter
/// does not read or write a persistent image cache. Session-only URLs and
/// request single-flights stay in this file. Live manifests use a three-entry
/// LRU so visiting chapters cannot grow session memory without bound.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';

import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/network_proxy/application/flutter_network_proxy_manager.dart';
import 'package:mg_read/features/network_proxy/application/network_proxy_settings.dart';
import 'package:mg_read/features/reader/data/bounded_reader_session_cache.dart';

typedef ComicImageFetcher = Future<Uint8List> Function(Uri uri);

ComicImageFetcher createProxyAwareComicImageFetcher(FlutterNetworkProxyManager manager) =>
    (uri) async => fetchComicImage(uri, client: await manager.createHttpClient(NetworkProxyTraffic.manga));

/// Content Library adapter for a source-backed comic session.
final class ContentLibraryComicReaderDataSource implements ComicReaderDataSource {
  ContentLibraryComicReaderDataSource({required this.library, required this.gateway, required this.item, ComicImageFetcher? fetcher})
    : fetcher = fetcher ?? fetchComicImage;

  static const _maximumImageBytes = 8 * 1024 * 1024;

  final ContentLibrary library;
  final SourceContentGateway gateway;
  final LibraryItem item;
  final ComicImageFetcher fetcher;
  _CatalogSnapshot? _catalog;
  Future<_CatalogSnapshot>? _catalogLoading;
  final BoundedReaderSessionCache<String, _ChapterManifest> _manifests = BoundedReaderSessionCache<String, _ChapterManifest>(maxEntries: 3);
  final Map<String, Future<_ChapterManifest>> _runtimeManifestLoads = <String, Future<_ChapterManifest>>{};
  final Map<String, Future<Uint8List>> _imageLoads = <String, Future<Uint8List>>{};

  @override
  Future<ComicBookInfo> loadBookInfo(String bookId) async {
    _checkBook(bookId);
    return ComicBookInfo(
      id: item.id.value,
      title: item.title,
      author: item.author,
      description: item.description,
      sourceName: item.sourceName,
      sourceKind: ReaderBookSourceKind.remote,
    );
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
    try {
      return _readerContent(await _runtimeManifest(chapterId));
    } on Object catch (error, stackTrace) {
      // A previously committed manifest remains a usable offline snapshot.
      // Preserve the live error when no such snapshot exists.
      final persisted = await _persistedManifest(chapterId);
      if (persisted == null) Error.throwWithStackTrace(error, stackTrace);
      return _readerContent(persisted);
    }
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
    final remote = await gateway.getContent(pluginId: source.pluginId, id: source.remoteContentId, chapterId: chapterId);
    final descriptors = _validatedPages(remote, chapterId);
    final sessionOnlyUrls = <String, Uri>{
      for (final page in remote.pages)
        if (page.resourcePolicy == PluginMangaPageResourcePolicy.sessionOnly) page.id: page.url,
    };
    var pages = _runtimePages(descriptors);
    CatalogEntry? refreshedEntry;
    try {
      await library.cacheMangaChapter(entryId: entry.id, pages: descriptors);
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
      sessionOnlyUrls: sessionOnlyUrls,
    );
    _manifests[chapterId] = manifest;
    return manifest;
  }

  List<MangaPageDescriptor> _validatedPages(PluginChapterContent content, String chapterId) {
    if (content.contentKind != PluginContentKind.manga) throw StateError('Source chapter is not manga.');
    if (content.chapterId != chapterId) throw StateError('Source returned a different manga chapter.');
    if (content.pages.isEmpty) throw StateError('Source manga manifest is empty.');
    final ids = <String>{};
    final indexes = <int>{};
    final updatedVersion = content.updatedAt?.toUtc().millisecondsSinceEpoch ?? 1;
    final version = updatedVersion > 0 ? updatedVersion : 1;
    final sorted = content.pages.toList(growable: false)..sort((left, right) => left.index.compareTo(right.index));
    return [
      for (final page in sorted)
        _pageDescriptor(page, version: version, duplicateId: !ids.add(page.id), duplicateIndex: !indexes.add(page.index)),
    ];
  }

  MangaPageDescriptor _pageDescriptor(
    PluginMangaPage page, {
    required int version,
    required bool duplicateId,
    required bool duplicateIndex,
  }) {
    if (page.id.isEmpty || page.index < 0 || duplicateId || duplicateIndex) {
      throw StateError('Source manga manifest contains duplicate or invalid pages.');
    }
    final resource = switch (page.resourcePolicy) {
      PluginMangaPageResourcePolicy.sessionOnly => SourceResource.sessionOnly(),
      PluginMangaPageResourcePolicy.refreshable => SourceResource.refreshable(
        page.url,
        page.expiresAt ?? (throw StateError('Refreshable manga page is missing expiresAt.')),
      ),
      PluginMangaPageResourcePolicy.durable => SourceResource.durable(page.url),
    };
    return MangaPageDescriptor(
      pageId: page.id,
      order: page.index,
      resource: resource,
      mimeType: page.mimeType ?? 'image/unknown',
      width: page.width,
      height: page.height,
      contentVersion: version,
    );
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

    var uri = manifest.downloadUri(page);
    if (uri == null || manifest.needsRefresh(page)) {
      manifest = await _runtimeManifest(chapterId, forceRefresh: true);
      page = manifest.page(imageId);
      if (page == null) throw StateError('Comic image is not in the refreshed chapter manifest.');
      uri = manifest.downloadUri(page);
    }
    if (uri == null) throw StateError('Comic image URL is unavailable.');
    final Uint8List bytes;
    try {
      bytes = await fetcher(uri);
    } on Object catch (error) {
      throw ReaderFailure(
        ReaderFailureKind.image,
        '漫画图片下载失败，请检查网络后重试。',
        code: 'library_comic_image_download_failed',
        location: '下载漫画图片',
        cause: error,
      );
    }
    if (bytes.isEmpty) throw StateError('Comic image is empty.');
    if (bytes.length > _maximumImageBytes) throw StateError('Comic image exceeds 8 MiB.');
    return bytes;
  }

  ComicChapterInfo _chapterInfo(CatalogEntry entry) => ComicChapterInfo(
    id: entry.remoteIdentity,
    title: entry.title,
    index: entry.index,
    availability: entry.contentStatus == 'ready' ? ReaderChapterAvailability.downloaded : ReaderChapterAvailability.notDownloaded,
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

  LibraryItemSource _requireSource() => item.source ?? (throw StateError('Comic source is missing.'));
  void _checkBook(String bookId) {
    if (bookId != item.id.value) throw ArgumentError.value(bookId, 'bookId');
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

/// Comic reader state adapter backed by Content Library and app settings.
final class ContentLibraryComicReaderStateStore implements ComicReaderStateStore {
  ContentLibraryComicReaderStateStore(this.library, {required this.itemId, this.settings});
  final ContentLibrary library;
  final LibraryItemId itemId;
  final AppSettingsManager? settings;
  @override
  Future<ComicReaderProgress?> loadProgress(String bookId) async {
    _check(bookId);
    final p = await library.loadMangaProgress(itemId);
    return p == null
        ? null
        : ComicReaderProgress(
            chapterId: p.chapterId,
            imageId: p.imageId,
            imageFraction: p.imageFraction,
            chapterIndex: p.chapterIndex,
            bookFraction: p.bookFraction,
          );
  }

  @override
  Future<void> saveProgress(String bookId, ComicReaderProgress p) {
    _check(bookId);
    return library.saveMangaProgress(
      LibraryMangaReadingProgress(
        itemId: itemId,
        chapterId: p.chapterId,
        imageId: p.imageId,
        imageFraction: p.imageFraction,
        chapterIndex: p.chapterIndex,
        bookFraction: p.bookFraction,
        updatedAtUtc: DateTime.now().toUtc(),
      ),
    );
  }

  @override
  Future<ComicReaderPreferences?> loadPreferences() async {
    final raw = settings?.get(AppSettingKeys.comicReaderPreferences) ?? const <String, Object?>{};
    return raw.isEmpty
        ? null
        : ComicReaderPreferences(
            brightness: (raw['brightness'] as num?)?.toDouble() ?? 1,
            keepScreenOn: raw['keepScreenOn'] as bool? ?? true,
            immersiveMode: raw['immersiveMode'] as bool? ?? false,
            imageSpacing: (raw['imageSpacing'] as num?)?.toDouble() ?? 0,
          ).normalized();
  }

  @override
  Future<void> savePreferences(ComicReaderPreferences p) async {
    final s = settings;
    if (s == null) return;
    await s.set(AppSettingKeys.comicReaderPreferences, <String, Object?>{
      'brightness': p.brightness,
      'keepScreenOn': p.keepScreenOn,
      'immersiveMode': p.immersiveMode,
      'imageSpacing': p.imageSpacing,
    });
    await s.flush();
  }

  @override
  Future<List<ComicReaderBookmark>> loadBookmarks(String bookId) async {
    _check(bookId);
    return [
      for (final b in await library.listMangaBookmarks(itemId))
        ComicReaderBookmark(
          id: b.id,
          bookId: b.itemId.value,
          chapterId: b.chapterId,
          imageId: b.imageId,
          imageFraction: b.imageFraction,
          chapterTitle: '',
          createdAt: b.createdAtUtc,
        ),
    ];
  }

  @override
  Future<void> addBookmark(ComicReaderBookmark b) {
    _check(b.bookId);
    return library.addMangaBookmark(
      LibraryMangaBookmark(
        id: b.id,
        itemId: itemId,
        chapterId: b.chapterId,
        imageId: b.imageId,
        imageFraction: b.imageFraction,
        createdAtUtc: b.createdAt.toUtc(),
      ),
    );
  }

  @override
  Future<void> removeBookmark(String bookId, String id) {
    _check(bookId);
    return library.removeMangaBookmark(itemId, id);
  }

  void _check(String bookId) {
    if (bookId != itemId.value) throw ArgumentError.value(bookId, 'bookId');
  }
}

Future<Uint8List> fetchComicImage(Uri uri, {HttpClient? client}) async {
  const maximumBytes = 8 * 1024 * 1024;
  final ownedClient = client ?? HttpClient();
  ownedClient
    ..maxConnectionsPerHost = 4
    ..connectionTimeout = const Duration(seconds: 15);
  try {
    var current = uri;
    for (var redirects = 0; ; redirects++) {
      if (current.scheme != 'http' && current.scheme != 'https') {
        throw ArgumentError.value(current, 'uri', 'Comic images require HTTP or HTTPS.');
      }
      if (client == null && _isLoopback(current)) {
        // Runtime source resources are private loopback URLs. They must never
        // be sent through a desktop proxy, which can turn a valid one-time
        // resource into an unrelated remote request.
        ownedClient.findProxy = (_) => 'DIRECT';
      }
      final request = await ownedClient.getUrl(current).timeout(const Duration(seconds: 15));
      request.followRedirects = false;
      final response = await request.close().timeout(const Duration(seconds: 20));
      if (response.isRedirect) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (redirects >= 3 || location == null) throw HttpException('Too many redirects.');
        await response.drain<void>().timeout(const Duration(seconds: 20));
        current = current.resolve(location);
        continue;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) throw HttpException('Image status ${response.statusCode}.');
      final mime = response.headers.contentType?.mimeType ?? '';
      if (!RegExp(r'^image/[^\s/]+$', caseSensitive: false).hasMatch(mime)) {
        throw HttpException('Image MIME is invalid.');
      }
      if (response.contentLength > maximumBytes) throw StateError('Image exceeds 8 MiB.');
      final bytes = await response
          .timeout(const Duration(seconds: 20))
          .fold<BytesBuilder>(BytesBuilder(), (b, chunk) {
            b.add(chunk);
            if (b.length > maximumBytes) throw StateError('Image exceeds 8 MiB.');
            return b;
          })
          .then((b) => b.takeBytes());
      if (bytes.isEmpty) throw StateError('Image is empty.');
      return Uint8List.fromList(bytes);
    }
  } finally {
    ownedClient.close(force: true);
  }
}

bool _isLoopback(Uri uri) => uri.host == 'localhost' || uri.host == '127.0.0.1' || uri.host == '::1';
