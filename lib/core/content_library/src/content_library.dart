import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:mg_read/core/content_library/src/models.dart';
import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/core/persistence/persistence.dart';
import 'package:mg_read/core/persistence/src/diagnostic_sha256.dart';

const _scope = ScopeKey(kind: 'content_library', id: 'default');
const _itemKind = 'content_library_item';
const _bindingKind = 'content_source_binding';
const _entryKind = 'content_catalog_entry';
const _readingProgressKind = 'content_library_reading_progress';
const _coverCacheMaxBytes = 100 * 1024 * 1024;

final class ContentLibrary {
  ContentLibrary._(
    this._persistence,
    this._diagnostics, {
    required this._closePersistenceOnClose,
  });
  final AppPersistence _persistence;
  final DiagnosticsManager? _diagnostics;
  final bool _closePersistenceOnClose;
  late final BookshelfRepository bookshelf = BookshelfRepository._(this);
  late final CatalogRepository catalog = CatalogRepository._(this);
  late final ContentRepository content = ContentRepository._(this);
  late final ReadingProgressRepository readingProgress =
      ReadingProgressRepository._(this);
  late final CoverRepository covers = CoverRepository._(this);
  static Future<ContentLibrary> open({
    required Directory dataRoot,
    DiagnosticsManager? diagnostics,
  }) async => ContentLibrary._(
    await AppPersistence.open(
      dataRoot: dataRoot,
      registry: _registry,
      diagnostics: diagnostics,
    ),
    diagnostics,
    closePersistenceOnClose: true,
  );

  /// Creates the library over the composition root's single persistence owner.
  ///
  /// The supplied registry must include [contentLibraryRecordDocumentCodecs].
  /// The application composition root retains ownership of the supplied
  /// [AppPersistence]; [close] therefore leaves it open.
  factory ContentLibrary.fromPersistence(
    AppPersistence persistence, {
    DiagnosticsManager? diagnostics,
  }) => ContentLibrary._(
    persistence,
    diagnostics,
    closePersistenceOnClose: false,
  );
  Future<void> close() =>
      _closePersistenceOnClose ? _persistence.close() : Future<void>.value();
  Future<Page<LibraryItem>> listLibrary(LibraryQuery query) =>
      bookshelf.list(query);
  Future<LibraryItem?> getLibraryItem(LibraryItemId id) => bookshelf.get(id);
  Future<Page<CatalogEntry>> listCatalog(
    LibraryItemId itemId,
    CatalogQuery query,
  ) => catalog.list(itemId, query);
  Future<List<CatalogEntry>> listAllCatalog(LibraryItemId itemId) =>
      catalog.listAll(itemId);
  Future<List<CatalogEntry>> ensureNovelCatalog({
    required LibraryItemId itemId,
    required Iterable<SourceNovelCatalogChapter> chapters,
  }) => catalog.ensureNovelCatalog(itemId: itemId, chapters: chapters);
  Future<List<CatalogEntry>> syncNovelCatalog({
    required LibraryItemId itemId,
    required Iterable<SourceNovelCatalogChapter> chapters,
  }) => catalog.syncNovelCatalog(itemId: itemId, chapters: chapters);
  Future<ReadableContent?> openContent(CatalogEntryId id) => content.open(id);
  Future<void> cacheNovelChapter({
    required LibraryItemId itemId,
    required String remoteChapterId,
    required String text,
  }) => content.cacheNovelChapter(
    itemId: itemId,
    remoteChapterId: remoteChapterId,
    text: text,
  );

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
      startAttributes: () => _libraryAttributes(
        operation: operation,
        contentKind: contentKind,
        itemCount: itemCount,
        bytes: bytes,
      ),
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

final class BookshelfRepository {
  BookshelfRepository._(this._library);
  final ContentLibrary _library;
  Future<LibraryItem> add({
    required String title,
    String? author,
    required ContentKind kind,
    required ContentLibraryIngest source,
  }) => _library._trace(
    operation: 'bookshelfAdd',
    contentKind: kind.code,
    itemCount: 1,
    action: () =>
        _add(title: title, author: author, kind: kind, source: source),
  );

  /// Adds or returns the item identified by a typed source reference.
  ///
  /// Feature adapters use this public operation instead of seeing the
  /// Runtime-facing ingest payload used by the persistence implementation.
  Future<LibraryItem> addFromSource(BookshelfAddRequest request) => add(
    title: request.title,
    author: request.author,
    kind: request.kind,
    source: ContentLibraryIngest(
      pluginId: request.pluginId,
      producerPluginVersion: request.pluginVersion,
      dataVersion: 1,
      opaqueData: <String, Object?>{
        'remoteBookId': request.remoteContentId,
        if (request.coverUrl != null) 'coverUrl': request.coverUrl.toString(),
        if (request.sourceName != null) 'sourceName': request.sourceName,
      },
    ),
  );

  Future<Page<LibraryItem>> list(LibraryQuery query) => _library._trace(
    operation: 'bookshelfList',
    itemCount: query.limit,
    action: () => _list(query),
    resultCount: (result) => result.items.length,
    resultState: (result) => result.items.isEmpty ? 'empty' : 'content',
  );

  /// Reads one shelf item by its app-owned stable identifier.
  Future<LibraryItem?> get(LibraryItemId id) => _library._trace(
    operation: 'bookshelfGet',
    itemCount: 1,
    action: () async {
      final record = await _library._persistence.metadataRecords.read(
        id: id.value,
        scope: _scope,
      );
      return record == null || record.recordKind != _itemKind
          ? null
          : _item(record);
    },
    resultCount: (result) => result == null ? 0 : 1,
    resultState: (result) => result == null ? 'empty' : 'content',
  );

  /// Reads the durable cover owned by [id], if the first-load fetch succeeded.
  ///
  /// The file object path remains private to the app-owned persistence layer.
  Future<List<int>?> readCover(LibraryItemId id) => _library._trace(
    operation: 'bookshelfCoverRead',
    contentKind: 'image',
    itemCount: 1,
    action: () => _library._persistence.fileObjects.readCoverBytes(id.value),
    resultCount: (result) => result == null ? 0 : 1,
    resultState: (result) => result == null ? 'miss' : 'hit',
  );

  /// Persists one validated cover after it has been fetched from its source.
  Future<void> saveCover({
    required LibraryItemId id,
    required List<int> bytes,
    required String mimeType,
  }) => _library._trace(
    operation: 'bookshelfCoverSave',
    contentKind: 'image',
    itemCount: 1,
    bytes: bytes.length,
    action: () async {
      _validateCover(bytes, mimeType);
      await _library._persistence.fileObjects.commitCoverBytes(
        itemId: id.value,
        bytes: bytes,
        mimeType: mimeType,
      );
    },
  );

  Future<void> remove(LibraryItemId id, LibraryRemovalPolicy policy) =>
      _library._trace(
        operation: 'bookshelfRemove',
        itemCount: 1,
        action: () => _remove(id, policy),
      );

  /// Changes only the local shelf visibility for one item.
  ///
  /// The retained catalog, cached content, covers, and reading progress are
  /// deliberately unaffected.
  Future<void> setVisibility(LibraryItemId id, LibraryVisibility visibility) =>
      _library._trace(
        operation: 'bookshelfSetVisibility',
        itemCount: 1,
        action: () => _setVisibility(id, visibility),
      );

  Future<LibraryItem> _add({
    required String title,
    String? author,
    required ContentKind kind,
    required ContentLibraryIngest source,
  }) async {
    _safeText(title);
    final identity =
        '${source.pluginId}:${source.opaqueData['remoteBookId'] ?? title}';
    return _library._persistence.metadataRecords.transaction(() async {
      final existing = await _library._persistence.metadataRecords.list(
        RecordQuery(
          recordKind: _itemKind,
          scope: _scope,
          identityKey: identity,
          limit: 1,
        ),
      );
      final shelfSummary = _shelfSummary(source);
      if (existing.records.isNotEmpty) {
        final previous = existing.records.single;
        final updated = await _library._persistence.metadataRecords.update(
          previous: previous,
          document: <String, Object?>{
            ...previous.document,
            'title': title,
            'author': ?author,
            'summary': <String, Object?>{
              ..._summaryFromDocument(previous.document),
              ...shelfSummary,
            },
          },
        );
        return _item(updated);
      }
      final id = _id();
      final document = {
        'title': title,
        'author': ?author,
        'kind': kind.code,
        'plugin': _plugin(source),
        'summary': shelfSummary,
      };
      final record = await _library._persistence.metadataRecords.create(
        RecordDraft(
          id: id,
          recordKind: _itemKind,
          scope: _scope,
          identityKey: identity,
          orderKey: id,
          stateKey: 'active',
          document: document,
        ),
      );
      await _library._persistence.metadataRecords.create(
        RecordDraft(
          id: _id(),
          recordKind: _bindingKind,
          scope: _scope,
          parentId: id,
          identityKey: identity,
          orderKey: '0',
          stateKey: 'available',
          document: {'itemId': id, 'plugin': _plugin(source)},
        ),
      );
      return _item(record);
    });
  }

  Future<Page<LibraryItem>> _list(LibraryQuery query) async {
    final page = await _library._persistence.metadataRecords.list(
      RecordQuery(
        recordKind: _itemKind,
        scope: _scope,
        stateKey: query.state,
        after: _cursor(query.after),
        limit: query.limit,
      ),
    );
    final items = page.records
        .map(_item)
        .where(
          (item) =>
              query.visibility == null || item.visibility == query.visibility,
        )
        .toList(growable: false);
    return Page(items: items, nextCursor: _cursorText(page.nextCursor));
  }

  Future<void> _setVisibility(
    LibraryItemId id,
    LibraryVisibility visibility,
  ) async {
    final record = await _library._persistence.metadataRecords.read(
      id: id.value,
      scope: _scope,
    );
    if (record == null || record.recordKind != _itemKind) return;
    if (_visibilityFromDocument(record.document) == visibility) return;
    await _library._persistence.metadataRecords.update(
      previous: record,
      document: <String, Object?>{
        ...record.document,
        'visibility': visibility.wireValue,
      },
    );
  }

  Future<void> _remove(LibraryItemId id, LibraryRemovalPolicy policy) async {
    final record = await _library._persistence.metadataRecords.read(
      id: id.value,
      scope: _scope,
    );
    if (record == null) return;
    if (record.document['kind'] == ContentKind.manga.code) {
      await _library._persistence.fileObjects.deleteMangaAssets(id.value);
    }
    await _library._persistence.fileObjects.deleteCover(id.value);
    await _library._persistence.metadataRecords.delete(
      previous: record,
    ); /* objects remain unless a later bounded maintenance pass proves no references */
  }
}

/// App-owned, cross-feature persistence for regenerable source covers.
///
/// Search, discovery, detail and bookshelf adapters all address the same
/// source cover through [CoverKey]. The repository exposes bytes only; file
/// paths and eviction details remain inside the persistence boundary.
final class CoverRepository {
  CoverRepository._(this._library);

  final ContentLibrary _library;

  Future<List<int>?> read(CoverKey key) => _library._trace(
    operation: 'coverRead',
    contentKind: 'image',
    itemCount: 1,
    action: () => _library._persistence.fileObjects.readGlobalCoverBytes(
      _storageKey(key),
    ),
    resultCount: (result) => result == null ? 0 : 1,
    resultState: (result) => result == null ? 'miss' : 'hit',
  );

  Future<void> save({
    required CoverKey key,
    required List<int> bytes,
    String mimeType = 'image/unknown',
  }) => _library._trace(
    operation: 'coverSave',
    contentKind: 'image',
    itemCount: 1,
    bytes: bytes.length,
    action: () async {
      _validateCover(bytes, mimeType);
      await _library._persistence.fileObjects.commitGlobalCoverBytes(
        coverKey: _storageKey(key),
        bytes: bytes,
        mimeType: mimeType,
      );
      await _library._persistence.fileObjects.pruneGlobalCovers(
        maxBytes: _coverCacheMaxBytes,
      );
    },
  );
}

/// Stores the user-owned semantic position reported by the text reader.
final class ReadingProgressRepository {
  ReadingProgressRepository._(this._library);

  final ContentLibrary _library;

  /// Returns the latest saved position, if the item has been opened before.
  Future<LibraryReadingProgress?> load(LibraryItemId itemId) => _library._trace(
    operation: 'readingProgressLoad',
    itemCount: 1,
    action: () => _load(itemId),
    resultCount: (result) => result == null ? 0 : 1,
    resultState: (result) => result == null ? 'empty' : 'content',
  );

  /// Reads the saved positions for several shelf items in one metadata query.
  ///
  /// Missing positions are omitted. A repeated item ID is read once, and any
  /// duplicate persisted record keeps the same first-record behavior as [load].
  Future<List<LibraryReadingProgress>> loadMany(
    Iterable<LibraryItemId> itemIds,
  ) {
    final itemIdsByValue = <String>{for (final itemId in itemIds) itemId.value};
    return _library._trace(
      operation: 'readingProgressLoadMany',
      itemCount: itemIdsByValue.length,
      action: () => _loadMany(itemIdsByValue),
      resultCount: (result) => result.length,
      resultState: (result) => result.isEmpty ? 'empty' : 'content',
    );
  }

  /// Persists a layout-independent reading position for [progress.itemId].
  Future<void> save(LibraryReadingProgress progress) => _library._trace(
    operation: 'readingProgressSave',
    itemCount: 1,
    action: () => _save(progress),
  );

  Future<LibraryReadingProgress?> _load(LibraryItemId itemId) async {
    final page = await _library._persistence.metadataRecords.list(
      RecordQuery(
        recordKind: _readingProgressKind,
        scope: _scope,
        identityKey: itemId.value,
        limit: 1,
      ),
    );
    return page.records.isEmpty ? null : _readingProgress(page.records.single);
  }

  Future<List<LibraryReadingProgress>> _loadMany(
    Set<String> itemIdsByValue,
  ) async {
    if (itemIdsByValue.isEmpty) return const <LibraryReadingProgress>[];
    final records = await _library._persistence.metadataRecords
        .listByIdentityKeys(
          recordKind: _readingProgressKind,
          scope: _scope,
          identityKeys: itemIdsByValue,
        );
    final progressByItemId = <String, LibraryReadingProgress>{};
    for (final record in records) {
      final itemId = record.identityKey;
      if (itemId == null || progressByItemId.containsKey(itemId)) continue;
      progressByItemId[itemId] = _readingProgress(record);
    }
    return List<LibraryReadingProgress>.unmodifiable(progressByItemId.values);
  }

  Future<void> _save(LibraryReadingProgress progress) async {
    final existing = await _library._persistence.metadataRecords.list(
      RecordQuery(
        recordKind: _readingProgressKind,
        scope: _scope,
        identityKey: progress.itemId.value,
        limit: 1,
      ),
    );
    final document = _readingProgressDocument(progress);
    if (existing.records.isNotEmpty) {
      await _library._persistence.metadataRecords.update(
        previous: existing.records.single,
        document: document,
      );
      return;
    }
    await _library._persistence.metadataRecords.create(
      RecordDraft(
        id: _id(),
        recordKind: _readingProgressKind,
        scope: _scope,
        parentId: progress.itemId.value,
        identityKey: progress.itemId.value,
        orderKey: _timestampOrderKey(progress.updatedAtUtc),
        stateKey: 'active',
        document: document,
      ),
    );
  }
}

final class CatalogRepository {
  CatalogRepository._(this._library);
  final ContentLibrary _library;
  Future<void> replaceSnapshot({
    required LibraryItemId itemId,
    required SourceBindingId bindingId,
    required Iterable<IngestCatalogEntry> entries,
  }) {
    final copied = List<IngestCatalogEntry>.of(entries);
    return _library._trace(
      operation: 'catalogReplaceSnapshot',
      itemCount: copied.length,
      action: () => _replaceSnapshot(
        itemId: itemId,
        bindingId: bindingId,
        entries: copied,
      ),
    );
  }

  Future<Page<CatalogEntry>> list(LibraryItemId itemId, CatalogQuery query) =>
      _library._trace(
        operation: 'catalogList',
        itemCount: query.limit,
        action: () => _list(itemId, query),
        resultCount: (result) => result.items.length,
        resultState: (result) => result.items.isEmpty ? 'empty' : 'content',
      );

  /// Returns the active catalog for one item without leaking persistence cursors.
  Future<List<CatalogEntry>> listAll(LibraryItemId itemId) => _library._trace(
    operation: 'catalogListAll',
    action: () => _listAll(itemId),
    resultCount: (result) => result.length,
    resultState: (result) => result.isEmpty ? 'empty' : 'content',
  );

  /// Initializes a persisted novel catalog once, preserving downloaded chapter
  /// content on all later reader launches.
  Future<List<CatalogEntry>> ensureNovelCatalog({
    required LibraryItemId itemId,
    required Iterable<SourceNovelCatalogChapter> chapters,
  }) {
    final copied = List<SourceNovelCatalogChapter>.of(chapters);
    return _library._trace(
      operation: 'catalogEnsureNovel',
      contentKind: ContentKind.novel.code,
      itemCount: copied.length,
      action: () => _ensureNovelCatalog(itemId, copied),
      resultCount: (result) => result.length,
      resultState: (result) => result.isEmpty ? 'empty' : 'content',
    );
  }

  /// Replaces the active novel catalog while preserving cached chapter bodies.
  ///
  /// Source chapter IDs are stored explicitly, rather than reconstructed from
  /// the internal binding key, so IDs containing `:` remain lossless.
  Future<List<CatalogEntry>> syncNovelCatalog({
    required LibraryItemId itemId,
    required Iterable<SourceNovelCatalogChapter> chapters,
  }) {
    final copied = List<SourceNovelCatalogChapter>.of(chapters);
    return _library._trace(
      operation: 'catalogSyncNovel',
      contentKind: ContentKind.novel.code,
      itemCount: copied.length,
      action: () => _syncNovelCatalog(itemId, copied),
      resultCount: (result) => result.length,
      resultState: (result) => result.isEmpty ? 'empty' : 'content',
    );
  }

  Future<void> _replaceSnapshot({
    required LibraryItemId itemId,
    required SourceBindingId bindingId,
    required Iterable<IngestCatalogEntry> entries,
    Map<String, CatalogEntry> previousByRemoteIdentity =
        const <String, CatalogEntry>{},
  }) async {
    final snapshot = _id();
    var ordinal = 0;
    final batch = <RecordDraft>[];
    for (final input in entries) {
      final previous = previousByRemoteIdentity[input.remoteIdentity];
      batch.add(
        RecordDraft(
          id: input.id ?? _id(),
          recordKind: _entryKind,
          scope: _scope,
          parentId: itemId.value,
          identityKey: '${bindingId.value}:${input.remoteIdentity}',
          orderKey: input.orderKey,
          stateKey: 'pending:$snapshot',
          document: {
            'bindingId': bindingId.value,
            'snapshotId': snapshot,
            'remoteIdentity': input.remoteIdentity,
            'title': input.title,
            'kind': input.kindCode,
            if (input.index != null) 'index': input.index,
            if (input.wordCount != null) 'wordCount': input.wordCount,
            'plugin': _plugin(input.source),
            'contentStatus': 'missing',
            if (previous != null && previous.contentStatus == 'ready')
              'contentStatus': 'ready',
          },
        ),
      );
      if (previous != null && previous.contentReference != null) {
        final record = batch.last.document;
        // The object reference is deliberately retained across catalog
        // snapshots; the app-owned content object remains immutable.
        record['contentReference'] = previous.contentReference;
        if (previous.kind != null) {
          record['contentKind'] = previous.kind!.code;
        }
      }
      ordinal++;
      // PersistenceRecordStore rejects batches larger than 128 records.
      // Keep catalog snapshot writes below that contract so a source can
      // return a whole 166-chapter page without failing reader launch.
      if (batch.length == PersistenceRecordStore.maxWriteBatchSize) {
        await _library._persistence.metadataRecords.createBatch(batch);
        batch.clear();
      }
    }
    if (batch.isNotEmpty) {
      await _library._persistence.metadataRecords.createBatch(batch);
    }
    if (ordinal == 0) {
      throw ArgumentError('A catalog snapshot cannot be empty.');
    }
    // Atomic visibility is a single CAS update of the item projection.
    final item = await _library._persistence.metadataRecords.read(
      id: itemId.value,
      scope: _scope,
    );
    if (item == null) throw StateError('Missing item.');
    await _library._persistence.metadataRecords.update(
      previous: item,
      document: {...item.document, 'activeSnapshotId': snapshot},
    );
  }

  Future<Page<CatalogEntry>> _list(
    LibraryItemId itemId,
    CatalogQuery query,
  ) async {
    final item = await _library._persistence.metadataRecords.read(
      id: itemId.value,
      scope: _scope,
    );
    final snapshot = item?.document['activeSnapshotId'];
    if (snapshot is! String) return const Page(items: []);
    final page = await _library._persistence.metadataRecords.list(
      RecordQuery(
        recordKind: _entryKind,
        scope: _scope,
        parentId: itemId.value,
        stateKey: 'pending:$snapshot',
        after: _cursor(query.after),
        limit: query.limit,
      ),
    );
    return Page(
      items: page.records.map(_entry).toList(growable: false),
      nextCursor: _cursorText(page.nextCursor),
    );
  }

  Future<List<CatalogEntry>> _listAll(LibraryItemId itemId) async {
    final entries = <CatalogEntry>[];
    String? cursor;
    do {
      final page = await _list(itemId, CatalogQuery(after: cursor, limit: 500));
      entries.addAll(page.items);
      cursor = page.nextCursor;
    } while (cursor != null);
    return List<CatalogEntry>.unmodifiable(entries);
  }

  Future<List<CatalogEntry>> _ensureNovelCatalog(
    LibraryItemId itemId,
    List<SourceNovelCatalogChapter> chapters,
  ) async {
    final existing = await _listAll(itemId);
    if (existing.isNotEmpty) return existing;
    if (chapters.isEmpty) {
      throw ArgumentError.value(
        chapters,
        'chapters',
        'Cannot persist an empty catalog.',
      );
    }
    final seen = <String>{};
    for (final chapter in chapters) {
      if (!seen.add(chapter.remoteIdentity)) {
        throw ArgumentError.value(chapter.remoteIdentity, 'chapters');
      }
    }
    final item = await _library._persistence.metadataRecords.read(
      id: itemId.value,
      scope: _scope,
    );
    final source = item == null ? null : _itemSource(item.document['plugin']);
    if (source == null) {
      throw StateError('The shelf item has no source identity.');
    }
    final bindings = await _library._persistence.metadataRecords.list(
      RecordQuery(
        recordKind: _bindingKind,
        scope: _scope,
        parentId: itemId.value,
        limit: 1,
      ),
    );
    if (bindings.records.isEmpty) {
      throw StateError('The shelf item has no source binding.');
    }
    final ingest = ContentLibraryIngest(
      pluginId: source.pluginId,
      producerPluginVersion: source.pluginVersion,
      dataVersion: 1,
      opaqueData: <String, Object?>{'remoteBookId': source.remoteContentId},
    );
    await _replaceSnapshot(
      itemId: itemId,
      bindingId: SourceBindingId(bindings.records.single.id),
      entries: chapters.map(
        (chapter) => IngestCatalogEntry(
          remoteIdentity: chapter.remoteIdentity,
          title: chapter.title,
          orderKey: chapter.index.toString().padLeft(12, '0'),
          kindCode: ContentKind.novel.code,
          source: ingest,
          index: chapter.index,
          wordCount: chapter.wordCount,
        ),
      ),
    );
    return _listAll(itemId);
  }

  Future<List<CatalogEntry>> _syncNovelCatalog(
    LibraryItemId itemId,
    List<SourceNovelCatalogChapter> chapters,
  ) async {
    if (chapters.isEmpty) {
      throw ArgumentError.value(
        chapters,
        'chapters',
        'Cannot persist an empty catalog.',
      );
    }
    final seen = <String>{};
    for (final chapter in chapters) {
      if (!seen.add(chapter.remoteIdentity)) {
        throw ArgumentError.value(chapter.remoteIdentity, 'chapters');
      }
    }
    final item = await _library._persistence.metadataRecords.read(
      id: itemId.value,
      scope: _scope,
    );
    final source = item == null ? null : _itemSource(item.document['plugin']);
    if (source == null) {
      throw StateError('The shelf item has no source identity.');
    }
    final bindings = await _library._persistence.metadataRecords.list(
      RecordQuery(
        recordKind: _bindingKind,
        scope: _scope,
        parentId: itemId.value,
        limit: 1,
      ),
    );
    if (bindings.records.isEmpty) {
      throw StateError('The shelf item has no source binding.');
    }
    final previous = {
      for (final entry in await _listAll(itemId)) entry.remoteIdentity: entry,
    };
    final ingest = ContentLibraryIngest(
      pluginId: source.pluginId,
      producerPluginVersion: source.pluginVersion,
      dataVersion: 1,
      opaqueData: <String, Object?>{'remoteBookId': source.remoteContentId},
    );
    await _replaceSnapshot(
      itemId: itemId,
      bindingId: SourceBindingId(bindings.records.single.id),
      previousByRemoteIdentity: previous,
      entries: chapters.map(
        (chapter) => IngestCatalogEntry(
          remoteIdentity: chapter.remoteIdentity,
          title: chapter.title,
          orderKey: chapter.index.toString().padLeft(12, '0'),
          kindCode: ContentKind.novel.code,
          source: ingest,
          index: chapter.index,
          wordCount: chapter.wordCount,
        ),
      ),
    );
    return _listAll(itemId);
  }
}

final class ContentRepository {
  ContentRepository._(this._library);
  final ContentLibrary _library;
  Future<void> putNovel({
    required CatalogEntryId entryId,
    required String text,
    required ContentLibraryIngest source,
  }) => _library._trace(
    operation: 'contentPutNovel',
    contentKind: 'novel',
    itemCount: 1,
    action: () => _putNovel(entryId: entryId, text: text, source: source),
  );

  Future<void> putManga({
    required CatalogEntryId entryId,
    required List<IngestMangaPage> pages,
    required ContentLibraryIngest source,
  }) => _library._trace(
    operation: 'contentPutManga',
    contentKind: 'manga',
    itemCount: pages.length,
    action: () => _putManga(entryId: entryId, pages: pages, source: source),
  );

  Future<ReadableContent?> open(CatalogEntryId id) => _library._trace(
    operation: 'contentOpen',
    itemCount: 1,
    action: () => _open(id),
    resultCount: (result) => result == null ? 0 : 1,
    resultState: (result) => result == null ? 'notFound' : 'content',
  );

  /// Commits one validated novel chapter under its persisted source identity.
  Future<void> cacheNovelChapter({
    required LibraryItemId itemId,
    required String remoteChapterId,
    required String text,
  }) => _library._trace(
    operation: 'contentCacheNovelChapter',
    contentKind: ContentKind.novel.code,
    itemCount: 1,
    bytes: text.length,
    action: () => _cacheNovelChapter(
      itemId: itemId,
      remoteChapterId: remoteChapterId,
      text: text,
    ),
  );

  Future<void> _putNovel({
    required CatalogEntryId entryId,
    required String text,
    required ContentLibraryIngest source,
  }) async {
    final objectId = _id();
    await _library._persistence.contentObjects.put(
      objectId: objectId,
      contentKind: 'novel',
      objectType: 'text',
      generation: 1,
      payload: text,
    );
    await _attach(entryId, objectId, 'novel', source);
  }

  Future<void> _cacheNovelChapter({
    required LibraryItemId itemId,
    required String remoteChapterId,
    required String text,
  }) async {
    final entries = await _library.catalog._listAll(itemId);
    final entry = entries.where(
      (value) => value.remoteIdentity == remoteChapterId,
    );
    if (entry.length != 1) {
      throw StateError('The cached catalog does not contain the chapter.');
    }
    final item = await _library.getLibraryItem(itemId);
    final source = item?.source;
    if (source == null) {
      throw StateError('The shelf item has no source identity.');
    }
    await _putNovel(
      entryId: entry.single.id,
      text: text,
      source: ContentLibraryIngest(
        pluginId: source.pluginId,
        producerPluginVersion: source.pluginVersion,
        dataVersion: 1,
        opaqueData: <String, Object?>{'remoteBookId': source.remoteContentId},
      ),
    );
  }

  Future<void> _putManga({
    required CatalogEntryId entryId,
    required List<IngestMangaPage> pages,
    required ContentLibraryIngest source,
  }) async {
    final objectId = _id();
    final serialized = jsonEncode({
      'plugin': _plugin(source),
      'pages': pages.map((p) => p.toJson()).toList(growable: false),
    });
    await _library._persistence.contentObjects.put(
      objectId: objectId,
      contentKind: 'manga',
      objectType: 'manifest',
      generation: 1,
      payload: serialized,
    );
    await _attach(entryId, objectId, 'manga', source);
  }

  Future<void> _attach(
    CatalogEntryId id,
    String objectId,
    String kind,
    ContentLibraryIngest source,
  ) async {
    final record = await _library._persistence.metadataRecords.read(
      id: id.value,
      scope: _scope,
    );
    if (record == null) throw StateError('Missing catalog entry.');
    await _library._persistence.metadataRecords.update(
      previous: record,
      document: {
        ...record.document,
        'contentReference': objectId,
        'contentKind': kind,
        'contentStatus': 'ready',
        'contentPlugin': _plugin(source),
      },
    );
  }

  Future<ReadableContent?> _open(CatalogEntryId id) async {
    final record = await _library._persistence.metadataRecords.read(
      id: id.value,
      scope: _scope,
    );
    final objectId = record?.document['contentReference'];
    final kind = record?.document['contentKind'];
    if (objectId is! String || kind is! String) return null;
    final object = await _library._persistence.contentObjects.read(objectId);
    if (object == null) return const UnsupportedContent(kindCode: 'missing');
    if (kind == 'novel') return NovelChapterContent(text: object.payload);
    if (kind != 'manga') return UnsupportedContent(kindCode: kind);
    final decoded = jsonDecode(object.payload) as Map<String, dynamic>;
    final pages = (decoded['pages'] as List)
        .map((raw) {
          final p = raw as Map<String, dynamic>;
          final policy = PersistencePolicy.values.byName(p['policy'] as String);
          return MangaPage(
            pageId: p['pageId'] as String,
            order: p['order'] as int,
            resource: policy == PersistencePolicy.sessionOnly
                ? SourceResource.sessionOnly()
                : (policy == PersistencePolicy.refreshable
                      ? SourceResource.refreshable(
                          Uri.parse(p['url'] as String),
                          DateTime.parse(p['expiresAtUtc'] as String),
                        )
                      : SourceResource.durable(Uri.parse(p['url'] as String))),
            downloadedAssetId: p['assetId'] is String
                ? ContentAssetId(p['assetId'] as String)
                : null,
          );
        })
        .toList(growable: false);
    return MangaChapterContent(pages: pages);
  }
}

final class IngestCatalogEntry {
  const IngestCatalogEntry({
    this.id,
    required this.remoteIdentity,
    required this.title,
    required this.orderKey,
    required this.kindCode,
    required this.source,
    this.index,
    this.wordCount,
  });
  final String? id;
  final String remoteIdentity, title, orderKey, kindCode;
  final ContentLibraryIngest source;
  final int? index, wordCount;
}

final class IngestMangaPage {
  const IngestMangaPage({
    required this.pageId,
    required this.order,
    required this.resource,
    required this.source,
    this.downloadedAssetId,
  });
  final String pageId;
  final int order;
  final SourceResource resource;
  final ContentLibraryIngest source;
  final ContentAssetId? downloadedAssetId;
  Map<String, Object?> toJson() => {
    'pageId': pageId,
    'order': order,
    'policy': resource.persistencePolicy.name,
    if (resource.url != null) 'url': resource.url.toString(),
    if (resource.expiresAtUtc != null)
      'expiresAtUtc': resource.expiresAtUtc!.toUtc().toIso8601String(),
    if (downloadedAssetId != null) 'assetId': downloadedAssetId!.value,
    'plugin': _plugin(source),
  };
}

DiagnosticObjectValue _libraryAttributes({
  required String operation,
  String? contentKind,
  int? itemCount,
  int? bytes,
  String? resultState,
  String? errorCode,
}) => DiagnosticObjectValue(<String, DiagnosticValue>{
  'operation': DiagnosticValue.string(operation),
  if (contentKind != null) 'contentKind': DiagnosticValue.string(contentKind),
  if (itemCount != null) 'itemCount': DiagnosticValue.int64(itemCount),
  if (bytes != null) 'bytes': DiagnosticValue.int64(bytes),
  if (resultState != null) 'resultState': DiagnosticValue.string(resultState),
  if (errorCode != null) 'errorCode': DiagnosticValue.string(errorCode),
  'thresholdMicros': DiagnosticValue.int64(
    AppDiagnosticThresholds.libraryOperation.inMicroseconds,
  ),
});

Iterable<RecordDocumentCodec> get contentLibraryRecordDocumentCodecs sync* {
  for (final kind in [
    _itemKind,
    _bindingKind,
    _entryKind,
    _readingProgressKind,
  ]) {
    yield RecordDocumentCodec(
      recordKind: kind,
      scopeKind: _scope.kind,
      currentVersion: 1,
      validators: {1: _validate},
    );
  }
}

RecordDocumentRegistry get _registry =>
    RecordDocumentRegistry(contentLibraryRecordDocumentCodecs);
void _validate(JsonObject value) {
  if (jsonEncode(value).length > 256 * 1024) {
    throw const PersistenceValidationError(
      'Content library dynamic document exceeds 256 KiB.',
    );
  }
}

Map<String, Object?> _plugin(ContentLibraryIngest v) => {
  'pluginId': v.pluginId,
  'producerPluginVersion': v.producerPluginVersion,
  'dataVersion': v.dataVersion,
  'data': v.opaqueData,
};
LibraryItem _item(RecordEnvelope r) => LibraryItem(
  id: LibraryItemId(r.id),
  title: r.document['title'] as String,
  author: r.document['author'] as String?,
  kind: ContentKind.fromCode(r.document['kind'] as String) ?? ContentKind.novel,
  state: r.stateKey ?? 'unknown',
  revision: r.revision,
  coverUrl: _uriFromSummary(r.document, 'coverUrl'),
  sourceName: _stringFromSummary(r.document, 'sourceName'),
  source: _itemSource(r.document['plugin']),
  visibility: _visibilityFromDocument(r.document),
);

LibraryVisibility _visibilityFromDocument(Map<String, Object?> document) =>
    LibraryVisibility.fromWireValue(document['visibility'] as String?);

Map<String, Object?> _shelfSummary(ContentLibraryIngest source) {
  final summary = <String, Object?>{};
  final coverUrl = source.opaqueData['coverUrl'];
  final sourceName = source.opaqueData['sourceName'];
  if (coverUrl is String && coverUrl.isNotEmpty) {
    summary['coverUrl'] = coverUrl;
  }
  if (sourceName is String && sourceName.isNotEmpty) {
    summary['sourceName'] = sourceName;
  }
  return summary;
}

Map<String, Object?> _summaryFromDocument(Map<String, Object?> document) {
  final raw = document['summary'];
  return raw is Map<String, Object?>
      ? Map<String, Object?>.from(raw)
      : <String, Object?>{};
}

String? _stringFromSummary(Map<String, Object?> document, String key) {
  final value = _summaryFromDocument(document)[key];
  return value is String && value.isNotEmpty ? value : null;
}

Uri? _uriFromSummary(Map<String, Object?> document, String key) {
  final value = _stringFromSummary(document, key);
  return value == null ? null : Uri.tryParse(value);
}

LibraryItemSource? _itemSource(Object? rawPlugin) {
  if (rawPlugin is! Map<String, Object?>) return null;
  final Object? rawData = rawPlugin['data'];
  if (rawData is! Map<String, Object?>) return null;
  final pluginId = rawPlugin['pluginId'];
  final pluginVersion = rawPlugin['producerPluginVersion'];
  final remoteContentId = rawData['remoteBookId'];
  if (pluginId is! String ||
      pluginVersion is! String ||
      remoteContentId is! String ||
      pluginId.isEmpty ||
      pluginVersion.isEmpty ||
      remoteContentId.isEmpty) {
    return null;
  }
  return LibraryItemSource(
    pluginId: pluginId,
    pluginVersion: pluginVersion,
    remoteContentId: remoteContentId,
  );
}

Map<String, Object?> _readingProgressDocument(
  LibraryReadingProgress progress,
) => <String, Object?>{
  'chapterId': progress.chapterId,
  'paragraphId': progress.paragraphId,
  'characterOffset': progress.characterOffset,
  'chapterIndex': progress.chapterIndex,
  'chapterFraction': progress.chapterFraction,
  'bookFraction': progress.bookFraction,
  'updatedAtUtc': progress.updatedAtUtc.toUtc().toIso8601String(),
  'totalReadingSeconds': progress.totalReadingSeconds,
};

LibraryReadingProgress _readingProgress(RecordEnvelope record) {
  final document = record.document;
  final updatedAt = DateTime.tryParse(
    document['updatedAtUtc'] as String? ?? '',
  );
  if (updatedAt == null ||
      document['chapterId'] is! String ||
      document['paragraphId'] is! String ||
      document['characterOffset'] is! int ||
      document['chapterIndex'] is! int ||
      document['chapterFraction'] is! num ||
      document['bookFraction'] is! num) {
    throw const PersistenceCorruptionError();
  }
  return LibraryReadingProgress(
    itemId: LibraryItemId(record.parentId ?? record.identityKey ?? ''),
    chapterId: document['chapterId']! as String,
    paragraphId: document['paragraphId']! as String,
    characterOffset: document['characterOffset']! as int,
    chapterIndex: document['chapterIndex']! as int,
    chapterFraction: (document['chapterFraction']! as num).toDouble(),
    bookFraction: (document['bookFraction']! as num).toDouble(),
    updatedAtUtc: updatedAt.toUtc(),
    totalReadingSeconds: document['totalReadingSeconds'] as int? ?? 0,
  );
}

String _timestampOrderKey(DateTime value) =>
    value.toUtc().microsecondsSinceEpoch.toString().padLeft(20, '0');
CatalogEntry _entry(RecordEnvelope r) => CatalogEntry(
  id: CatalogEntryId(r.id),
  itemId: LibraryItemId(r.parentId!),
  bindingId: SourceBindingId(r.document['bindingId'] as String),
  remoteIdentity: r.document['remoteIdentity'] is String
      ? r.document['remoteIdentity']! as String
      : _remoteIdentity(r.identityKey),
  title: r.document['title'] as String,
  orderKey: r.orderKey ?? '',
  index: r.document['index'] as int? ?? 0,
  kind: ContentKind.fromCode(r.document['kind'] as String),
  contentStatus: r.document['contentStatus'] as String? ?? 'missing',
  wordCount: r.document['wordCount'] as int?,
  hasExplicitRemoteIdentity: r.document['remoteIdentity'] is String,
  contentReference: r.document['contentReference'] as String?,
);

String _remoteIdentity(String? identityKey) {
  if (identityKey == null) return '';
  final separator = identityKey.indexOf(':');
  return separator < 0 ? identityKey : identityKey.substring(separator + 1);
}

RecordCursor? _cursor(String? input) {
  if (input == null) return null;
  final parts = input.split('|');
  return parts.length == 2
      ? RecordCursor(orderKey: parts[0], id: parts[1])
      : null;
}

String? _cursorText(RecordCursor? c) =>
    c == null ? null : '${c.orderKey}|${c.id}';
String _id() {
  final random = Random.secure();
  return List.generate(
    24,
    (_) => 'abcdefghijklmnopqrstuvwxyz0123456789'[random.nextInt(36)],
  ).join();
}

void _safeText(String text) {
  if (text.isEmpty || text.length > 32768) {
    throw ArgumentError.value(text, 'text');
  }
}

void _validateCover(List<int> bytes, String mimeType) {
  if (bytes.isEmpty || bytes.length > 5 * 1024 * 1024) {
    throw ArgumentError.value(bytes.length, 'bytes');
  }
  if (mimeType.isEmpty || mimeType.length > 128) {
    throw ArgumentError.value(mimeType, 'mimeType');
  }
}

String _storageKey(CoverKey key) {
  final digest = DiagnosticSha256()..add(utf8.encode(key.canonicalValue));
  return digest.closeHex();
}
