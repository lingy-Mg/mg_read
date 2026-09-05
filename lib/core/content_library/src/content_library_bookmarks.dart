/// Content Library owned semantic bookmarks.
///
/// 职责：
/// - 以稳定书籍父 ID 和书签 ID 持久化语义章节/段落锚点。
/// - 将 metadata record 转换为不泄漏持久化实现的强类型模型。
///
/// 注意：
/// - 调用方不得依赖页码或像素偏移；重复保存同一书签 ID 必须幂等。
part of 'content_library.dart';

LibraryBookmark _storedBookmark(StoredBookmark row, LibraryItemId itemId) {
  final values = row.values;
  return LibraryBookmark(
    id: values['bookmark_id']! as String,
    itemId: itemId,
    chapterId: values['chapter_id']! as String,
    paragraphId: values['paragraph_id']! as String,
    characterOffset: values['character_offset']! as int,
    chapterTitle: values['chapter_title'] as String? ?? '',
    excerpt: values['excerpt'] as String? ?? '',
    createdAtUtc: DateTime.fromMillisecondsSinceEpoch(values['created_at_utc']! as int, isUtc: true),
  );
}

LibraryMangaReadingProgress _storedMangaProgress(StoredProgress row, LibraryItemId itemId) {
  final values = row.values;
  return LibraryMangaReadingProgress(
    itemId: itemId,
    chapterId: values['chapter_id']! as String,
    imageId: values['image_id']! as String,
    imageFraction: (values['image_fraction']! as num).toDouble(),
    chapterIndex: values['chapter_position']! as int,
    bookFraction: (values['book_fraction']! as num).toDouble(),
    updatedAtUtc: DateTime.fromMillisecondsSinceEpoch(values['updated_at_utc']! as int, isUtc: true),
    readingSeconds: values['total_reading_seconds']! as int,
  );
}

LibraryMangaBookmark _storedMangaBookmark(StoredBookmark row, LibraryItemId itemId) {
  final values = row.values;
  return LibraryMangaBookmark(
    id: values['bookmark_id']! as String,
    itemId: itemId,
    chapterId: values['chapter_id']! as String,
    imageId: values['image_id']! as String,
    imageFraction: (values['image_fraction']! as num).toDouble(),
    createdAtUtc: DateTime.fromMillisecondsSinceEpoch(values['created_at_utc']! as int, isUtc: true),
  );
}

Map<String, Object?> _bookmarkValues(LibraryBookmarkEntry bookmark) => switch (bookmark) {
  LibraryBookmark value => <String, Object?>{
    'bookmark_id': value.id,
    'bookmark_kind': 'novel',
    'chapter_id': value.chapterId,
    'paragraph_id': value.paragraphId,
    'character_offset': value.characterOffset,
    'chapter_title': value.chapterTitle,
    'excerpt': value.excerpt,
    'created_at_utc': value.createdAtUtc.toUtc().millisecondsSinceEpoch,
  },
  LibraryMangaBookmark value => <String, Object?>{
    'bookmark_id': value.id,
    'bookmark_kind': 'manga',
    'chapter_id': value.chapterId,
    'image_id': value.imageId,
    'image_fraction': value.imageFraction,
    'created_at_utc': value.createdAtUtc.toUtc().millisecondsSinceEpoch,
  },
};
