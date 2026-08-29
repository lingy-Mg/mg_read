/// Content Library 不可变正文对象写入、引用切换与读取。
///
/// 正文先写入对象库，再在共享维护屏障内以 metadata CAS 挂接；UI 不接触对象路径。
part of 'content_library.dart';

final class ContentRepository {
  ContentRepository._(this._library);
  final ContentLibrary _library;
  Future<void> putNovel({required CatalogEntryId entryId, required String text, required ContentLibraryIngest source}) => _library._trace(
    operation: 'contentPutNovel',
    contentKind: 'novel',
    itemCount: 1,
    action: () => _putNovel(entryId: entryId, text: text, source: source),
  );

  Future<void> putManga({required CatalogEntryId entryId, required List<IngestMangaPage> pages, required ContentLibraryIngest source}) =>
      _library._trace(
        operation: 'contentPutManga',
        contentKind: 'manga',
        itemCount: pages.length,
        action: () => _putManga(entryId: entryId, pages: pages, source: source),
      );

  Future<void> cacheMangaChapter({required CatalogEntryId entryId, required Iterable<MangaPageDescriptor> pages}) {
    final copied = pages.toList(growable: false);
    return _library._withStorageMaintenance(() async {
      final record = await _library._persistence.metadataRecords.read(id: entryId.value, scope: _scope);
      final source = _library.getLibraryItem(LibraryItemId(record?.parentId ?? ''));
      final item = await source;
      if (item?.source == null) throw StateError('The shelf item has no source identity.');
      final ingest = ContentLibraryIngest(
        pluginId: item!.source!.pluginId,
        producerPluginVersion: item.source!.pluginVersion,
        dataVersion: 1,
        opaqueData: {'remoteBookId': item.source!.remoteContentId},
      );
      return putManga(
        entryId: entryId,
        pages: copied
            .map(
              (page) => IngestMangaPage(
                pageId: page.pageId,
                order: page.order,
                resource: page.resource,
                source: ingest,
                downloadedAssetId: null,
                mimeType: page.mimeType,
                width: page.width,
                height: page.height,
                byteLength: page.byteLength,
                contentVersion: page.contentVersion,
              ),
            )
            .toList(growable: false),
        source: ingest,
      );
    });
  }

  Future<ReadableContent?> open(CatalogEntryId id) => _library._trace(
    operation: 'contentOpen',
    itemCount: 1,
    action: () => _open(id),
    resultCount: (result) => result == null ? 0 : 1,
    resultState: (result) => result == null ? 'notFound' : 'content',
  );

  Future<void> cacheNovelChapter({required LibraryItemId itemId, required String remoteChapterId, required String text}) => _library._trace(
    operation: 'contentCacheNovelChapter',
    contentKind: ContentKind.novel.code,
    itemCount: 1,
    bytes: text.length,
    action: () => _library._withStorageMaintenance(() => _cacheNovelChapter(itemId: itemId, remoteChapterId: remoteChapterId, text: text)),
  );

  Future<void> _putNovel({required CatalogEntryId entryId, required String text, required ContentLibraryIngest source, int? wordCount}) =>
      _library._withStorageMaintenance(() => _putNovelLocked(entryId: entryId, text: text, source: source, wordCount: wordCount));

  Future<void> _putNovelLocked({
    required CatalogEntryId entryId,
    required String text,
    required ContentLibraryIngest source,
    int? wordCount,
  }) async {
    final objectId = _id();
    await _library._persistence.contentObjects.put(
      objectId: objectId,
      contentKind: 'novel',
      objectType: 'text',
      generation: 1,
      payload: text,
    );
    await _attach(entryId, objectId, 'novel', source, wordCount: wordCount);
  }

  Future<void> _cacheNovelChapter({required LibraryItemId itemId, required String remoteChapterId, required String text}) async {
    final item = await _library.getLibraryItem(itemId);
    final source = item?.source;
    if (source == null) throw StateError('The cached catalog does not contain the chapter.');
    final catalog = await _library.catalog._activeEntryByRemoteIdentity(itemId, remoteChapterId);
    if (catalog == null) throw StateError('The cached catalog does not contain the chapter.');
    await _cacheNovelChapterForEntry(item: item!, entry: catalog, text: text);
  }

  Future<void> _cacheNovelChapterForEntry({required LibraryItem item, required CatalogEntry entry, required String text}) async {
    if (item.kind != ContentKind.novel || entry.itemId.value != item.id.value || entry.kind != ContentKind.novel) {
      throw ArgumentError.value(entry, 'entry');
    }
    final source = item.source;
    if (source == null) throw StateError('The shelf item has no source identity.');
    await _putNovel(
      entryId: entry.id,
      text: text,
      source: ContentLibraryIngest(
        pluginId: source.pluginId,
        producerPluginVersion: source.pluginVersion,
        dataVersion: 1,
        opaqueData: <String, Object?>{'remoteBookId': source.remoteContentId},
      ),
      wordCount: text.length,
    );
  }

  Future<void> _putManga({required CatalogEntryId entryId, required List<IngestMangaPage> pages, required ContentLibraryIngest source}) =>
      _library._withStorageMaintenance(() => _putMangaLocked(entryId: entryId, pages: pages, source: source));

  Future<void> _putMangaLocked({
    required CatalogEntryId entryId,
    required List<IngestMangaPage> pages,
    required ContentLibraryIngest source,
  }) async {
    final objectId = _id();
    final serialized = jsonEncode({'plugin': _plugin(source), 'pages': pages.map((p) => p.toJson()).toList(growable: false)});
    await _library._persistence.contentObjects.put(
      objectId: objectId,
      contentKind: 'manga',
      objectType: 'manifest',
      generation: 1,
      payload: serialized,
    );
    await _attach(entryId, objectId, 'manga', source);
  }

  Future<void> _attach(CatalogEntryId id, String objectId, String kind, ContentLibraryIngest source, {int? wordCount}) async {
    final record = await _library._persistence.metadataRecords.read(id: id.value, scope: _scope);
    if (record == null) throw StateError('Missing catalog entry.');
    final Map<String, Object?> contentMetadata = wordCount == null ? const <String, Object?>{} : <String, Object?>{'wordCount': wordCount};
    await _library._persistence.metadataRecords.update(
      previous: record,
      document: {
        ...record.document,
        'contentReference': objectId,
        'contentKind': kind,
        'contentStatus': 'ready',
        'contentPlugin': _plugin(source),
        ...contentMetadata,
      },
    );
  }

  Future<ReadableContent?> _open(CatalogEntryId id) async {
    final record = await _library._persistence.metadataRecords.read(id: id.value, scope: _scope);
    final objectId = record?.document['contentReference'];
    final kindCode = record?.document['contentKind'];
    if (objectId is! String || kindCode is! String) return null;
    return _openReference(contentReference: objectId, kind: ContentKind.fromCode(kindCode), kindCode: kindCode);
  }

  Future<ReadableContent?> _openReference({required String? contentReference, required ContentKind? kind, String? kindCode}) async {
    if (contentReference == null || contentReference.isEmpty) return null;
    final code = kindCode ?? kind?.code;
    if (code == null) return const UnsupportedContent(kindCode: 'unknown');
    final object = await _library._persistence.contentObjects.read(contentReference);
    if (object == null) return const UnsupportedContent(kindCode: 'missing');
    if (code == 'novel') return NovelChapterContent(text: object.payload);
    if (code != 'manga') return UnsupportedContent(kindCode: code);
    try {
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
                        ? SourceResource.refreshable(Uri.parse(p['url'] as String), DateTime.parse(p['expiresAtUtc'] as String))
                        : SourceResource.durable(Uri.parse(p['url'] as String))),
              downloadedAssetId: p['assetId'] is String ? ContentAssetId(p['assetId'] as String) : null,
              mimeType: p['mimeType'] as String?,
              width: p['width'] as int?,
              height: p['height'] as int?,
              byteLength: p['byteLength'] as int?,
              contentVersion: p['contentVersion'] is int ? p['contentVersion'] as int : 1,
            );
          })
          .toList(growable: false);
      return MangaChapterContent(pages: pages);
    } on Object {
      return const UnsupportedContent(kindCode: 'corrupt');
    }
  }
}
