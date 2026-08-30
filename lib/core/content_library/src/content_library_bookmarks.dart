/// Content Library owned semantic text-reader bookmarks.
///
/// 职责：
/// - 以稳定书籍父 ID 和书签 ID 持久化语义章节/段落锚点。
/// - 将 metadata record 转换为不泄漏持久化实现的强类型模型。
///
/// 注意：
/// - 调用方不得依赖页码或像素偏移；重复保存同一书签 ID 必须幂等。
part of 'content_library.dart';

final class BookmarkRepository {
  BookmarkRepository._(this._library);

  final ContentLibrary _library;

  Future<List<LibraryBookmark>> load(LibraryItemId itemId) => _library._trace(
    operation: 'bookmarksLoad',
    itemCount: 1,
    action: () async {
      final page = await _library._persistence.metadataRecords.list(
        RecordQuery(recordKind: _bookmarkKind, scope: _scope, parentId: itemId.value, limit: 1000),
      );
      return List<LibraryBookmark>.unmodifiable(page.records.map(_bookmark));
    },
  );

  Future<void> save(LibraryBookmark bookmark) => _library._trace(
    operation: 'bookmarkSave',
    itemCount: 1,
    action: () async {
      final existing = await _library._persistence.metadataRecords.list(
        RecordQuery(recordKind: _bookmarkKind, scope: _scope, parentId: bookmark.itemId.value, identityKey: bookmark.id, limit: 1),
      );
      final document = _bookmarkDocument(bookmark);
      if (existing.records.isNotEmpty) {
        await _library._persistence.metadataRecords.update(previous: existing.records.single, document: document);
        return;
      }
      await _library._persistence.metadataRecords.create(
        RecordDraft(
          id: _id(),
          recordKind: _bookmarkKind,
          scope: _scope,
          parentId: bookmark.itemId.value,
          identityKey: bookmark.id,
          orderKey: _timestampOrderKey(bookmark.createdAtUtc),
          stateKey: 'active',
          document: document,
        ),
      );
    },
  );

  Future<void> remove(LibraryItemId itemId, String bookmarkId) => _library._trace(
    operation: 'bookmarkRemove',
    itemCount: 1,
    action: () async {
      final page = await _library._persistence.metadataRecords.list(
        RecordQuery(recordKind: _bookmarkKind, scope: _scope, parentId: itemId.value, identityKey: bookmarkId, limit: 1),
      );
      if (page.records.isNotEmpty) {
        await _library._persistence.metadataRecords.delete(previous: page.records.single);
      }
    },
  );
}

Map<String, Object?> _bookmarkDocument(LibraryBookmark bookmark) => <String, Object?>{
  'chapterId': bookmark.chapterId,
  'paragraphId': bookmark.paragraphId,
  'characterOffset': bookmark.characterOffset,
  'chapterTitle': bookmark.chapterTitle,
  'excerpt': bookmark.excerpt,
  'createdAtUtc': bookmark.createdAtUtc.toUtc().toIso8601String(),
};

LibraryBookmark _bookmark(RecordEnvelope record) {
  final document = record.document;
  final createdAt = DateTime.tryParse(document['createdAtUtc'] as String? ?? '');
  if (record.parentId == null ||
      record.identityKey == null ||
      createdAt == null ||
      document['chapterId'] is! String ||
      document['paragraphId'] is! String ||
      document['characterOffset'] is! int ||
      document['chapterTitle'] is! String ||
      document['excerpt'] is! String) {
    throw const PersistenceCorruptionError();
  }
  return LibraryBookmark(
    id: record.identityKey!,
    itemId: LibraryItemId(record.parentId!),
    chapterId: document['chapterId']! as String,
    paragraphId: document['paragraphId']! as String,
    characterOffset: document['characterOffset']! as int,
    chapterTitle: document['chapterTitle']! as String,
    excerpt: document['excerpt']! as String,
    createdAtUtc: createdAt.toUtc(),
  );
}

/// Manga-only reading state; intentionally separate from text anchors.
final class MangaStateRepository {
  MangaStateRepository._(this._library);
  final ContentLibrary _library;

  Future<LibraryMangaReadingProgress?> loadProgress(LibraryItemId itemId) async {
    final page = await _library._persistence.metadataRecords.list(
      RecordQuery(recordKind: _mangaProgressKind, scope: _scope, parentId: itemId.value, limit: 1),
    );
    return page.records.isEmpty ? null : _mangaProgress(page.records.single);
  }

  Future<List<LibraryMangaReadingProgress>> loadProgressMany(Iterable<LibraryItemId> itemIds) async {
    final itemIdsByValue = <String>{for (final itemId in itemIds) itemId.value};
    if (itemIdsByValue.isEmpty) return const <LibraryMangaReadingProgress>[];
    final records = await _library._persistence.metadataRecords.listByIdentityKeys(
      recordKind: _mangaProgressKind,
      scope: _scope,
      identityKeys: itemIdsByValue,
    );
    final progressByItemId = <String, LibraryMangaReadingProgress>{};
    for (final record in records) {
      final itemId = record.identityKey;
      if (itemId == null || progressByItemId.containsKey(itemId)) continue;
      progressByItemId[itemId] = _mangaProgress(record);
    }
    return List<LibraryMangaReadingProgress>.unmodifiable(progressByItemId.values);
  }

  Future<void> saveProgress(LibraryMangaReadingProgress value) async {
    final page = await _library._persistence.metadataRecords.list(
      RecordQuery(recordKind: _mangaProgressKind, scope: _scope, parentId: value.itemId.value, limit: 1),
    );
    final document = {
      'chapterId': value.chapterId,
      'imageId': value.imageId,
      'imageFraction': value.imageFraction,
      'chapterIndex': value.chapterIndex,
      'bookFraction': value.bookFraction,
      'updatedAtUtc': value.updatedAtUtc.toUtc().toIso8601String(),
      'readingSeconds': value.readingSeconds,
    };
    if (page.records.isEmpty) {
      await _library._persistence.metadataRecords.create(
        RecordDraft(
          id: _id(),
          recordKind: _mangaProgressKind,
          scope: _scope,
          parentId: value.itemId.value,
          identityKey: value.itemId.value,
          stateKey: 'active',
          document: document,
        ),
      );
    } else {
      await _library._persistence.metadataRecords.update(previous: page.records.single, document: document);
    }
  }

  Future<List<LibraryMangaBookmark>> listBookmarks(LibraryItemId itemId) async {
    final page = await _library._persistence.metadataRecords.list(
      RecordQuery(recordKind: _mangaBookmarkKind, scope: _scope, parentId: itemId.value, limit: 1000),
    );
    return List.unmodifiable(page.records.map(_mangaBookmark));
  }

  Future<void> addBookmark(LibraryMangaBookmark value) async {
    final existing = await _library._persistence.metadataRecords.list(
      RecordQuery(recordKind: _mangaBookmarkKind, scope: _scope, parentId: value.itemId.value, identityKey: value.id, limit: 1),
    );
    final document = {
      'chapterId': value.chapterId,
      'imageId': value.imageId,
      'imageFraction': value.imageFraction,
      'createdAtUtc': value.createdAtUtc.toUtc().toIso8601String(),
    };
    if (existing.records.isNotEmpty) {
      await _library._persistence.metadataRecords.update(previous: existing.records.single, document: document);
      return;
    }
    await _library._persistence.metadataRecords.create(
      RecordDraft(
        id: _id(),
        recordKind: _mangaBookmarkKind,
        scope: _scope,
        parentId: value.itemId.value,
        identityKey: value.id,
        stateKey: 'active',
        document: document,
      ),
    );
  }

  Future<void> removeBookmark(LibraryItemId itemId, String id) async {
    final page = await _library._persistence.metadataRecords.list(
      RecordQuery(recordKind: _mangaBookmarkKind, scope: _scope, parentId: itemId.value, identityKey: id, limit: 1),
    );
    if (page.records.isNotEmpty) await _library._persistence.metadataRecords.delete(previous: page.records.single);
  }
}

LibraryMangaReadingProgress _mangaProgress(RecordEnvelope r) => LibraryMangaReadingProgress(
  itemId: LibraryItemId(r.parentId!),
  chapterId: r.document['chapterId']! as String,
  imageId: r.document['imageId']! as String,
  imageFraction: (r.document['imageFraction']! as num).toDouble(),
  chapterIndex: r.document['chapterIndex']! as int,
  bookFraction: (r.document['bookFraction']! as num).toDouble(),
  updatedAtUtc: DateTime.parse(r.document['updatedAtUtc']! as String),
  readingSeconds: r.document['readingSeconds']! as int,
);
LibraryMangaBookmark _mangaBookmark(RecordEnvelope r) => LibraryMangaBookmark(
  id: r.identityKey!,
  itemId: LibraryItemId(r.parentId!),
  chapterId: r.document['chapterId']! as String,
  imageId: r.document['imageId']! as String,
  imageFraction: (r.document['imageFraction']! as num).toDouble(),
  createdAtUtc: DateTime.parse(r.document['createdAtUtc']! as String),
);
