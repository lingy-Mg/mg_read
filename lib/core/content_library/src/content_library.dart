/// 应用自有 Content Library 实现。
///
/// 职责：
/// - 编排书架、目录、正文、封面、阅读进度和显式存储维护的受控持久化访问。
/// - 将数据源结果转换为主应用拥有的强类型内容对象。
/// - 注册 Content Library 元数据 codec、通知操作记录与有界小写入策略。
///
/// 注意：
/// - 不泄漏 SQLite、路径、动态 JSON 或 Runtime 传输对象。
/// - ContentLibrary 是业务数据权威；持久化与诊断失败必须保留既有边界。
/// - 所有新书架条目必须在 metadata 事务内遵守全局 100 本硬上限。
/// - 目录/正文引用写入、书架删除与清理共享可重入维护屏障，普通读取不排队。
/// - 通知写入是有界、串行且失败开放的附属工作，书架主操作不等待它。
///
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:mg_read/core/content_library/src/models.dart';
import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/core/persistence/persistence.dart';
import 'package:mg_read/core/persistence/src/diagnostic_sha256.dart';

part 'content_library_bookshelf.dart';
part 'content_library_reader.dart';
part 'content_library_bookmarks.dart';
part 'content_library_catalog.dart';
part 'content_library_content.dart';
part 'content_library_maintenance.dart';
part 'content_library_notifications.dart';

const _scope = ScopeKey(kind: 'content_library', id: 'default');
const _notificationKind = 'content_library_notification';
const _coverCacheMaxBytes = 100 * 1024 * 1024;
const _metadataInlinePreparationPolicy = JsonInlinePreparationPolicy(
  maxDocuments: 8,
  maxTotalNodes: 384,
  maxDepth: 8,
  maxCollectionLength: 64,
  maxTotalTextCodeUnits: 12 * 1024,
);

Iterable<RecordDocumentCodec> get contentLibraryRecordDocumentCodecs sync* {
  yield RecordDocumentCodec(
    recordKind: _notificationKind,
    scopeKind: _scope.kind,
    currentVersion: 1,
    validators: {1: _validateContentMetadata},
    inlinePreparationPolicy: _metadataInlinePreparationPolicy,
  );
}

RecordDocumentRegistry get _registry => RecordDocumentRegistry(contentLibraryRecordDocumentCodecs);
void _validateContentMetadata(JsonObject _) {}

final class ContentLibrary {
  ContentLibrary._(this._persistence, this._diagnostics, {required this._closePersistenceOnClose});
  final AppPersistence _persistence;
  final DiagnosticsManager? _diagnostics;
  final bool _closePersistenceOnClose;
  final _ContentLibraryMaintenanceBarrier _maintenanceBarrier = _ContentLibraryMaintenanceBarrier();
  Future<void> _notificationWriteTail = Future<void>.value();
  Future<void>? _closeFuture;
  bool _closing = false;
  late final _BookshelfOperations _bookshelf = _BookshelfOperations(this);
  late final _CatalogOperations _catalog = _CatalogOperations(this);
  late final _ContentOperations _content = _ContentOperations(this);
  late final _LibrarySyncOperations _sync = _LibrarySyncOperations(this);
  late final _CoverOperations _covers = _CoverOperations(this);
  late final _MangaImageCacheOperations _mangaImageCache = _MangaImageCacheOperations(this);
  late final _StorageMaintenanceOperations _storageMaintenance = _StorageMaintenanceOperations(this);
  late final _LibraryNotificationOperations _notifications = _LibraryNotificationOperations(this);
  static Future<ContentLibrary> open({required Directory dataRoot, DiagnosticsManager? diagnostics}) async => ContentLibrary._(
    await AppPersistence.open(dataRoot: dataRoot, registry: _registry, diagnostics: diagnostics),
    diagnostics,
    closePersistenceOnClose: true,
  );

  /// Creates the library over the composition root's single persistence owner.
  ///
  /// The supplied registry must include [contentLibraryRecordDocumentCodecs].
  /// The application composition root retains ownership of the supplied
  /// [AppPersistence]; [close] therefore leaves it open.
  factory ContentLibrary.fromPersistence(AppPersistence persistence, {DiagnosticsManager? diagnostics}) =>
      ContentLibrary._(persistence, diagnostics, closePersistenceOnClose: false);
  Future<void> close() => _closeFuture ??= _beginClose();
  Future<void> _beginClose() async {
    _closing = true;
    await _notificationWriteTail;
    if (_closePersistenceOnClose) await _persistence.close();
  }

  void _enqueueNotification({required LibraryNotificationKind kind, required String title}) {
    if (_closing) return;
    _notificationWriteTail = _notificationWriteTail.then((_) => _notifications.append(kind: kind, title: title)).catchError((Object _) {
      // Notifications are non-critical. A failed log write must never
      // change the bookshelf result or poison later queued records.
    });
  }

  Future<T> _withStorageMaintenance<T>(Future<T> Function() action) => _maintenanceBarrier.run(action);
  Future<List<LibraryShelfProjection>> loadShelfProjection({
    LibraryVisibility visibility = LibraryVisibility.normal,
    int limit = bookshelfMaxItemCount,
  }) async {
    final rows = await _persistence.metadataRecords.contentLibrary.listShelf(visibility: visibility.wireValue, limit: limit);
    return List<LibraryShelfProjection>.unmodifiable(rows.map(_storedShelfProjection));
  }

  int get businessQueryCountForTest => _persistence.metadataRecords.contentLibrary.businessQueryCountForTest;
  void resetBusinessQueryCountForTest() => _persistence.metadataRecords.contentLibrary.resetBusinessQueryCountForTest();
  Future<({int count, int revision})?> catalogStateForTest(LibraryItemId itemId) =>
      _persistence.metadataRecords.contentLibrary.catalogStateForTest(itemId.value);
  Future<List<String>> persistentTableNamesForTest() => _persistence.metadataRecords.contentLibrary.persistentTableNamesForTest();
  Future<Map<String, List<String>>> hotIndexPlansForTest(LibraryItemId itemId) =>
      _persistence.metadataRecords.contentLibrary.hotIndexPlansForTest(itemId.value);

  Future<LibraryProgress?> loadProgress(LibraryItemId itemId) => _trace(
    operation: 'progressLoad',
    itemCount: 1,
    action: () async {
      final row = await _persistence.metadataRecords.contentLibrary.readProgress(itemId.value);
      return row == null ? null : _storedProgress(row, itemId);
    },
    resultCount: (result) => result == null ? 0 : 1,
    resultState: (result) => result == null ? 'empty' : 'content',
  );

  Future<List<LibraryProgress>> _loadProgressMany(Iterable<LibraryItemId> itemIds) async {
    final ids = <String>{for (final itemId in itemIds) itemId.value};
    if (ids.isEmpty) return const <LibraryProgress>[];
    final rows = await _persistence.metadataRecords.contentLibrary.readProgressMany(ids);
    return List<LibraryProgress>.unmodifiable(rows.map((row) => _storedProgress(row, LibraryItemId(row.values['item_id']! as String))));
  }

  Future<void> saveProgress(LibraryProgress progress) => _trace(
    operation: 'progressSave',
    contentKind: progress.kind.code,
    itemCount: 1,
    action: () => _persistence.metadataRecords.contentLibrary.saveProgress(progress.itemId.value, _progressValues(progress)),
  );

  Future<List<LibraryBookmarkEntry>> loadBookmarks(LibraryItemId itemId, ContentKind kind) => _trace(
    operation: 'bookmarksLoad',
    contentKind: kind.code,
    itemCount: 1,
    action: () async {
      if (kind != ContentKind.novel && kind != ContentKind.manga) return const <LibraryBookmarkEntry>[];
      final rows = await _persistence.metadataRecords.contentLibrary.listBookmarks(itemId.value, kind.code);
      return List<LibraryBookmarkEntry>.unmodifiable(
        rows.map((row) => kind == ContentKind.novel ? _storedBookmark(row, itemId) : _storedMangaBookmark(row, itemId)),
      );
    },
  );

  Future<void> saveBookmark(LibraryBookmarkEntry bookmark) => _trace(
    operation: 'bookmarkSave',
    contentKind: bookmark.bookmarkKind.code,
    itemCount: 1,
    action: () => _persistence.metadataRecords.contentLibrary.saveBookmark(bookmark.itemId.value, _bookmarkValues(bookmark)),
  );

  Future<void> deleteBookmark(LibraryItemId itemId, String bookmarkId) =>
      _persistence.metadataRecords.contentLibrary.deleteBookmark(itemId.value, bookmarkId);

  Future<LibraryItem> addLibraryItem(BookshelfAddRequest request) => _bookshelf.add(request);
  Future<void> removeLibraryItem(LibraryItemId id, LibraryRemovalPolicy policy) => _bookshelf.remove(id, policy);
  Future<void> setLibraryItemVisibility(LibraryItemId id, LibraryVisibility visibility) => _bookshelf.setVisibility(id, visibility);
  Future<Page<LibraryItem>> listLibrary(LibraryQuery query) => _bookshelf.list(query);
  Future<LibraryItem?> getLibraryItem(LibraryItemId id) => _bookshelf.get(id);
  Future<Page<CatalogEntry>> listCatalog(LibraryItemId itemId, CatalogQuery query) => _catalog.list(itemId, query);
  Future<List<CatalogEntry>> listAllCatalog(LibraryItemId itemId) => _catalog.listAll(itemId);
  Future<int> ensureNovelCatalog({required LibraryItemId itemId, required Iterable<SourceNovelCatalogChapter> chapters}) =>
      _catalog.ensureNovelCatalog(itemId: itemId, chapters: chapters);
  Future<int> syncNovelCatalog({required LibraryItemId itemId, required Iterable<SourceNovelCatalogChapter> chapters}) =>
      _catalog.syncNovelCatalog(itemId: itemId, chapters: chapters);
  Future<int> syncMangaCatalog({required LibraryItemId itemId, required Iterable<MangaChapterDescriptor> chapters}) =>
      _catalog.syncMangaCatalog(itemId: itemId, chapters: chapters);
  Future<ReadableContent?> openContent(CatalogEntryId id) => _content.open(id);
  Future<void> cacheMangaChapter({required CatalogEntryId entryId, required Iterable<MangaPageDescriptor> pages}) =>
      _content.cacheMangaChapter(entryId: entryId, pages: pages);
  Future<List<int>?> readCover(CoverKey key) => _covers.read(key);
  Future<void> saveCover({required CoverKey key, required List<int> bytes, String mimeType = 'image/unknown'}) =>
      _covers.save(key: key, bytes: bytes, mimeType: mimeType);
  Future<void> removeCover(CoverKey key) => _covers.remove(key);
  Future<int> coverCacheUsageBytes() => _covers.usageBytes();
  Future<int> clearCoverCache() => _covers.clear();
  Future<List<int>?> readMangaImage({
    required LibraryItemId itemId,
    required String chapterId,
    required String pageId,
    required int contentVersion,
  }) => _mangaImageCache.read(itemId: itemId, chapterId: chapterId, pageId: pageId, contentVersion: contentVersion);
  Future<void> saveMangaImage({
    required LibraryItemId itemId,
    required String chapterId,
    required String pageId,
    required int contentVersion,
    required List<int> bytes,
    required String mimeType,
  }) => _mangaImageCache.save(
    itemId: itemId,
    chapterId: chapterId,
    pageId: pageId,
    contentVersion: contentVersion,
    bytes: bytes,
    mimeType: mimeType,
  );
  Future<int> mangaImageCacheUsageBytes() => _mangaImageCache.usageBytes();
  Future<MangaImageCacheStorageUsage> inspectMangaImageCache() => _mangaImageCache.usage();
  Future<int> clearMangaImageCache() => _mangaImageCache.clear();
  Future<StorageCleanupPreview> inspectStorage() => _storageMaintenance.inspect();
  Future<StorageCleanupResult> clearStorage() => _storageMaintenance.clearAll();
  Future<StorageCompactionResult> compactStorage() => _storageMaintenance.compact();
  Future<List<LibraryNotification>> loadNotifications({int limit = libraryNotificationMaxCount}) => _notifications.list(limit: limit);
  Future<void> clearNotifications() => _notifications.clear();
  Future<MangaReaderSession?> openMangaReaderSession(LibraryItemId itemId) => _trace(
    operation: 'mangaReaderSessionOpen',
    contentKind: ContentKind.manga.code,
    itemCount: 1,
    action: () => _openMangaReaderSession(itemId),
    resultCount: (result) => result == null ? 0 : 1,
    resultState: (result) => result == null ? 'empty' : 'content',
  );

  Future<MangaReaderSession?> _openMangaReaderSession(LibraryItemId itemId) async {
    final projection = await _persistence.metadataRecords.contentLibrary.openReaderProjection(itemId.value, ContentKind.manga.code);
    final chapter = projection?.chapter;
    if (projection == null || chapter == null) return null;
    final count = projection.values['catalog_count']! as int;
    return MangaReaderSession._(
      library: this,
      item: _storedItem(projection.item),
      initialChapter: _storedEntry(chapter, itemId),
      catalogCount: count,
    );
  }

  Future<void> cacheNovelChapter({required LibraryItemId itemId, required String remoteChapterId, required String text}) =>
      _content.cacheNovelChapter(itemId: itemId, remoteChapterId: remoteChapterId, text: text);

  Future<LibrarySyncSnapshot> createSyncSnapshot() => _sync.createSnapshot();

  Future<LibrarySyncPreview> previewSyncSnapshot(LibrarySyncSnapshot snapshot, {required Set<String> availablePluginIds}) =>
      _sync.preview(snapshot, availablePluginIds: availablePluginIds);

  Future<LibrarySyncApplyResult> applySyncSnapshot(
    LibrarySyncSnapshot snapshot, {
    required LibrarySyncPreview preview,
    required Map<LibrarySyncIdentity, LibrarySyncConflictChoice> choices,
  }) => _sync.apply(snapshot, preview: preview, choices: choices);

  /// Opens a novel against the catalog count captured by one metadata query.
  ///
  /// The returned session never follows later appends, so background sync only
  /// becomes visible after the reader is reopened.
  Future<NovelReaderSession?> openNovelReaderSession(LibraryItemId itemId) => _trace(
    operation: 'novelReaderSessionOpen',
    contentKind: ContentKind.novel.code,
    itemCount: 1,
    action: () => _openNovelReaderSession(itemId),
    resultCount: (result) => result == null ? 0 : 1,
    resultState: (result) => result == null ? 'empty' : 'content',
  );

  Future<NovelReaderSession?> _openNovelReaderSession(LibraryItemId itemId) async {
    final projection = await _persistence.metadataRecords.contentLibrary.openReaderProjection(itemId.value, ContentKind.novel.code);
    final chapter = projection?.chapter;
    if (projection == null || chapter == null) return null;
    final item = _storedItem(projection.item);
    final catalogCount = projection.values['catalog_count']! as int;
    final progress = projection.progress == null ? null : _storedReadingProgress(projection.progress!, itemId);
    return NovelReaderSession._(
      library: this,
      item: item,
      progress: progress,
      initialChapter: _storedEntry(chapter, itemId),
      catalogCount: catalogCount,
    );
  }

  Future<T> _trace<T>({
    required String operation,
    String? contentKind,
    int? itemCount,
    int? bytes,
    required Future<T> Function() action,
    int? Function(T result)? resultCount,
    String Function(T result)? resultState,
  }) {
    final diagnostics = _diagnostics;
    if (diagnostics == null || diagnostics.isClosed) return action();
    return diagnostics.runSpan<T>(
      AppDiagnosticEvents.libraryOperation,
      (span) async {
        final stopwatch = Stopwatch()..start();
        try {
          final result = await action();
          stopwatch.stop();
          reportSlowDiagnostic(
            diagnostics,
            subjectComponent: 'core.content-library',
            operation: operation,
            elapsed: stopwatch.elapsed,
            threshold: AppDiagnosticThresholds.libraryOperation,
            outcome: DiagnosticOutcome.success,
            traceContext: span.traceContext,
          );
          return result;
        } catch (_) {
          stopwatch.stop();
          reportSlowDiagnostic(
            diagnostics,
            subjectComponent: 'core.content-library',
            operation: operation,
            elapsed: stopwatch.elapsed,
            threshold: AppDiagnosticThresholds.libraryOperation,
            outcome: DiagnosticOutcome.error,
            traceContext: span.traceContext,
          );
          rethrow;
        }
      },
      startAttributes: () => _libraryAttributes(operation: operation, contentKind: contentKind, itemCount: itemCount, bytes: bytes),
      successAttributes: (result) => _libraryAttributes(
        operation: operation,
        contentKind: contentKind,
        itemCount: resultCount?.call(result) ?? itemCount,
        bytes: bytes,
        resultState: resultState?.call(result) ?? 'success',
      ),
      errorAttributes: (_) => _libraryAttributes(
        operation: operation,
        contentKind: contentKind,
        itemCount: itemCount,
        bytes: bytes,
        resultState: 'failure',
        errorCode: 'operation_failed',
      ),
    );
  }
}
