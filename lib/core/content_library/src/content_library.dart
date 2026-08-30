/// 应用自有 Content Library 实现。
///
/// 职责：
/// - 编排书架、目录、正文、封面、阅读进度和显式存储维护的受控持久化访问。
/// - 将数据源结果转换为主应用拥有的强类型内容对象。
/// - 注册 Content Library 元数据 codec 与有界小写入策略。
///
/// 注意：
/// - 不泄漏 SQLite、路径、动态 JSON 或 Runtime 传输对象。
/// - ContentLibrary 是业务数据权威；持久化与诊断失败必须保留既有边界。
/// - 所有新书架条目必须在 metadata 事务内遵守全局 100 本硬上限。
/// - 目录/正文引用写入、书架删除与清理共享可重入维护屏障，普通读取不排队。
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

const _scope = ScopeKey(kind: 'content_library', id: 'default');
const _itemKind = 'content_library_item';
const _bindingKind = 'content_source_binding';
const _entryKind = 'content_catalog_entry';
const _readingProgressKind = 'content_library_reading_progress';
const _bookmarkKind = 'content_library_bookmark';
const _mangaProgressKind = 'content_library_manga_progress';
const _audioProgressKind = 'content_library_audio_progress';
const _videoProgressKind = 'content_library_video_progress';
const _mangaBookmarkKind = 'content_library_manga_bookmark';
const _coverCacheMaxBytes = 100 * 1024 * 1024;
const _metadataInlinePreparationPolicy = JsonInlinePreparationPolicy(
  maxDocuments: 8,
  maxTotalNodes: 384,
  maxDepth: 8,
  maxCollectionLength: 64,
  maxTotalTextCodeUnits: 12 * 1024,
);

Iterable<RecordDocumentCodec> get contentLibraryRecordDocumentCodecs sync* {
  for (final kind in [
    _itemKind,
    _bindingKind,
    _entryKind,
    _readingProgressKind,
    _bookmarkKind,
    _mangaProgressKind,
    _audioProgressKind,
    _videoProgressKind,
    _mangaBookmarkKind,
  ]) {
    yield RecordDocumentCodec(
      recordKind: kind,
      scopeKind: _scope.kind,
      currentVersion: 1,
      validators: {1: _validateContentMetadata},
      inlinePreparationPolicy: _metadataInlinePreparationPolicy,
    );
  }
}

RecordDocumentRegistry get _registry => RecordDocumentRegistry(contentLibraryRecordDocumentCodecs);
void _validateContentMetadata(JsonObject _) {}

final class ContentLibrary {
  ContentLibrary._(this._persistence, this._diagnostics, {required this._closePersistenceOnClose});
  final AppPersistence _persistence;
  final DiagnosticsManager? _diagnostics;
  final bool _closePersistenceOnClose;
  final _ContentLibraryMaintenanceBarrier _maintenanceBarrier = _ContentLibraryMaintenanceBarrier();
  late final BookshelfRepository bookshelf = BookshelfRepository._(this);
  late final CatalogRepository catalog = CatalogRepository._(this);
  late final ContentRepository content = ContentRepository._(this);
  late final ReadingProgressRepository readingProgress = ReadingProgressRepository._(this);
  late final AudioProgressRepository audioProgress = AudioProgressRepository._(this);
  late final VideoProgressRepository videoProgress = VideoProgressRepository._(this);
  late final BookmarkRepository bookmarks = BookmarkRepository._(this);
  late final MangaStateRepository mangaState = MangaStateRepository._(this);
  late final LibrarySyncRepository sync = LibrarySyncRepository._(this);
  late final CoverRepository covers = CoverRepository._(this);
  late final MangaImageCacheRepository mangaImageCache = MangaImageCacheRepository._(this);
  late final StorageMaintenanceRepository storageMaintenance = StorageMaintenanceRepository._(this);
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
  Future<void> close() => _closePersistenceOnClose ? _persistence.close() : Future<void>.value();
  Future<T> _withStorageMaintenance<T>(Future<T> Function() action) => _maintenanceBarrier.run(action);
  Future<Page<LibraryItem>> listLibrary(LibraryQuery query) => bookshelf.list(query);
  Future<LibraryItem?> getLibraryItem(LibraryItemId id) => bookshelf.get(id);
  Future<Page<CatalogEntry>> listCatalog(LibraryItemId itemId, CatalogQuery query) => catalog.list(itemId, query);
  Future<List<CatalogEntry>> listAllCatalog(LibraryItemId itemId) => catalog.listAll(itemId);
  Future<int> ensureNovelCatalog({required LibraryItemId itemId, required Iterable<SourceNovelCatalogChapter> chapters}) =>
      catalog.ensureNovelCatalog(itemId: itemId, chapters: chapters);
  Future<int> syncNovelCatalog({required LibraryItemId itemId, required Iterable<SourceNovelCatalogChapter> chapters}) =>
      catalog.syncNovelCatalog(itemId: itemId, chapters: chapters);
  Future<int> syncMangaCatalog({required LibraryItemId itemId, required Iterable<MangaChapterDescriptor> chapters}) =>
      catalog.syncMangaCatalog(itemId: itemId, chapters: chapters);
  Future<ReadableContent?> openContent(CatalogEntryId id) => content.open(id);
  Future<void> cacheMangaChapter({required CatalogEntryId entryId, required Iterable<MangaPageDescriptor> pages}) =>
      content.cacheMangaChapter(entryId: entryId, pages: pages);
  Future<LibraryMangaReadingProgress?> loadMangaProgress(LibraryItemId itemId) => mangaState.loadProgress(itemId);
  Future<void> saveMangaProgress(LibraryMangaReadingProgress value) => mangaState.saveProgress(value);
  Future<LibraryAudioPlaybackProgress?> loadAudioProgress(LibraryItemId itemId) => audioProgress.load(itemId);
  Future<void> saveAudioProgress(LibraryAudioPlaybackProgress value) => audioProgress.save(value);
  Future<LibraryVideoPlaybackProgress?> loadVideoProgress(LibraryItemId itemId) => videoProgress.load(itemId);
  Future<void> saveVideoProgress(LibraryVideoPlaybackProgress value) => videoProgress.save(value);
  Future<List<LibraryMangaBookmark>> listMangaBookmarks(LibraryItemId itemId) => mangaState.listBookmarks(itemId);
  Future<void> addMangaBookmark(LibraryMangaBookmark value) => mangaState.addBookmark(value);
  Future<void> removeMangaBookmark(LibraryItemId itemId, String bookmarkId) => mangaState.removeBookmark(itemId, bookmarkId);
  Future<MangaReaderSession?> openMangaReaderSession(LibraryItemId itemId) => _trace(
    operation: 'mangaReaderSessionOpen',
    contentKind: ContentKind.manga.code,
    itemCount: 1,
    action: () => _openMangaReaderSession(itemId),
    resultCount: (result) => result == null ? 0 : 1,
    resultState: (result) => result == null ? 'empty' : 'content',
  );

  Future<MangaReaderSession?> _openMangaReaderSession(LibraryItemId itemId) async {
    final record = await _persistence.metadataRecords.read(id: itemId.value, scope: _scope);
    if (record == null || record.recordKind != _itemKind) return null;
    final item = _item(record);
    if (item.kind != ContentKind.manga) return null;
    final snapshot = record.document['activeSnapshotId'];
    if (snapshot is! String || snapshot.isEmpty) return null;
    final first = await _persistence.metadataRecords.list(
      RecordQuery(recordKind: _entryKind, scope: _scope, parentId: itemId.value, stateKey: 'pending:$snapshot', limit: 1),
    );
    if (first.records.isEmpty) return null;
    final binding = first.records.single.document['bindingId'];
    if (binding is! String || binding.isEmpty) return null;
    final count = record.document['catalogCount'] is int ? record.document['catalogCount'] as int : first.records.length;
    return MangaReaderSession._(library: this, item: item, catalogCount: count, snapshot: snapshot, bindingId: SourceBindingId(binding));
  }

  Future<void> cacheNovelChapter({required LibraryItemId itemId, required String remoteChapterId, required String text}) =>
      content.cacheNovelChapter(itemId: itemId, remoteChapterId: remoteChapterId, text: text);

  Future<LibrarySyncSnapshot> createSyncSnapshot() => sync.createSnapshot();

  Future<LibrarySyncPreview> previewSyncSnapshot(LibrarySyncSnapshot snapshot, {required Set<String> availablePluginIds}) =>
      sync.preview(snapshot, availablePluginIds: availablePluginIds);

  Future<LibrarySyncApplyResult> applySyncSnapshot(
    LibrarySyncSnapshot snapshot, {
    required LibrarySyncPreview preview,
    required Map<LibrarySyncIdentity, LibrarySyncConflictChoice> choices,
  }) => sync.apply(snapshot, preview: preview, choices: choices);

  /// Opens a novel against one immutable active catalog snapshot.
  ///
  /// The returned session never follows a later catalog refresh; callers can
  /// therefore keep chapter identity stable while a background refresh runs.
  Future<NovelReaderSession?> openNovelReaderSession(LibraryItemId itemId) => _trace(
    operation: 'novelReaderSessionOpen',
    contentKind: ContentKind.novel.code,
    itemCount: 1,
    action: () => _openNovelReaderSession(itemId),
    resultCount: (result) => result == null ? 0 : 1,
    resultState: (result) => result == null ? 'empty' : 'content',
  );

  Future<NovelReaderSession?> _openNovelReaderSession(LibraryItemId itemId) async {
    final record = await _persistence.metadataRecords.read(id: itemId.value, scope: _scope);
    if (record == null || record.recordKind != _itemKind) return null;
    final item = _item(record);
    if (item.kind != ContentKind.novel) return null;
    final snapshot = record.document['activeSnapshotId'];
    if (snapshot is! String || snapshot.isEmpty) return null;
    final progressFuture = readingProgress._load(itemId);
    final firstEntry = await _persistence.metadataRecords.list(
      RecordQuery(recordKind: _entryKind, scope: _scope, parentId: itemId.value, stateKey: 'pending:$snapshot', limit: 1),
    );
    if (firstEntry.records.isEmpty) {
      await progressFuture;
      return null;
    }
    final storedBinding = firstEntry.records.single.document['bindingId'];
    SourceBindingId bindingId;
    if (storedBinding is String && storedBinding.isNotEmpty) {
      bindingId = SourceBindingId(storedBinding);
    } else {
      final bindings = await _persistence.metadataRecords.list(
        RecordQuery(recordKind: _bindingKind, scope: _scope, parentId: itemId.value, limit: 1),
      );
      if (bindings.records.isEmpty) return null;
      bindingId = SourceBindingId(bindings.records.single.id);
    }
    final storedCatalogCount = record.document['catalogCount'];
    var catalogCount = storedCatalogCount is int
        ? storedCatalogCount
        : await _persistence.metadataRecords.count(
            RecordQuery(recordKind: _entryKind, scope: _scope, parentId: itemId.value, stateKey: 'pending:$snapshot', limit: 1),
          );
    if (storedCatalogCount is! int) {
      try {
        await _persistence.metadataRecords.update(previous: record, document: {...record.document, 'catalogCount': catalogCount});
      } on PersistenceConflictError {
        // A concurrent snapshot switch owns the newer item revision.
      }
    }
    final progress = await progressFuture;
    return NovelReaderSession._(
      library: this,
      item: item,
      progress: progress,
      catalogCount: catalogCount,
      snapshot: snapshot,
      bindingId: bindingId,
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
