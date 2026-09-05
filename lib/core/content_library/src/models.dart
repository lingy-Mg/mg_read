/// Content Library 的公开强类型模型。
///
/// 职责：
/// - 定义书架、来源、目录、正文、进度、书签和同步边界的数据结构。
/// - 保存少量可查询展示字段，并允许携带宿主校验后的 JSON 兼容详情快照。
/// - 公开书架唯一容量上限和可识别的容量业务错误。
///
/// 注意：
/// - 模型不得包含数据库路径、未校验传输对象或平台资源句柄。
/// - 可再生数据源详情只作为本地优先展示摘要，远端仍可在后台刷新。
library;

/// The single global capacity shared by shelf writes, statistics and sync.
const int bookshelfMaxItemCount = 100;

const String bookshelfCapacityExceededCode = 'bookshelf_capacity_exceeded';

/// Maximum number of lightweight operation notifications retained locally.
const int libraryNotificationMaxCount = 100;

/// Stable notification kinds. Content updates are reserved for the future
/// background-refresh producer while shelf mutations are live today.
enum LibraryNotificationKind {
  bookshelfAdded('bookshelf_added'),
  bookshelfRemoved('bookshelf_removed'),
  contentUpdated('content_updated');

  const LibraryNotificationKind(this.code);
  final String code;

  static LibraryNotificationKind? fromCode(String code) => switch (code) {
    'bookshelf_added' => bookshelfAdded,
    'bookshelf_removed' => bookshelfRemoved,
    'content_updated' => contentUpdated,
    _ => null,
  };
}

/// One bounded local notification projection.
final class LibraryNotification {
  const LibraryNotification({required this.id, required this.kind, required this.title, required this.occurredAt});

  final String id;
  final LibraryNotificationKind kind;
  final String title;
  final DateTime occurredAt;
}

/// Stable business failure raised when a write would create item 101.
final class BookshelfCapacityExceededException implements Exception {
  const BookshelfCapacityExceededException({required this.currentCount, required this.requestedNewItems});

  final int currentCount;
  final int requestedNewItems;
  String get code => bookshelfCapacityExceededCode;

  @override
  String toString() =>
      'BookshelfCapacityExceededException(code: $code, currentCount: $currentCount, requestedNewItems: $requestedNewItems)';
}

enum ContentKind {
  audio('audio'),
  novel('novel'),
  manga('manga'),
  video('video');

  const ContentKind(this.code);
  final String code;
  static ContentKind? fromCode(String code) => switch (code) {
    'novel' => novel,
    'manga' => manga,
    'audio' => audio,
    'video' => video,
    _ => null,
  };
}

final class LibraryItemId {
  const LibraryItemId(this.value);
  final String value;
  @override
  String toString() => value;
}

final class CatalogEntryId {
  const CatalogEntryId(this.value);
  final String value;
}

final class ContentObjectId {
  const ContentObjectId(this.value);
  final String value;
}

final class ContentAssetId {
  const ContentAssetId(this.value);
  final String value;
}

final class LibraryItem {
  const LibraryItem({
    required this.id,
    required this.title,
    required this.author,
    required this.kind,
    required this.state,
    required this.revision,
    this.visibility = LibraryVisibility.normal,
    this.coverUrl,
    this.sourceName,
    this.sourceUrl,
    this.description,
    this.language,
    this.accessCode,
    this.wordCount,
    this.chapterCount,
    this.publishedAt,
    this.updatedAt,
    this.statusLabel,
    this.latestChapterId,
    this.latestChapterTitle,
    this.latestChapterUrl,
    this.latestChapterUpdatedAt,
    this.categories = const <String>[],
    this.tags = const <String>[],
    this.attributes = const <LibraryItemAttribute>[],
    this.sourceDetail = const <String, Object?>{},
    this.labels = const <String>[],
    required this.source,
  });
  final LibraryItemId id;
  final String title;
  final String? author;
  final ContentKind kind;
  final String state;
  final int revision;

  /// Whether this item participates in the normal or privacy-only shelf.
  ///
  /// Visibility never changes the item's source identity, reading progress, or
  /// locally retained content.
  final LibraryVisibility visibility;
  final Uri? coverUrl;
  final String? sourceName;
  final Uri? sourceUrl;
  final String? description;
  final String? language;
  final String? accessCode;
  final int? wordCount;
  final int? chapterCount;
  final DateTime? publishedAt;
  final DateTime? updatedAt;
  final String? statusLabel;
  final String? latestChapterId;
  final String? latestChapterTitle;
  final Uri? latestChapterUrl;
  final DateTime? latestChapterUpdatedAt;
  final List<String> categories;
  final List<String> tags;
  final List<LibraryItemAttribute> attributes;

  /// JSON-compatible host snapshot used only to restore source detail fields.
  final Map<String, Object?> sourceDetail;
  final List<String> labels;

  /// Stable source identity needed to resolve a shelf item for reading.
  final LibraryItemSource source;
}

/// One structured source attribute retained for cached detail rendering.
final class LibraryItemAttribute {
  const LibraryItemAttribute({required this.key, required this.label, required this.value})
    : assert(key != ''),
      assert(label != ''),
      assert(value != '');

  final String key;
  final String label;
  final String value;
}

/// Typed source identity retained by a bookshelf item.
final class LibraryItemSource {
  const LibraryItemSource({required this.pluginId, required this.pluginVersion, required this.remoteContentId})
    : assert(pluginId != ''),
      assert(pluginVersion != ''),
      assert(remoteContentId != '');

  final String pluginId;
  final String pluginVersion;
  final String remoteContentId;
}

/// Bounded shelf-card projection returned by one metadata query.
final class LibraryShelfProjection {
  const LibraryShelfProjection({
    required this.itemId,
    required this.kind,
    required this.title,
    required this.author,
    required this.coverUrl,
    required this.sourceName,
    required this.source,
    required this.sourceChapterCount,
    required this.catalogCount,
    required this.summaryExcerpt,
    required this.progressKind,
    required this.chapterPosition,
    required this.bookFraction,
    required this.totalReadingSeconds,
    required this.progressUpdatedAtUtc,
  });

  final LibraryItemId itemId;
  final ContentKind kind;
  final String title;
  final String? author;
  final Uri? coverUrl;
  final String? sourceName;
  final LibraryItemSource source;
  final int? sourceChapterCount;
  final int catalogCount;
  final String? summaryExcerpt;
  final ContentKind? progressKind;
  final int? chapterPosition;
  final double? bookFraction;
  final int? totalReadingSeconds;
  final DateTime? progressUpdatedAtUtc;
}

/// Stable identity for a regenerable source cover shared by all features.
///
/// The URL is part of the identity so a source changing its cover naturally
/// creates a new cache entry without mutating an older entry in place.
final class CoverKey {
  const CoverKey({required this.pluginId, required this.remoteContentId, required this.coverUrl, this.pluginVersion = 'unknown'})
    : assert(pluginId != ''),
      assert(pluginVersion != ''),
      assert(remoteContentId != '');

  final String pluginId;
  final String pluginVersion;
  final String remoteContentId;
  final Uri coverUrl;

  String get canonicalValue => '$pluginId\u001f$pluginVersion\u001f$remoteContentId\u001f$coverUrl';
}

/// A durable, layout-independent text-reading position for one shelf item.
///
/// It uses the reader package's semantic anchors rather than a page number or
/// pixel offset, so it remains valid after layout and font changes.
sealed class LibraryProgress {
  const LibraryProgress();
  LibraryItemId get itemId;
  ContentKind get kind;
}

final class LibraryReadingProgress implements LibraryProgress {
  const LibraryReadingProgress({
    required this.itemId,
    required this.chapterId,
    required this.paragraphId,
    required this.characterOffset,
    required this.chapterIndex,
    required this.chapterFraction,
    required this.bookFraction,
    required this.updatedAtUtc,
    this.totalReadingSeconds = 0,
  }) : assert(characterOffset >= 0),
       assert(chapterFraction >= 0 && chapterFraction <= 1),
       assert(bookFraction >= 0 && bookFraction <= 1),
       assert(totalReadingSeconds >= 0);

  @override
  final LibraryItemId itemId;
  final String chapterId;
  final String paragraphId;
  final int characterOffset;
  final int chapterIndex;
  final double chapterFraction;
  final double bookFraction;
  final DateTime updatedAtUtc;

  /// Accumulated foreground reading time measured by the host, in seconds.
  final int totalReadingSeconds;

  @override
  ContentKind get kind => ContentKind.novel;
}

/// Durable spoken-audio position, identified by source chapter rather than a
/// transient player queue index.
final class LibraryAudioPlaybackProgress implements LibraryProgress {
  LibraryAudioPlaybackProgress({required this.itemId, required this.chapterId, required this.position, required this.updatedAtUtc})
    : assert(chapterId != ''),
      assert(!position.isNegative);

  @override
  final LibraryItemId itemId;
  final String chapterId;
  final Duration position;
  final DateTime updatedAtUtc;

  @override
  ContentKind get kind => ContentKind.audio;
}

/// Durable video selection and position owned by the Content Library.
///
/// Group and episode identities remain source-defined playback metadata.
final class LibraryVideoPlaybackProgress implements LibraryProgress {
  LibraryVideoPlaybackProgress({
    required this.itemId,
    required this.groupId,
    required this.episodeId,
    required this.position,
    required this.duration,
    required this.updatedAtUtc,
  }) : assert(groupId != ''),
       assert(episodeId != ''),
       assert(!position.isNegative),
       assert(!duration.isNegative);

  @override
  final LibraryItemId itemId;
  final String groupId;
  final String episodeId;
  final Duration position;
  final Duration duration;
  final DateTime updatedAtUtc;

  @override
  ContentKind get kind => ContentKind.video;
}

/// A durable semantic text-reader bookmark owned by the Content Library.
sealed class LibraryBookmarkEntry {
  const LibraryBookmarkEntry();
  String get id;
  LibraryItemId get itemId;
  String get chapterId;
  ContentKind get bookmarkKind;
}

final class LibraryBookmark implements LibraryBookmarkEntry {
  const LibraryBookmark({
    required this.id,
    required this.itemId,
    required this.chapterId,
    required this.paragraphId,
    required this.characterOffset,
    required this.chapterTitle,
    required this.excerpt,
    required this.createdAtUtc,
  }) : assert(characterOffset >= 0);

  @override
  final String id;
  @override
  final LibraryItemId itemId;
  @override
  final String chapterId;
  final String paragraphId;
  final int characterOffset;
  final String chapterTitle;
  final String excerpt;
  final DateTime createdAtUtc;

  @override
  ContentKind get bookmarkKind => ContentKind.novel;
}

/// Narrow, host-owned request for adding a typed source item to the shelf.
///
/// It keeps stable source identity and a small typed display projection. The
/// optional dynamic detail is host-normalized JSON.
final class BookshelfAddRequest {
  const BookshelfAddRequest({
    required this.title,
    required this.author,
    required this.kind,
    required this.pluginId,
    required this.pluginVersion,
    required this.remoteContentId,
    this.coverUrl,
    this.sourceName,
    this.sourceUrl,
    this.description,
    this.language,
    this.accessCode,
    this.wordCount,
    this.chapterCount,
    this.publishedAt,
    this.updatedAt,
    this.statusLabel,
    this.latestChapterId,
    this.latestChapterTitle,
    this.latestChapterUrl,
    this.latestChapterUpdatedAt,
    this.categories = const <String>[],
    this.tags = const <String>[],
    this.attributes = const <LibraryItemAttribute>[],
    this.sourceDetail = const <String, Object?>{},
    this.labels = const <String>[],
  }) : assert(title != ''),
       assert(pluginId != ''),
       assert(pluginVersion != ''),
       assert(remoteContentId != '');

  final String title;
  final String? author;
  final ContentKind kind;
  final String pluginId;
  final String pluginVersion;
  final String remoteContentId;
  final Uri? coverUrl;
  final String? sourceName;
  final Uri? sourceUrl;
  final String? description;
  final String? language;
  final String? accessCode;
  final int? wordCount;
  final int? chapterCount;
  final DateTime? publishedAt;
  final DateTime? updatedAt;
  final String? statusLabel;
  final String? latestChapterId;
  final String? latestChapterTitle;
  final Uri? latestChapterUrl;
  final DateTime? latestChapterUpdatedAt;
  final List<String> categories;
  final List<String> tags;
  final List<LibraryItemAttribute> attributes;
  final Map<String, Object?> sourceDetail;
  final List<String> labels;
}

/// Stable source identity used by the app-owned LAN sync contract.
final class LibrarySyncIdentity {
  const LibrarySyncIdentity({required this.pluginId, required this.remoteContentId});

  final String pluginId;
  final String remoteContentId;

  @override
  bool operator ==(Object other) => other is LibrarySyncIdentity && other.pluginId == pluginId && other.remoteContentId == remoteContentId;

  @override
  int get hashCode => Object.hash(pluginId, remoteContentId);
}

/// A progress value in a sync snapshot.  The local [LibraryItemId] is
/// deliberately omitted; the receiver remaps it from source identity.
final class LibrarySyncReadingProgress {
  const LibrarySyncReadingProgress({
    required this.chapterId,
    required this.paragraphId,
    required this.characterOffset,
    required this.chapterIndex,
    required this.chapterFraction,
    required this.bookFraction,
    required this.updatedAtUtc,
    this.totalReadingSeconds = 0,
  });

  final String chapterId;
  final String paragraphId;
  final int characterOffset;
  final int chapterIndex;
  final double chapterFraction;
  final double bookFraction;
  final DateTime updatedAtUtc;
  final int totalReadingSeconds;

  LibrarySyncReadingProgress.fromLocal(LibraryReadingProgress progress)
    : this(
        chapterId: progress.chapterId,
        paragraphId: progress.paragraphId,
        characterOffset: progress.characterOffset,
        chapterIndex: progress.chapterIndex,
        chapterFraction: progress.chapterFraction,
        bookFraction: progress.bookFraction,
        updatedAtUtc: progress.updatedAtUtc,
        totalReadingSeconds: progress.totalReadingSeconds,
      );

  LibraryReadingProgress toLocal(LibraryItemId itemId) => LibraryReadingProgress(
    itemId: itemId,
    chapterId: chapterId,
    paragraphId: paragraphId,
    characterOffset: characterOffset,
    chapterIndex: chapterIndex,
    chapterFraction: chapterFraction,
    bookFraction: bookFraction,
    updatedAtUtc: updatedAtUtc,
    totalReadingSeconds: totalReadingSeconds,
  );
}

/// Version-1, metadata-only LAN sync item.
final class LibrarySyncItem {
  const LibrarySyncItem({
    required this.pluginId,
    required this.producerPluginVersion,
    required this.remoteContentId,
    required this.kind,
    required this.title,
    this.author,
    this.coverUrl,
    this.sourceName,
    this.progress,
  });

  final String pluginId;
  final String producerPluginVersion;
  final String remoteContentId;
  final ContentKind kind;
  final String title;
  final String? author;
  final Uri? coverUrl;
  final String? sourceName;
  final LibrarySyncReadingProgress? progress;

  LibrarySyncIdentity get identity => LibrarySyncIdentity(pluginId: pluginId, remoteContentId: remoteContentId);
}

/// Version-1 sync snapshot.  It contains no catalog, content, cover bytes or
/// deletion records.  [skippedSourceLessItems] is an export-side count only.
final class LibrarySyncSnapshot {
  const LibrarySyncSnapshot({required this.items, this.version = 1, this.skippedSourceLessItems = 0});

  final int version;
  final List<LibrarySyncItem> items;
  final int skippedSourceLessItems;
}

enum LibrarySyncBlockedReason { missingPlugin, invalidEntry }

final class LibrarySyncBlockedItem {
  const LibrarySyncBlockedItem({required this.item, required this.reason});

  final LibrarySyncItem item;
  final LibrarySyncBlockedReason reason;
}

final class LibrarySyncConflict {
  const LibrarySyncConflict({
    required this.identity,
    required this.local,
    required this.sender,
    required this.expectedLocalRevision,
    this.localProgress,
  });

  final LibrarySyncIdentity identity;
  final LibraryItem local;
  final LibrarySyncItem sender;
  final int expectedLocalRevision;
  final LibrarySyncReadingProgress? localProgress;
}

final class LibrarySyncPreview {
  const LibrarySyncPreview({
    required this.snapshot,
    required this.newItems,
    required this.conflicts,
    required this.blocked,
    this.skippedSourceLessItems = 0,
  });

  final LibrarySyncSnapshot snapshot;
  final List<LibrarySyncItem> newItems;
  final List<LibrarySyncConflict> conflicts;
  final List<LibrarySyncBlockedItem> blocked;
  final int skippedSourceLessItems;
}

enum LibrarySyncConflictChoice { smartMerge, useSender, keepLocal }

enum LibrarySyncResultCode { applied, staleRevision, invalidRequest }

final class LibrarySyncApplyResult {
  const LibrarySyncApplyResult({
    required this.code,
    this.addedItems = 0,
    this.updatedItems = 0,
    this.progressApplied = 0,
    this.skippedItems = 0,
    this.blockedItems = 0,
  });

  final LibrarySyncResultCode code;
  final int addedItems;
  final int updatedItems;
  final int progressApplied;
  final int skippedItems;
  final int blockedItems;
}

// Descriptive aliases keep the public contract discoverable for callers that
// prefer the feature-qualified names while retaining the compact v1 names.
typedef ContentLibrarySyncIdentity = LibrarySyncIdentity;
typedef ContentLibrarySyncReadingProgress = LibrarySyncReadingProgress;
typedef ContentLibrarySyncItem = LibrarySyncItem;
typedef ContentLibrarySyncSnapshot = LibrarySyncSnapshot;
typedef ContentLibrarySyncBlockedReason = LibrarySyncBlockedReason;
typedef ContentLibrarySyncBlockedItem = LibrarySyncBlockedItem;
typedef ContentLibrarySyncConflict = LibrarySyncConflict;
typedef ContentLibrarySyncPreview = LibrarySyncPreview;
typedef ContentLibrarySyncConflictChoice = LibrarySyncConflictChoice;
typedef ContentLibrarySyncResultCode = LibrarySyncResultCode;
typedef ContentLibrarySyncApplyResult = LibrarySyncApplyResult;

final class CatalogEntry {
  const CatalogEntry({
    required this.id,
    required this.itemId,
    required this.remoteIdentity,
    required this.title,
    required this.orderKey,
    required this.index,
    required this.kind,
    required this.contentStatus,
    this.wordCount,
    this.chapterUrl,
    this.contentReference,
    this.storageKey = 0,
    this.contentVersion = 0,
  });
  final CatalogEntryId id;
  final LibraryItemId itemId;
  final String remoteIdentity, title, orderKey, contentStatus;
  final int index;
  final ContentKind? kind;
  final int? wordCount;
  final Uri? chapterUrl;
  final String? contentReference;
  final int storageKey;
  final int contentVersion;
}

/// A typed remote-novel chapter projection to initialize an app-owned catalog.
///
/// It carries stable chapter identity, display metadata and the source chapter
/// reference needed by the Content Library boundary.
final class SourceNovelCatalogChapter {
  const SourceNovelCatalogChapter({required this.remoteIdentity, required this.title, required this.index, this.wordCount, this.chapterUrl})
    : assert(remoteIdentity != ''),
      assert(title != ''),
      assert(index >= 0),
      assert(wordCount == null || wordCount >= 0);

  final String remoteIdentity;
  final String title;
  final int index;
  final int? wordCount;
  final Uri? chapterUrl;
}

final class Page<T> {
  const Page({required this.items, this.nextCursor});
  final List<T> items;
  final String? nextCursor;
}

enum LibraryVisibility {
  normal('normal'),
  private('private');

  const LibraryVisibility(this.wireValue);

  final String wireValue;

  static LibraryVisibility fromWireValue(String? value) => switch (value) {
    'private' => private,
    _ => normal,
  };
}

final class LibraryQuery {
  const LibraryQuery({this.after, this.limit = bookshelfMaxItemCount, this.state, this.visibility});
  final String? after, state;
  final int limit;

  /// Omitting this selects both normal and private active items.
  final LibraryVisibility? visibility;
}

final class CatalogQuery {
  const CatalogQuery({this.after, this.limit = 100});
  final String? after;
  final int limit;
}

enum LibraryRemovalPolicy { removeFromShelfKeepContent, removeIncludingUnreferencedContent }

sealed class ReadableContent {
  const ReadableContent();
}

final class NovelChapterContent extends ReadableContent {
  const NovelChapterContent({required this.text});
  final String text;
}

final class MangaChapterContent extends ReadableContent {
  const MangaChapterContent({required this.pages});
  final List<MangaPage> pages;
}

final class UnsupportedContent extends ReadableContent {
  const UnsupportedContent({required this.kindCode});
  final String kindCode;
}

final class MangaPage {
  const MangaPage({
    required this.pageId,
    required this.order,
    required this.resource,
    this.downloadedAssetId,
    this.mimeType,
    this.width,
    this.height,
    this.byteLength,
    this.contentVersion = 1,
  });
  final String pageId;
  final int order;
  final SourceResource resource;
  final ContentAssetId? downloadedAssetId;
  final String? mimeType;
  final int? width, height, byteLength;
  final int contentVersion;
}

/// Public, stable manga page input. Plugin payloads remain inside core.
final class MangaPageDescriptor {
  const MangaPageDescriptor({
    required this.pageId,
    required this.order,
    required this.resource,
    this.mimeType = 'image/unknown',
    this.width,
    this.height,
    this.byteLength,
    this.contentVersion = 1,
  });
  final String pageId;
  final int order;
  final SourceResource resource;
  final String mimeType;
  final int? width, height, byteLength;
  final int contentVersion;
}

/// Public manga chapter manifest submitted by the host.
final class MangaChapterDescriptor {
  const MangaChapterDescriptor({required this.remoteIdentity, required this.title, required this.index, required this.pages});
  final String remoteIdentity, title;
  final int index;
  final List<MangaPageDescriptor> pages;
}

final class LibraryMangaReadingProgress implements LibraryProgress {
  const LibraryMangaReadingProgress({
    required this.itemId,
    required this.chapterId,
    required this.imageId,
    required this.imageFraction,
    required this.chapterIndex,
    required this.bookFraction,
    required this.updatedAtUtc,
    this.readingSeconds = 0,
  });
  @override
  final LibraryItemId itemId;
  final String chapterId, imageId;
  final double imageFraction, bookFraction;
  final int chapterIndex, readingSeconds;
  final DateTime updatedAtUtc;

  @override
  ContentKind get kind => ContentKind.manga;
}

final class LibraryMangaBookmark implements LibraryBookmarkEntry {
  const LibraryMangaBookmark({
    required this.id,
    required this.itemId,
    required this.chapterId,
    required this.imageId,
    required this.imageFraction,
    required this.createdAtUtc,
  });
  @override
  final String id;
  @override
  final LibraryItemId itemId;
  @override
  final String chapterId;
  final String imageId;
  final double imageFraction;
  final DateTime createdAtUtc;

  @override
  ContentKind get bookmarkKind => ContentKind.manga;
}

enum PersistencePolicy { durable, refreshable, sessionOnly }

final class SourceResource {
  const SourceResource._({required this.url, required this.persistencePolicy, this.expiresAtUtc});
  final Uri? url;
  final PersistencePolicy persistencePolicy;
  final DateTime? expiresAtUtc;
  static SourceResource durable(Uri url) => SourceResource._(url: url, persistencePolicy: PersistencePolicy.durable);
  static SourceResource refreshable(Uri url, DateTime expiresAtUtc) =>
      SourceResource._(url: url, persistencePolicy: PersistencePolicy.refreshable, expiresAtUtc: expiresAtUtc);
  static SourceResource sessionOnly() => const SourceResource._(url: null, persistencePolicy: PersistencePolicy.sessionOnly);
}
