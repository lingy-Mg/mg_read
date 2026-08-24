import 'dart:collection';

enum ContentKind {
  novel('novel'),
  manga('manga');

  const ContentKind(this.code);
  final String code;
  static ContentKind? fromCode(String code) => switch (code) {
    'novel' => novel,
    'manga' => manga,
    _ => null,
  };
}

final class LibraryItemId {
  const LibraryItemId(this.value);
  final String value;
  @override
  String toString() => value;
}

final class SourceBindingId {
  const SourceBindingId(this.value);
  final String value;
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
    this.coverUrl,
    this.sourceName,
    this.source,
  });
  final LibraryItemId id;
  final String title;
  final String? author;
  final ContentKind kind;
  final String state;
  final int revision;
  final Uri? coverUrl;
  final String? sourceName;

  /// Stable source identity needed to resolve a shelf item for reading.
  ///
  /// This intentionally excludes URLs, cookies, and untyped plugin payloads.
  final LibraryItemSource? source;
}

/// Typed source identity retained by a bookshelf item.
final class LibraryItemSource {
  const LibraryItemSource({
    required this.pluginId,
    required this.pluginVersion,
    required this.remoteContentId,
  }) : assert(pluginId != ''),
       assert(pluginVersion != ''),
       assert(remoteContentId != '');

  final String pluginId;
  final String pluginVersion;
  final String remoteContentId;
}

/// Stable identity for a regenerable source cover shared by all features.
///
/// The URL is part of the identity so a source changing its cover naturally
/// creates a new cache entry without mutating an older entry in place.
final class CoverKey {
  const CoverKey({
    required this.pluginId,
    required this.remoteContentId,
    required this.coverUrl,
    this.pluginVersion = 'unknown',
  }) : assert(pluginId != ''),
       assert(pluginVersion != ''),
       assert(remoteContentId != '');

  final String pluginId;
  final String pluginVersion;
  final String remoteContentId;
  final Uri coverUrl;

  String get canonicalValue =>
      '$pluginId\u001f$pluginVersion\u001f$remoteContentId\u001f$coverUrl';
}

/// A durable, layout-independent text-reading position for one shelf item.
///
/// It uses the reader package's semantic anchors rather than a page number or
/// pixel offset, so it remains valid after layout and font changes.
final class LibraryReadingProgress {
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
}

/// Narrow, host-owned request for adding a typed source item to the shelf.
///
/// It intentionally keeps stable source identity and a small typed display
/// projection. Runtime payloads, cookies, and dynamic data never cross into a
/// feature or widget through this type; the optional cover URL is only a
/// source-provided display reference.
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
}

final class SourceBinding {
  const SourceBinding({
    required this.id,
    required this.itemId,
    required this.pluginId,
    required this.availability,
  });
  final SourceBindingId id;
  final LibraryItemId itemId;
  final String pluginId;
  final String availability;
}

final class CatalogEntry {
  const CatalogEntry({
    required this.id,
    required this.itemId,
    required this.bindingId,
    required this.remoteIdentity,
    required this.title,
    required this.orderKey,
    required this.index,
    required this.kind,
    required this.contentStatus,
    this.wordCount,
    this.hasExplicitRemoteIdentity = true,
    this.contentReference,
  });
  final CatalogEntryId id;
  final LibraryItemId itemId;
  final SourceBindingId bindingId;
  final String remoteIdentity, title, orderKey, contentStatus;
  final int index;
  final ContentKind? kind;
  final int? wordCount;
  final String? contentReference;

  /// Whether this entry was written with the lossless remote identity field.
  ///
  /// Older snapshots encoded the identity in a colon-delimited persistence
  /// key, which could truncate source IDs that themselves contained a colon.
  /// Readers use this flag to refresh those legacy snapshots once.
  final bool hasExplicitRemoteIdentity;
}

/// A typed remote-novel chapter projection to initialize an app-owned catalog.
///
/// It carries only stable chapter identity and display metadata; Runtime payloads
/// and source URLs remain outside the Content Library boundary.
final class SourceNovelCatalogChapter {
  const SourceNovelCatalogChapter({
    required this.remoteIdentity,
    required this.title,
    required this.index,
    this.wordCount,
  }) : assert(remoteIdentity != ''),
       assert(title != ''),
       assert(index >= 0),
       assert(wordCount == null || wordCount >= 0);

  final String remoteIdentity;
  final String title;
  final int index;
  final int? wordCount;
}

final class Page<T> {
  const Page({required this.items, this.nextCursor});
  final List<T> items;
  final String? nextCursor;
}

final class LibraryQuery {
  const LibraryQuery({this.after, this.limit = 100, this.state});
  final String? after, state;
  final int limit;
}

final class CatalogQuery {
  const CatalogQuery({this.after, this.limit = 100});
  final String? after;
  final int limit;
}

enum LibraryRemovalPolicy {
  removeFromShelfKeepContent,
  removeIncludingUnreferencedContent,
}

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
  });
  final String pageId;
  final int order;
  final SourceResource resource;
  final ContentAssetId? downloadedAssetId;
}

enum PersistencePolicy { durable, refreshable, sessionOnly }

final class SourceResource {
  const SourceResource._({
    required this.url,
    required this.persistencePolicy,
    this.expiresAtUtc,
  });
  final Uri? url;
  final PersistencePolicy persistencePolicy;
  final DateTime? expiresAtUtc;
  static SourceResource durable(Uri url) =>
      SourceResource._(url: url, persistencePolicy: PersistencePolicy.durable);
  static SourceResource refreshable(Uri url, DateTime expiresAtUtc) =>
      SourceResource._(
        url: url,
        persistencePolicy: PersistencePolicy.refreshable,
        expiresAtUtc: expiresAtUtc,
      );
  static SourceResource sessionOnly() => const SourceResource._(
    url: null,
    persistencePolicy: PersistencePolicy.sessionOnly,
  );
}

/// Runtime-facing validated commit input. It is intentionally not exported by
/// the barrel; an adapter inside core may use it while feature/UI cannot.
final class ContentLibraryIngest {
  const ContentLibraryIngest({
    required this.pluginId,
    required this.producerPluginVersion,
    required this.dataVersion,
    required this.opaqueData,
  });
  final String pluginId, producerPluginVersion;
  final int dataVersion;
  final Map<String, Object?> opaqueData;
}

JsonObjectFrozen freezeInternalJson(Map<String, Object?> source) =>
    JsonObjectFrozen(UnmodifiableMapView(Map.of(source)));

final class JsonObjectFrozen {
  const JsonObjectFrozen(this.value);
  final Map<String, Object?> value;
}
