/// Content Library 的封面、阅读进度与阅读会话仓储。
///
/// 职责：
/// - 经主应用持久化层读写可再生封面和语义阅读进度。
/// - 为阅读器提供绑定到不可变目录快照的强类型会话。
/// - 投影漫画正文图片缓存总量和按书架漫画归属的用量。
///
/// 注意：
/// - 全局封面写入在持久化边界内按 LRU 上限维护，调用方不访问路径或自行清理。
/// - 漫画正文图片写入不设总容量上限；总量统计和清理只由用户主动管理触发。
/// - 会话不得越过 active snapshot；异步访问保持在 ContentLibrary 所有权内。
///
part of 'content_library.dart';

final class CoverRepository {
  CoverRepository._(this._library);

  final ContentLibrary _library;

  Future<List<int>?> read(CoverKey key) => _library._trace(
    operation: 'coverRead',
    contentKind: 'image',
    itemCount: 1,
    action: () => _library._persistence.fileObjects.readGlobalCoverBytes(_storageKey(key)),
    resultCount: (result) => result == null ? 0 : 1,
    resultState: (result) => result == null ? 'miss' : 'hit',
  );

  Future<void> save({required CoverKey key, required List<int> bytes, String mimeType = 'image/unknown'}) => _library._trace(
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
        maxBytes: _coverCacheMaxBytes,
      );
    },
  );

  /// Invalidates one source cover without disturbing other shelf covers.
  Future<void> remove(CoverKey key) => _library._trace(
    operation: 'coverRemove',
    contentKind: 'image',
    itemCount: 1,
    action: () => _library._persistence.fileObjects.deleteGlobalCover(_storageKey(key)),
  );

  /// Returns the disk usage of regenerable source-cover files.
  Future<int> usageBytes() =>
      _library._trace(operation: 'coverCacheUsage', contentKind: 'image', action: _library._persistence.fileObjects.coverCacheUsageBytes);

  /// Clears regenerable source covers without touching shelf or reading data.
  Future<int> clear() => _library._trace(
    operation: 'coverCacheClear',
    contentKind: 'image',
    action: _library._persistence.fileObjects.clearCoverCache,
    resultState: (releasedBytes) => releasedBytes == 0 ? 'empty' : 'cleared',
  );
}

final class MangaImageCacheRepository {
  MangaImageCacheRepository._(this._library);
  final ContentLibrary _library;
  Future<List<int>?> read({
    required LibraryItemId itemId,
    required String chapterId,
    required String pageId,
    required int contentVersion,
  }) => _library._persistence.fileObjects.readMangaImage(
    itemId: itemId.value,
    chapterId: chapterId,
    pageId: pageId,
    contentVersion: contentVersion,
  );

  Future<void> save({
    required LibraryItemId itemId,
    required String chapterId,
    required String pageId,
    required int contentVersion,
    required List<int> bytes,
    required String mimeType,
  }) async {
    await _library._persistence.fileObjects.commitMangaImage(
      itemId: itemId.value,
      chapterId: chapterId,
      pageId: pageId,
      contentVersion: contentVersion,
      bytes: bytes,
      mimeType: mimeType,
    );
  }

  Future<int> usageBytes() => _library._persistence.fileObjects.mangaImageCacheUsageBytes();

  Future<MangaImageCacheStorageUsage> usage() async {
    final usage = await _library._persistence.fileObjects.mangaImageCacheUsage();
    final items = <MangaImageCacheItemUsage>[
      for (final entry in usage.bytesByItem.entries) MangaImageCacheItemUsage(itemId: LibraryItemId(entry.key), bytes: entry.value),
    ];
    final attributedBytes = items.fold<int>(0, (sum, item) => sum + item.bytes);
    return MangaImageCacheStorageUsage(totalBytes: usage.totalBytes, unattributedBytes: usage.totalBytes - attributedBytes, items: items);
  }

  Future<int> clear() => _library._persistence.fileObjects.clearMangaImageCache();
}

final class MangaImageCacheStorageUsage {
  MangaImageCacheStorageUsage({required this.totalBytes, required this.unattributedBytes, required List<MangaImageCacheItemUsage> items})
    : items = List<MangaImageCacheItemUsage>.unmodifiable(items);

  final int totalBytes;
  final int unattributedBytes;
  final List<MangaImageCacheItemUsage> items;
}

final class MangaImageCacheItemUsage {
  const MangaImageCacheItemUsage({required this.itemId, required this.bytes});

  final LibraryItemId itemId;
  final int bytes;
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
  Future<List<LibraryReadingProgress>> loadMany(Iterable<LibraryItemId> itemIds) {
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
  Future<void> save(LibraryReadingProgress progress) =>
      _library._trace(operation: 'readingProgressSave', itemCount: 1, action: () => _save(progress));

  Future<LibraryReadingProgress?> _load(LibraryItemId itemId) async {
    final page = await _library._persistence.metadataRecords.list(
      RecordQuery(recordKind: _readingProgressKind, scope: _scope, identityKey: itemId.value, limit: 1),
    );
    return page.records.isEmpty ? null : _readingProgress(page.records.single);
  }

  Future<List<LibraryReadingProgress>> _loadMany(Set<String> itemIdsByValue) async {
    if (itemIdsByValue.isEmpty) return const <LibraryReadingProgress>[];
    final records = await _library._persistence.metadataRecords.listByIdentityKeys(
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
      RecordQuery(recordKind: _readingProgressKind, scope: _scope, identityKey: progress.itemId.value, limit: 1),
    );
    final document = _readingProgressDocument(progress);
    if (existing.records.isNotEmpty) {
      await _library._persistence.metadataRecords.update(previous: existing.records.single, document: document);
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

/// Persists the last spoken-audio chapter and timestamp for a shelf item.
final class AudioProgressRepository {
  AudioProgressRepository._(this._library);

  final ContentLibrary _library;

  Future<LibraryAudioPlaybackProgress?> load(LibraryItemId itemId) =>
      _library._trace(
        operation: 'audioProgressLoad',
        itemCount: 1,
        action: () => _load(itemId),
        resultCount: (result) => result == null ? 0 : 1,
        resultState: (result) => result == null ? 'empty' : 'content',
      );

  Future<void> save(LibraryAudioPlaybackProgress progress) => _library._trace(
    operation: 'audioProgressSave',
    itemCount: 1,
    action: () => _save(progress),
  );

  Future<LibraryAudioPlaybackProgress?> _load(LibraryItemId itemId) async {
    final page = await _library._persistence.metadataRecords.list(
      RecordQuery(recordKind: _audioProgressKind, scope: _scope, identityKey: itemId.value, limit: 1),
    );
    return page.records.isEmpty ? null : _audioProgress(page.records.single);
  }

  Future<void> _save(LibraryAudioPlaybackProgress progress) async {
    final existing = await _library._persistence.metadataRecords.list(
      RecordQuery(recordKind: _audioProgressKind, scope: _scope, identityKey: progress.itemId.value, limit: 1),
    );
    final document = _audioProgressDocument(progress);
    if (existing.records.isNotEmpty) {
      await _library._persistence.metadataRecords.update(previous: existing.records.single, document: document);
      return;
    }
    await _library._persistence.metadataRecords.create(
      RecordDraft(
        id: _id(),
        recordKind: _audioProgressKind,
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

/// A bounded novel-reading view over an immutable catalog snapshot.
///
/// The snapshot and binding identifiers are implementation details. All
/// chapter access is consequently routed through typed projections rather
/// than persistence records or dynamic documents.
final class NovelReaderSession {
  NovelReaderSession._({
    required this._library,
    required this.item,
    required this.progress,
    required this.catalogCount,
    required this._snapshot,
    required this._bindingId,
  });

  final ContentLibrary _library;
  final LibraryItem item;
  final LibraryReadingProgress? progress;
  final int catalogCount;
  final String _snapshot;
  final SourceBindingId _bindingId;

  Future<CatalogEntry?> itemAtIndex(int index) {
    if (index < 0 || index >= catalogCount) return Future.value(null);
    return _library.catalog._findInSnapshot(itemId: item.id, snapshot: _snapshot, bindingId: _bindingId, orderKey: _catalogOrderKey(index));
  }

  Future<CatalogEntry?> itemByRemoteIdentity(String remoteIdentity) {
    if (remoteIdentity.isEmpty) return Future.value(null);
    return _library.catalog._findInSnapshot(itemId: item.id, snapshot: _snapshot, bindingId: _bindingId, remoteIdentity: remoteIdentity);
  }

  /// Resolves a bounded group of chapter identities with one snapshot-scoped
  /// metadata query. Missing identities are omitted from the result.
  Future<Map<String, CatalogEntry>> itemsByRemoteIdentities(Iterable<String> remoteIdentities) {
    final identities = remoteIdentities.toSet();
    if (identities.isEmpty) return Future.value(const <String, CatalogEntry>{});
    return _library.catalog._findManyInSnapshot(itemId: item.id, snapshot: _snapshot, bindingId: _bindingId, remoteIdentities: identities);
  }

  Future<Page<CatalogEntry>> page({String? after, int limit = 100}) {
    return _library.catalog._pageInSnapshot(itemId: item.id, snapshot: _snapshot, after: after, limit: limit);
  }

  /// Resolves saved semantic progress without loading the whole catalog.
  /// If its remote chapter was removed, the saved numeric index is used as a
  /// bounded fallback and may return null when the new catalog is shorter.
  Future<CatalogEntry?> resolveProgressEntry() async {
    final saved = progress;
    if (saved == null) return null;
    final byIdentity = await itemByRemoteIdentity(saved.chapterId);
    return byIdentity ?? itemAtIndex(saved.chapterIndex);
  }

  /// Reads content through the entry's already-known immutable object reference.
  Future<ReadableContent?> readContent(CatalogEntry entry) =>
      _library.content._openReference(contentReference: entry.contentReference, kind: entry.kind);

  /// Commits a novel body to this session's target entry only.
  Future<void> cacheChapter({required CatalogEntry entry, required String text}) =>
      _library.content._cacheNovelChapterForEntry(item: item, entry: entry, text: text);

  Future<void> saveProgress(LibraryReadingProgress value) {
    if (value.itemId.value != item.id.value) {
      return Future<void>.error(ArgumentError.value(value.itemId, 'progress.itemId'));
    }
    return _library.readingProgress.save(value);
  }
}

/// Bounded reader session pinned to one manga catalog snapshot.
final class MangaReaderSession {
  MangaReaderSession._({
    required this._library,
    required this.item,
    required this.catalogCount,
    required this._snapshot,
    required this._bindingId,
  });

  final ContentLibrary _library;
  final LibraryItem item;
  final int catalogCount;
  final String _snapshot;
  final SourceBindingId _bindingId;

  Future<CatalogEntry?> itemAtIndex(int index) => index < 0 || index >= catalogCount
      ? Future.value(null)
      : _library.catalog._findInSnapshot(itemId: item.id, snapshot: _snapshot, bindingId: _bindingId, orderKey: _catalogOrderKey(index));

  Future<CatalogEntry?> itemByRemoteIdentity(String remoteIdentity) {
    if (remoteIdentity.isEmpty) return Future.value(null);
    return _library.catalog._findInSnapshot(itemId: item.id, snapshot: _snapshot, bindingId: _bindingId, remoteIdentity: remoteIdentity);
  }

  Future<Page<CatalogEntry>> page({String? after, int limit = 100}) =>
      _library.catalog._pageInSnapshot(itemId: item.id, snapshot: _snapshot, after: after, limit: limit);

  Future<ReadableContent?> readContent(CatalogEntry entry) =>
      _library.content._openReference(contentReference: entry.contentReference, kind: entry.kind);
}

String _catalogOrderKey(int index) => index.toString().padLeft(12, '0');
