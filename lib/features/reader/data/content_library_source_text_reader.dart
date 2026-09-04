/// Content Library-backed text reader launcher and session adapter.
///
/// Durable chapter bodies remain owned by Content Library. The live adapter
/// keeps at most two recently used bodies within a 128 KiB logical UTF-16
/// budget, without scanning or encoding text on the first-content path.
library;

import 'dart:convert';

import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';

import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/discovery/application/content_library_source_prefetcher.dart';
import 'package:mg_read/features/reader/application/library_reader_launcher.dart';
import 'package:mg_read/features/reader/application/chapter_cache_task_controller.dart';
import 'package:mg_read/features/reader/application/reader_launch_failure.dart';
import 'package:mg_read/features/reader/application/reader_launch_request.dart';
import 'package:mg_read/features/reader/application/shelf_reader_launch_coordinator.dart';
import 'package:mg_read/features/reader/data/bounded_reader_session_cache.dart';
import 'package:mg_read/features/reader/data/content_library_text_reader_state_store.dart';

/// Opens a shelf novel with app-owned reading state and a typed source gateway.
///
/// Whole-book cache requests are handed to the app-global task controller;
/// each selected chapter is committed through the immutable library session.
///
/// Shelf launches use the app-owned immutable catalog snapshot and only ask the
/// source gateway for the selected chapter when its local body is unavailable.
final class ContentLibrarySourceTextReader implements LibraryReaderLauncher, LocalShelfReaderPrewarmer {
  const ContentLibrarySourceTextReader(this._library, this._gateway, [this._prefetcher, this._settings, this._chapterCacheTasks]);

  final ContentLibrary _library;
  final SourceContentGateway _gateway;
  final ContentLibrarySourcePrefetcher? _prefetcher;
  final AppSettingsManager? _settings;
  final ChapterCacheTaskController? _chapterCacheTasks;

  @override
  Future<NovelReaderLaunchRequest> launch(String libraryItemId) async {
    final itemId = LibraryItemId(libraryItemId);
    var session = await _library.openNovelReaderSession(itemId);
    var item = session?.item ?? await _library.getLibraryItem(itemId);
    if (item == null) {
      throw _failure(ReaderLaunchFailureReason.shelfItemMissing, AppErrorCode.notFound);
    }
    if (item.kind != ContentKind.novel) {
      throw _failure(ReaderLaunchFailureReason.unsupportedContentKind, AppErrorCode.unsupported);
    }
    final source = item.source;
    if (source == null) {
      throw _failure(ReaderLaunchFailureReason.shelfSourceMissing, AppErrorCode.invalidFormat);
    }

    if (_prefetcher?.hasInFlight(item.id.value) == true) {
      try {
        await _prefetcher!.prepareForReading(item);
      } on Object {
        // A failed background warm-up is retried through the typed gateway.
      }
      item = await _library.getLibraryItem(item.id) ?? item;
      session = await _library.openNovelReaderSession(item.id);
    }
    final request = session == null
        ? await _launchLiveSession(item, source)
        : await _launchLocalSession(item, source, session, waitForWarm: session.resolveProgressEntry);
    return _attachCachedCover(item, request);
  }

  @override
  Future<NovelReaderLaunchRequest?> warmLocal(String libraryItemId) async {
    final session = await _library.openNovelReaderSession(LibraryItemId(libraryItemId));
    if (session == null) return null;
    final item = session.item;
    if (item.source == null) return null;
    final target = await session.resolveProgressEntry() ?? await session.itemAtIndex(0);
    if (target == null) return null;
    final content = await session.readContent(target);
    if (content is! NovelChapterContent) return null;
    final request = _buildSessionRequest(
      item: item,
      source: item.source!,
      session: session,
      initialEntry: target,
      initialContent: content,
      preparationKind: ReaderLaunchPreparationKind.memory,
    );
    return _attachCachedCover(item, request);
  }

  Future<NovelReaderLaunchRequest> _attachCachedCover(LibraryItem item, NovelReaderLaunchRequest request) async {
    final bytes = await _readCachedCover(item);
    return bytes == null ? request : request.withEntryCoverBytes(bytes);
  }

  Future<List<int>?> _readCachedCover(LibraryItem item) async {
    try {
      final source = item.source;
      final url = item.coverUrl;
      if (source != null && url != null) {
        final cached = await _library.covers.read(
          CoverKey(pluginId: source.pluginId, pluginVersion: source.pluginVersion, remoteContentId: source.remoteContentId, coverUrl: url),
        );
        if (cached != null && cached.isNotEmpty) return cached;
      }
      final legacy = await _library.bookshelf.readCover(item.id);
      return legacy == null || legacy.isEmpty ? null : legacy;
    } on Object {
      // A cover cache miss must never prevent the reader session from opening.
      return null;
    }
  }

  Future<NovelReaderLaunchRequest> _launchLocalSession(
    LibraryItem item,
    LibraryItemSource source,
    NovelReaderSession session, {
    required Future<CatalogEntry?> Function() waitForWarm,
  }) async {
    var target = await waitForWarm();
    target ??= await session.itemAtIndex(0);
    if (target == null) {
      return _launchLiveSession(item, source);
    }
    var content = await session.readContent(target);
    var preparationKind = ReaderLaunchPreparationKind.persistent;
    var networkPreparationElapsed = Duration.zero;
    if (content is! NovelChapterContent) {
      final networkStopwatch = Stopwatch()..start();
      var reusedInFlight = false;
      if (_prefetcher?.hasInFlight(item.id.value) == true) {
        try {
          await _prefetcher!.prepareForReading(item);
          content = await session.readContent(target);
          reusedInFlight = content is NovelChapterContent;
        } on Object {
          // Continue with the targeted chapter request below.
        }
      }
      if (!reusedInFlight) {
        final remote = await _resolve(
          ReaderLaunchFailureReason.sourceContentKind,
          () => _gateway.getContent(pluginId: source.pluginId, id: source.remoteContentId, chapterId: target!.remoteIdentity),
        );
        if (remote.contentKind != PluginContentKind.novel || remote.text == null) {
          throw _failure(ReaderLaunchFailureReason.sourceContentKind, AppErrorCode.unsupported);
        }
        try {
          await session.cacheChapter(entry: target, text: remote.text!);
        } on Object {
          // The validated remote body remains usable when persistence is down.
        }
        content = NovelChapterContent(text: remote.text!);
      }
      preparationKind = ReaderLaunchPreparationKind.network;
      networkStopwatch.stop();
      networkPreparationElapsed = networkStopwatch.elapsed;
    }
    final preparedContent = content;
    if (preparedContent is! NovelChapterContent) {
      throw _failure(ReaderLaunchFailureReason.sourceContentKind, AppErrorCode.notFound);
    }
    return _buildSessionRequest(
      item: item,
      source: source,
      session: session,
      initialEntry: target,
      initialContent: preparedContent,
      preparationKind: preparationKind,
      networkPreparationElapsed: networkPreparationElapsed,
    );
  }

  /// A newly added or incomplete shelf item refreshes and atomically commits
  /// one complete source catalog before constructing the reader session.
  Future<NovelReaderLaunchRequest> _launchLiveSession(LibraryItem item, LibraryItemSource source) async {
    final networkStopwatch = Stopwatch()..start();
    final remoteCatalog = await _resolve(
      ReaderLaunchFailureReason.sourceCatalog,
      () => _gateway.getChapters(pluginId: source.pluginId, id: source.remoteContentId),
    );
    if (remoteCatalog.items.isEmpty) {
      throw _failure(ReaderLaunchFailureReason.sourceCatalogEmpty, AppErrorCode.notFound);
    }
    await _library.syncNovelCatalog(
      itemId: item.id,
      chapters: remoteCatalog.items
          .map(
            (chapter) => SourceNovelCatalogChapter(
              remoteIdentity: chapter.id,
              title: chapter.title,
              index: chapter.order,
              wordCount: chapter.wordCount,
              chapterUrl: chapter.url,
            ),
          )
          .toList(growable: false),
    );
    final localSession = await _library.openNovelReaderSession(item.id);
    if (localSession == null) {
      throw StateError('Catalog snapshot was not committed.');
    }
    final initialEntry = await localSession.resolveProgressEntry() ?? await localSession.itemAtIndex(0);
    if (initialEntry == null) throw StateError('Catalog snapshot is empty.');
    final initialContent = await _resolve(
      ReaderLaunchFailureReason.sourceContentKind,
      () => _gateway.getContent(pluginId: source.pluginId, id: source.remoteContentId, chapterId: initialEntry.remoteIdentity),
    );
    if (initialContent.contentKind != PluginContentKind.novel || initialContent.text == null) {
      throw _failure(ReaderLaunchFailureReason.sourceContentKind, AppErrorCode.unsupported);
    }
    networkStopwatch.stop();
    try {
      await localSession.cacheChapter(entry: initialEntry, text: initialContent.text!);
    } on Object {
      // The fetched body is still passed to the reader if the cache is down.
    }
    return _buildSessionRequest(
      item: item,
      source: source,
      session: localSession,
      initialEntry: initialEntry,
      initialContent: NovelChapterContent(text: initialContent.text!),
      preparationKind: ReaderLaunchPreparationKind.network,
      networkPreparationElapsed: networkStopwatch.elapsed,
    );
  }

  NovelReaderLaunchRequest _buildSessionRequest({
    required LibraryItem item,
    required LibraryItemSource source,
    required NovelReaderSession session,
    required CatalogEntry initialEntry,
    required NovelChapterContent initialContent,
    required ReaderLaunchPreparationKind preparationKind,
    Duration networkPreparationElapsed = Duration.zero,
  }) {
    final chapterAccess = _SessionNovelChapterAccess(
      session: session,
      item: item,
      source: source,
      gateway: _gateway,
      cacheTasks: _chapterCacheTasks,
      initialEntry: initialEntry,
      initialContent: initialContent,
    );
    final dataSource = _SessionTextReaderDataSource(
      item: item,
      session: session,
      chapterAccess: chapterAccess,
      sourceKind: preparationKind == ReaderLaunchPreparationKind.network ? ReaderBookSourceKind.remote : ReaderBookSourceKind.local,
    );
    final stateStore = ContentLibraryTextReaderStateStore(
      _library,
      itemId: item.id,
      settings: _settings,
      initialProgress: session.progress,
      progressAlreadyLoaded: true,
    );
    return NovelReaderLaunchRequest(
      bookId: item.id.value,
      dataSource: dataSource,
      stateStore: stateStore,
      chapterPreloadCount: _settings?.get(AppSettingKeys.novelPreloadChapterCount) ?? 1,
      observer: _TimedReaderObserver(stateStore, null),
      extensions: ReaderExtensions(
        chapterStateCapability: chapterAccess,
        chapterCacheCapability: _chapterCacheTasks == null ? null : chapterAccess,
      ),
      estimatedWarmBytes: utf8.encode(initialContent.text).length,
      preparationKind: preparationKind,
      networkPreparationElapsed: preparationKind == ReaderLaunchPreparationKind.network ? networkPreparationElapsed : Duration.zero,
    );
  }

  Future<T> _resolve<T>(ReaderLaunchFailureReason reason, Future<T> Function() action) async {
    try {
      return await action();
    } on ReaderLaunchFailure {
      rethrow;
    } on Object catch (error) {
      throw ReaderLaunchFailure(reason: reason, error: AppError.fromUnknown(error));
    }
  }

  ReaderLaunchFailure _failure(ReaderLaunchFailureReason reason, AppErrorCode code) =>
      ReaderLaunchFailure(reason: reason, error: AppError.fromCode(code));
}

/// Preserves host callbacks while synchronizing foreground reading duration.
final class _TimedReaderObserver extends ReaderObserver {
  const _TimedReaderObserver(this._stateStore, this._delegate);

  final ContentLibraryTextReaderStateStore _stateStore;
  final ReaderObserver? _delegate;

  @override
  Future<void> onSessionStarted(String bookId) async {
    _stateStore.startSession();
    await _delegate?.onSessionStarted(bookId);
  }

  @override
  Future<void> onSessionEnded(String bookId, ReaderProgress? progress) async {
    _stateStore.finishSession();
    await _delegate?.onSessionEnded(bookId, progress);
  }

  @override
  Future<void> onLifecycleChanged(ReaderLifecycleState state, ReaderProgress? progress) async {
    _stateStore.onLifecycleChanged(state);
    await _delegate?.onLifecycleChanged(state, progress);
  }

  @override
  Future<void> onChapterChanged(ReaderChapterInfo chapter) async {
    await _delegate?.onChapterChanged(chapter);
  }

  @override
  Future<void> onFirstContentPresented(ReaderFirstContentPresentation presentation) async {
    await _delegate?.onFirstContentPresented(presentation);
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
final class _SessionNovelChapterAccess implements ReaderChapterStateCapability, ReaderChapterCacheCapability {
  static const int _maximumMemoryWeight = 128 * 1024;

  _SessionNovelChapterAccess({
    required this.session,
    required this.item,
    required this.source,
    required this.gateway,
    required this.cacheTasks,
    required CatalogEntry initialEntry,
    required NovelChapterContent initialContent,
  }) {
    // The launch path has already obtained usable content, either from the
    // durable object store or after persisting the initial remote response.
    // Keep this dynamic state correct even when the immutable catalog entry
    // was cached before that content write completed.
    _cachedChapterIds.add(initialEntry.remoteIdentity);
    _memoryByRemoteId[initialEntry.remoteIdentity] = initialContent.text;
  }

  final NovelReaderSession session;
  final LibraryItem item;
  final LibraryItemSource source;
  final SourceContentGateway gateway;
  final ChapterCacheTaskController? cacheTasks;
  final BoundedReaderSessionCache<String, String> _memoryByRemoteId = BoundedReaderSessionCache<String, String>(
    maxEntries: 2,
    maxWeight: _maximumMemoryWeight,
    // Dart String.length is O(1). This UTF-16 payload estimate avoids
    // re-encoding a whole chapter on the reader's first-content path.
    weightOf: (String _, String text) => text.length * 2,
  );
  final Set<String> _readChapterIds = <String>{};
  final Set<String> _cachedChapterIds = <String>{};
  final Set<String> _failedChapterIds = <String>{};
  final Map<String, Future<PluginChapterContent>> _loading = <String, Future<PluginChapterContent>>{};
  final Map<String, Future<ChapterCacheItemResult>> _cacheLoading = <String, Future<ChapterCacheItemResult>>{};

  Future<PluginChapterContent> load(String chapterId) async {
    final content = await _load(chapterId);
    final text = content.text;
    if (text != null) _memoryByRemoteId[chapterId] = text;
    return content;
  }

  Future<PluginChapterContent> _load(String chapterId) {
    final active = _loading[chapterId];
    if (active != null) return active;
    final task = _loadAndCache(chapterId);
    _loading[chapterId] = task;
    return task.whenComplete(() => _loading.remove(chapterId));
  }

  Future<PluginChapterContent> _loadAndCache(String chapterId) async {
    final entry = await session.itemByRemoteIdentity(chapterId);
    if (entry == null) {
      throw ArgumentError.value(chapterId, 'chapterId', 'Unknown chapter.');
    }
    final memory = _memoryByRemoteId[chapterId];
    if (memory != null) return _pluginContent(entry, memory);
    final cached = await session.readContent(entry);
    if (cached case NovelChapterContent(:final text)) {
      return _pluginContent(entry, text);
    }
    try {
      final remote = await gateway.getContent(pluginId: source.pluginId, id: source.remoteContentId, chapterId: chapterId);
      if (remote.contentKind != PluginContentKind.novel || remote.text == null) {
        throw StateError('The source chapter is not a text-reader chapter.');
      }
      // The validated remote text is already usable. A cache-write failure
      // must not turn it into a reader failure.
      try {
        await session.cacheChapter(entry: entry, text: remote.text!);
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

  PluginChapterContent _pluginContent(CatalogEntry entry, String text) => PluginChapterContent(
    pluginId: source.pluginId,
    sourceName: item.sourceName ?? '书架缓存',
    contentKind: PluginContentKind.novel,
    chapterId: entry.remoteIdentity,
    title: entry.title,
    updatedAt: null,
    text: text,
    pages: const <PluginMangaPage>[],
  );

  @override
  Future<Map<String, ReaderChapterState>> loadChapterStates(String bookId, List<String> chapterIds) async {
    _requireBook(bookId);
    final progress = session.progress;
    final entries = await session.itemsByRemoteIdentities(chapterIds);
    final states = <String, ReaderChapterState>{};
    for (final chapterId in chapterIds) {
      final entry = entries[chapterId];
      if (entry == null) continue;
      states[chapterId] = ReaderChapterState(
        chapterId: chapterId,
        availability: _availability(entry),
        wordCount: entry.wordCount,
        hasBeenRead: _readChapterIds.contains(chapterId) || (progress != null && entry.index <= progress.chapterIndex),
      );
    }
    return states;
  }

  @override
  Future<void> markRead(String bookId, String chapterId) async {
    _requireBook(bookId);
    _readChapterIds.add(chapterId);
  }

  @override
  Future<void> startCaching(String bookId, ReaderChapterCacheRequest request) async {
    _requireBook(bookId);
    final tasks = cacheTasks;
    if (tasks == null) throw StateError('Chapter caching is unavailable.');
    if (request.chapterCount > session.catalogCount) {
      throw RangeError.range(request.chapterCount, 0, session.catalogCount, 'request.chapterCount');
    }
    tasks.start(
      bookTitle: item.title,
      total: request.chapterCount,
      concurrency: request.concurrency,
      delay: request.delay,
      cacheChapter: _cacheChapterAtIndex,
    );
  }

  Future<ChapterCacheItemResult> _cacheChapterAtIndex(int index) async {
    final entry = await session.itemAtIndex(index);
    if (entry == null) throw RangeError.index(index, List<void>.filled(session.catalogCount, null));
    final chapterId = entry.remoteIdentity;
    final activeCache = _cacheLoading[chapterId];
    if (activeCache != null) return activeCache;
    final task = _persistChapter(entry);
    _cacheLoading[chapterId] = task;
    return task.whenComplete(() => _cacheLoading.remove(chapterId));
  }

  Future<ChapterCacheItemResult> _persistChapter(CatalogEntry entry) async {
    final chapterId = entry.remoteIdentity;
    if (entry.contentStatus == 'ready' || _cachedChapterIds.contains(chapterId)) {
      return ChapterCacheItemResult.alreadyCached;
    }
    final cached = await session.readContent(entry);
    if (cached is NovelChapterContent) {
      _cachedChapterIds.add(chapterId);
      return ChapterCacheItemResult.alreadyCached;
    }
    final memory = _memoryByRemoteId[chapterId];
    if (memory != null) {
      await session.cacheChapter(entry: entry, text: memory);
      _cachedChapterIds.add(chapterId);
      _failedChapterIds.remove(chapterId);
      return ChapterCacheItemResult.downloaded;
    }
    final activeReaderLoad = _loading[chapterId];
    if (activeReaderLoad != null) {
      await activeReaderLoad;
      if (_cachedChapterIds.contains(chapterId)) {
        return ChapterCacheItemResult.alreadyCached;
      }
    }
    try {
      final remote = await gateway.getContent(pluginId: source.pluginId, id: source.remoteContentId, chapterId: chapterId);
      if (remote.contentKind != PluginContentKind.novel || remote.text == null) {
        throw StateError('The source chapter is not a text-reader chapter.');
      }
      await session.cacheChapter(entry: entry, text: remote.text!);
      _cachedChapterIds.add(chapterId);
      _failedChapterIds.remove(chapterId);
      return ChapterCacheItemResult.downloaded;
    } on Object {
      _failedChapterIds.add(chapterId);
      rethrow;
    }
  }

  ReaderChapterAvailability _availability(CatalogEntry entry) {
    if (entry.contentStatus == 'ready' || _cachedChapterIds.contains(entry.remoteIdentity)) {
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

  ReaderChapterAvailability availabilityFor(CatalogEntry entry) => _availability(entry);

  void _requireBook(String bookId) {
    if (bookId != item.id.value) {
      throw ArgumentError.value(bookId, 'bookId', 'Unexpected reader book ID.');
    }
  }
}

final class _SessionTextReaderDataSource implements TextReaderDataSource {
  const _SessionTextReaderDataSource({required this.item, required this.session, required this.chapterAccess, required this.sourceKind});

  final LibraryItem item;
  final NovelReaderSession session;
  final _SessionNovelChapterAccess chapterAccess;
  final ReaderBookSourceKind sourceKind;

  @override
  Future<ReaderBookInfo> loadBookInfo(String bookId) async {
    _requireBook(bookId);
    return ReaderBookInfo(
      id: bookId,
      title: item.title,
      author: item.author,
      description: item.description,
      sourceName: item.sourceName ?? '书架缓存',
      sourceUrl: item.sourceUrl,
      coverUrl: item.coverUrl,
      wordCount: item.wordCount,
      chapterCount: item.chapterCount ?? session.catalogCount,
      statusLabel: item.statusLabel,
      latestChapterTitle: item.latestChapterTitle,
      latestChapterUrl: item.latestChapterUrl,
      labels: item.labels,
      sourceKind: sourceKind,
    );
  }

  @override
  Future<ChapterCatalogPage> loadChapterCatalog(String bookId, {String? cursor, int pageSize = 100}) async {
    _requireBook(bookId);
    final page = await session.page(after: cursor, limit: pageSize.clamp(1, 500));
    return ChapterCatalogPage(
      items: [for (final entry in page.items) _chapterInfo(entry)],
      total: session.catalogCount,
      hasMore: page.nextCursor != null,
      nextCursor: page.nextCursor,
    );
  }

  @override
  Future<ReaderChapterInfo> loadChapterAtIndex(String bookId, int index) async {
    _requireBook(bookId);
    final entry = await session.itemAtIndex(index);
    if (entry == null) throw RangeError.index(index, session.catalogCount);
    return _chapterInfo(entry);
  }

  @override
  Future<TextChapterContent> loadChapterContent(String bookId, String chapterId) async {
    _requireBook(bookId);
    final content = await chapterAccess.load(chapterId);
    final entry = await session.itemByRemoteIdentity(chapterId);
    return TextChapterContent(
      chapterId: chapterId,
      title: content.title ?? entry?.title ?? chapterId,
      paragraphs: _readerParagraphs(chapterId, content.text ?? ''),
      contentVersion: content.updatedAt?.toUtc().toIso8601String(),
      chapterUrl: entry?.chapterUrl?.toString(),
    );
  }

  ReaderChapterInfo _chapterInfo(CatalogEntry entry) => ReaderChapterInfo(
    id: entry.remoteIdentity,
    title: entry.title,
    index: entry.index,
    availability: chapterAccess.availabilityFor(entry),
    wordCount: entry.wordCount,
  );

  void _requireBook(String bookId) {
    if (bookId != item.id.value) {
      throw ArgumentError.value(bookId, 'bookId');
    }
  }
}

List<TextParagraph> _readerParagraphs(String chapterId, String text) {
  final paragraphs = <TextParagraph>[];
  for (final line in text.split(RegExp(r'\r?\n\s*\r?\n'))) {
    final value = line.trim();
    if (value.isEmpty) continue;
    paragraphs.add(TextParagraph(id: '$chapterId:paragraph:${paragraphs.length}', text: value));
  }
  return paragraphs.isEmpty ? <TextParagraph>[TextParagraph(id: '$chapterId:paragraph:0', text: '')] : paragraphs;
}
