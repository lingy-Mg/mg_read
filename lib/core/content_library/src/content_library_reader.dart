/// Content Library 的封面、统一进度与阅读会话。
///
/// 职责：
/// - 经主应用持久化层读写可再生封面和语义阅读进度。
/// - 为阅读器提供绑定到打开时目录上界的强类型会话。
/// - 投影漫画正文图片缓存总量和按书架漫画归属的用量。
///
/// 注意：
/// - 全局封面写入在持久化边界内按 LRU 上限维护，调用方不访问路径或自行清理。
/// - 漫画正文图片不设全局容量上限；每本漫画以 100 MiB 为 LRU 软目标并允许批量淘汰前临时超出。
/// - 会话不得越过打开时的目录上界；异步访问保持在 ContentLibrary 所有权内。
///
part of 'content_library.dart';

final class _CoverOperations {
  _CoverOperations(this._library);

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

final class _MangaImageCacheOperations {
  _MangaImageCacheOperations(this._library);
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

/// A novel-reading view pinned to the catalog count captured at open time.
final class NovelReaderSession {
  NovelReaderSession._({
    required this._library,
    required this.item,
    required this.progress,
    required this.initialChapter,
    required this.catalogCount,
  });

  final ContentLibrary _library;
  final LibraryItem item;
  final LibraryReadingProgress? progress;
  final CatalogEntry initialChapter;
  final int catalogCount;
  final Map<String, CatalogEntry> _entryCache = <String, CatalogEntry>{};

  Future<CatalogEntry?> itemAtIndex(int index) async {
    if (index < 0 || index >= catalogCount) return Future.value(null);
    final entry = await _library._catalog._findBounded(itemId: item.id, upperBound: catalogCount, position: index);
    if (entry != null) _entryCache[entry.remoteIdentity] = entry;
    return entry;
  }

  Future<CatalogEntry?> itemByRemoteIdentity(String remoteIdentity) async {
    if (remoteIdentity.isEmpty) return Future.value(null);
    final cached = _entryCache[remoteIdentity];
    if (cached != null) return cached;
    final entry = await _library._catalog._findBounded(itemId: item.id, upperBound: catalogCount, remoteIdentity: remoteIdentity);
    if (entry != null) _entryCache[entry.remoteIdentity] = entry;
    return entry;
  }

  /// Resolves a bounded group of chapter identities with one catalog-bounded
  /// metadata query. Missing identities are omitted from the result.
  Future<Map<String, CatalogEntry>> itemsByRemoteIdentities(Iterable<String> remoteIdentities) async {
    final identities = remoteIdentities.toSet();
    if (identities.isEmpty) return Future.value(const <String, CatalogEntry>{});
    final missing = identities.where((identity) => !_entryCache.containsKey(identity)).toList(growable: false);
    if (missing.isNotEmpty) {
      _entryCache.addAll(await _library._catalog._findManyBounded(itemId: item.id, upperBound: catalogCount, remoteIdentities: missing));
    }
    return <String, CatalogEntry>{
      for (final identity in identities)
        if (_entryCache[identity] case final CatalogEntry entry) identity: entry,
    };
  }

  Future<Page<CatalogEntry>> page({String? after, int limit = 100}) async {
    final page = await _library._catalog._pageBounded(itemId: item.id, upperBound: catalogCount, after: after, limit: limit);
    for (final entry in page.items) {
      _entryCache[entry.remoteIdentity] = entry;
    }
    return page;
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
      _library._content._openReference(contentReference: entry.contentReference, kind: entry.kind);

  /// Commits a novel body to this session's target entry only.
  Future<void> cacheChapter({required CatalogEntry entry, required String text}) async {
    await _library._content._cacheNovelChapterForEntry(item: item, entry: entry, text: text);
    _entryCache.remove(entry.remoteIdentity);
  }

  /// Replaces one body using the entry version captured before the remote read.
  Future<void> refreshChapter({required CatalogEntry entry, required String text}) async {
    await _library._content._refreshNovelChapterForEntry(item: item, entry: entry, text: text);
    _entryCache.remove(entry.remoteIdentity);
  }

  Future<void> saveProgress(LibraryReadingProgress value) {
    if (value.itemId.value != item.id.value) {
      return Future<void>.error(ArgumentError.value(value.itemId, 'progress.itemId'));
    }
    return _library.saveProgress(value);
  }
}

/// Manga reader session pinned to the catalog count captured at open time.
final class MangaReaderSession {
  MangaReaderSession._({required this._library, required this.item, required this.initialChapter, required this.catalogCount});

  final ContentLibrary _library;
  final LibraryItem item;
  final CatalogEntry initialChapter;
  final int catalogCount;

  Future<CatalogEntry?> itemAtIndex(int index) => index < 0 || index >= catalogCount
      ? Future.value(null)
      : _library._catalog._findBounded(itemId: item.id, upperBound: catalogCount, position: index);

  Future<CatalogEntry?> itemByRemoteIdentity(String remoteIdentity) {
    if (remoteIdentity.isEmpty) return Future.value(null);
    return _library._catalog._findBounded(itemId: item.id, upperBound: catalogCount, remoteIdentity: remoteIdentity);
  }

  Future<Page<CatalogEntry>> page({String? after, int limit = 100}) =>
      _library._catalog._pageBounded(itemId: item.id, upperBound: catalogCount, after: after, limit: limit);

  Future<ReadableContent?> readContent(CatalogEntry entry) =>
      _library._content._openReference(contentReference: entry.contentReference, kind: entry.kind);
}

String _catalogOrderKey(int index) => index.toString().padLeft(12, '0');

LibraryReadingProgress _storedReadingProgress(StoredProgress row, LibraryItemId itemId) {
  final values = row.values;
  return LibraryReadingProgress(
    itemId: itemId,
    chapterId: values['chapter_id']! as String,
    paragraphId: values['paragraph_id']! as String,
    characterOffset: values['character_offset']! as int,
    chapterIndex: values['chapter_position']! as int,
    chapterFraction: (values['chapter_fraction']! as num).toDouble(),
    bookFraction: (values['book_fraction']! as num).toDouble(),
    updatedAtUtc: DateTime.fromMillisecondsSinceEpoch(values['updated_at_utc']! as int, isUtc: true),
    totalReadingSeconds: values['total_reading_seconds']! as int,
  );
}

LibraryAudioPlaybackProgress _storedAudioProgress(StoredProgress row, LibraryItemId itemId) {
  final values = row.values;
  return LibraryAudioPlaybackProgress(
    itemId: itemId,
    chapterId: values['chapter_id']! as String,
    position: Duration(milliseconds: values['playback_ms']! as int),
    updatedAtUtc: DateTime.fromMillisecondsSinceEpoch(values['updated_at_utc']! as int, isUtc: true),
  );
}

LibraryVideoPlaybackProgress _storedVideoProgress(StoredProgress row, LibraryItemId itemId) {
  final values = row.values;
  return LibraryVideoPlaybackProgress(
    itemId: itemId,
    groupId: values['group_id']! as String,
    episodeId: values['episode_id']! as String,
    position: Duration(milliseconds: values['playback_ms']! as int),
    duration: Duration(milliseconds: values['total_duration_ms']! as int),
    updatedAtUtc: DateTime.fromMillisecondsSinceEpoch(values['updated_at_utc']! as int, isUtc: true),
  );
}

LibraryProgress _storedProgress(StoredProgress row, LibraryItemId itemId) => switch (row.values['progress_kind']) {
  'novel' => _storedReadingProgress(row, itemId),
  'manga' => _storedMangaProgress(row, itemId),
  'audio' => _storedAudioProgress(row, itemId),
  'video' => _storedVideoProgress(row, itemId),
  _ => throw const PersistenceCorruptionError(),
};

Map<String, Object?> _progressValues(LibraryProgress progress) => switch (progress) {
  LibraryReadingProgress value => <String, Object?>{
    'progress_kind': 'novel',
    'chapter_id': value.chapterId,
    'chapter_position': value.chapterIndex,
    'paragraph_id': value.paragraphId,
    'character_offset': value.characterOffset,
    'chapter_fraction': value.chapterFraction,
    'book_fraction': value.bookFraction,
    'total_reading_seconds': value.totalReadingSeconds,
    'updated_at_utc': value.updatedAtUtc.toUtc().millisecondsSinceEpoch,
  },
  LibraryMangaReadingProgress value => <String, Object?>{
    'progress_kind': 'manga',
    'chapter_id': value.chapterId,
    'chapter_position': value.chapterIndex,
    'image_id': value.imageId,
    'image_fraction': value.imageFraction,
    'book_fraction': value.bookFraction,
    'total_reading_seconds': value.readingSeconds,
    'updated_at_utc': value.updatedAtUtc.toUtc().millisecondsSinceEpoch,
  },
  LibraryAudioPlaybackProgress value => <String, Object?>{
    'progress_kind': 'audio',
    'chapter_id': value.chapterId,
    'playback_ms': value.position.inMilliseconds,
    'updated_at_utc': value.updatedAtUtc.toUtc().millisecondsSinceEpoch,
  },
  LibraryVideoPlaybackProgress value => <String, Object?>{
    'progress_kind': 'video',
    'group_id': value.groupId,
    'episode_id': value.episodeId,
    'playback_ms': value.position.inMilliseconds,
    'total_duration_ms': value.duration.inMilliseconds,
    'updated_at_utc': value.updatedAtUtc.toUtc().millisecondsSinceEpoch,
  },
};
