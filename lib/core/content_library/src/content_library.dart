import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:mg_read/core/content_library/src/models.dart';
import 'package:mg_read/core/persistence/persistence.dart';

const _scope = ScopeKey(kind: 'content_library', id: 'default');
const _itemKind = 'content_library_item';
const _bindingKind = 'content_source_binding';
const _entryKind = 'content_catalog_entry';

final class ContentLibrary {
  ContentLibrary._(this._persistence);
  final AppPersistence _persistence;
  late final BookshelfRepository bookshelf = BookshelfRepository._(this);
  late final CatalogRepository catalog = CatalogRepository._(this);
  late final ContentRepository content = ContentRepository._(this);
  static Future<ContentLibrary> open({required Directory dataRoot}) async =>
      ContentLibrary._(
        await AppPersistence.open(dataRoot: dataRoot, registry: _registry),
      );
  Future<void> close() => _persistence.close();
  Future<Page<LibraryItem>> listLibrary(LibraryQuery query) =>
      bookshelf.list(query);
  Future<Page<CatalogEntry>> listCatalog(
    LibraryItemId itemId,
    CatalogQuery query,
  ) => catalog.list(itemId, query);
  Future<ReadableContent?> openContent(CatalogEntryId id) => content.open(id);
}

final class BookshelfRepository {
  BookshelfRepository._(this._library);
  final ContentLibrary _library;
  Future<LibraryItem> add({
    required String title,
    String? author,
    required ContentKind kind,
    required ContentLibraryIngest source,
  }) async {
    _safeText(title);
    final identity =
        '${source.pluginId}:${source.opaqueData['remoteBookId'] ?? title}';
    final existing = await _library._persistence.metadataRecords.list(
      RecordQuery(
        recordKind: _itemKind,
        scope: _scope,
        identityKey: identity,
        limit: 1,
      ),
    );
    if (existing.records.isNotEmpty) return _item(existing.records.single);
    final id = _id();
    final document = {
      'title': title,
      'author': ?author,
      'kind': kind.code,
      'plugin': _plugin(source),
      'summary': <String, Object?>{},
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
  }

  Future<Page<LibraryItem>> list(LibraryQuery query) async {
    final page = await _library._persistence.metadataRecords.list(
      RecordQuery(
        recordKind: _itemKind,
        scope: _scope,
        stateKey: query.state,
        after: _cursor(query.after),
        limit: query.limit,
      ),
    );
    return Page(
      items: page.records.map(_item).toList(growable: false),
      nextCursor: _cursorText(page.nextCursor),
    );
  }

  Future<void> remove(LibraryItemId id, LibraryRemovalPolicy policy) async {
    final record = await _library._persistence.metadataRecords.read(
      id: id.value,
      scope: _scope,
    );
    if (record == null) return;
    await _library._persistence.metadataRecords.delete(
      previous: record,
    ); /* objects remain unless a later bounded maintenance pass proves no references */
  }
}

final class CatalogRepository {
  CatalogRepository._(this._library);
  final ContentLibrary _library;
  Future<void> replaceSnapshot({
    required LibraryItemId itemId,
    required SourceBindingId bindingId,
    required Iterable<IngestCatalogEntry> entries,
  }) async {
    final snapshot = _id();
    var ordinal = 0;
    final batch = <RecordDraft>[];
    for (final input in entries) {
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
            'title': input.title,
            'kind': input.kindCode,
            'plugin': _plugin(input.source),
            'contentStatus': 'missing',
          },
        ),
      );
      ordinal++;
      if (batch.length == 250) {
        await _library._persistence.metadataRecords.createBatch(batch);
        batch.clear();
      }
    }
    if (batch.isNotEmpty)
      await _library._persistence.metadataRecords.createBatch(batch);
    if (ordinal == 0)
      throw ArgumentError('A catalog snapshot cannot be empty.');
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

  Future<Page<CatalogEntry>> list(
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
}

final class ContentRepository {
  ContentRepository._(this._library);
  final ContentLibrary _library;
  Future<void> putNovel({
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

  Future<void> putManga({
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

  Future<ReadableContent?> open(CatalogEntryId id) async {
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
  });
  final String? id;
  final String remoteIdentity, title, orderKey, kindCode;
  final ContentLibraryIngest source;
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

RecordDocumentRegistry get _registry => RecordDocumentRegistry([
  for (final kind in [_itemKind, _bindingKind, _entryKind])
    RecordDocumentCodec(
      recordKind: kind,
      scopeKind: _scope.kind,
      currentVersion: 1,
      validators: {1: _validate},
    ),
]);
void _validate(JsonObject value) {
  if (jsonEncode(value).length > 256 * 1024)
    throw const PersistenceValidationError(
      'Content library dynamic document exceeds 256 KiB.',
    );
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
);
CatalogEntry _entry(RecordEnvelope r) => CatalogEntry(
  id: CatalogEntryId(r.id),
  itemId: LibraryItemId(r.parentId!),
  bindingId: SourceBindingId(r.document['bindingId'] as String),
  title: r.document['title'] as String,
  orderKey: r.orderKey ?? '',
  kind: ContentKind.fromCode(r.document['kind'] as String),
  contentStatus: r.document['contentStatus'] as String? ?? 'missing',
);
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
  if (text.isEmpty || text.length > 32768)
    throw ArgumentError.value(text, 'text');
}
