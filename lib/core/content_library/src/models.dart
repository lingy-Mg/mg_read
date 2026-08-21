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
  });
  final LibraryItemId id;
  final String title;
  final String? author;
  final ContentKind kind;
  final String state;
  final int revision;
}

/// Narrow, host-owned request for adding a typed source item to the shelf.
///
/// It intentionally keeps only stable source identity and display metadata.
/// Runtime payloads, URLs, cookies, and dynamic data never cross into a
/// feature or widget through this type.
final class BookshelfAddRequest {
  const BookshelfAddRequest({
    required this.title,
    required this.author,
    required this.kind,
    required this.pluginId,
    required this.pluginVersion,
    required this.remoteContentId,
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
    required this.title,
    required this.orderKey,
    required this.kind,
    required this.contentStatus,
  });
  final CatalogEntryId id;
  final LibraryItemId itemId;
  final SourceBindingId bindingId;
  final String title, orderKey, contentStatus;
  final ContentKind? kind;
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
