/// Content Library 不可变正文对象写入、引用切换与读取。
///
/// 正文先写入对象库，再在共享维护屏障内以 metadata CAS 挂接；UI 不接触对象路径。
part of 'content_library.dart';

final class _ContentOperations {
  _ContentOperations(this._library);
  final ContentLibrary _library;
  Future<void> cacheMangaChapter({required CatalogEntryId entryId, required Iterable<MangaPageDescriptor> pages}) {
    final copied = pages.toList(growable: false);
    return _library._withStorageMaintenance(() async {
      final chapter = await _library._persistence.metadataRecords.contentLibrary.chapterById(entryId.value);
      if (chapter?.values['content_kind'] != ContentKind.manga.code) {
        throw StateError('The catalog entry is not a manga chapter.');
      }
      return _putManga(
        entryId: entryId,
        pages: copied
            .map(
              (page) => _SerializedMangaPage(
                pageId: page.pageId,
                order: page.order,
                resource: page.resource,
                downloadedAssetId: null,
                mimeType: page.mimeType,
                width: page.width,
                height: page.height,
                byteLength: page.byteLength,
                contentVersion: page.contentVersion,
              ),
            )
            .toList(growable: false),
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

  Future<void> _putNovel({required CatalogEntryId entryId, required String text, int? wordCount}) =>
      _library._withStorageMaintenance(() => _putNovelLocked(entryId: entryId, text: text, wordCount: wordCount));

  Future<void> _putNovelLocked({required CatalogEntryId entryId, required String text, int? wordCount}) async {
    final objectId = _id();
    await _library._persistence.contentObjects.put(
      objectId: objectId,
      contentKind: 'novel',
      objectType: 'text',
      generation: 1,
      payload: text,
    );
    await _attach(entryId, objectId, wordCount: wordCount);
  }

  Future<void> _cacheNovelChapter({required LibraryItemId itemId, required String remoteChapterId, required String text}) async {
    final item = await _library.getLibraryItem(itemId);
    if (item == null) throw StateError('The cached catalog does not contain the chapter.');
    final catalog = await _library._catalog._activeEntryByRemoteIdentity(itemId, remoteChapterId);
    if (catalog == null) throw StateError('The cached catalog does not contain the chapter.');
    await _cacheNovelChapterForEntry(item: item, entry: catalog, text: text);
  }

  Future<void> _cacheNovelChapterForEntry({required LibraryItem item, required CatalogEntry entry, required String text}) async {
    if (item.kind != ContentKind.novel || entry.itemId.value != item.id.value || entry.kind != ContentKind.novel) {
      throw ArgumentError.value(entry, 'entry');
    }
    await _putNovel(entryId: entry.id, text: text, wordCount: text.length);
  }

  Future<void> _refreshNovelChapterForEntry({required LibraryItem item, required CatalogEntry entry, required String text}) async {
    if (item.kind != ContentKind.novel || entry.itemId.value != item.id.value || entry.kind != ContentKind.novel) {
      throw ArgumentError.value(entry, 'entry');
    }
    final objectId = _id();
    await _library._persistence.contentObjects.put(
      objectId: objectId,
      contentKind: ContentKind.novel.code,
      objectType: 'text',
      generation: entry.contentVersion + 1,
      payload: text,
    );
    final attached = await _library._persistence.metadataRecords.contentLibrary.attachContent(
      chapterPk: entry.storageKey,
      expectedVersion: entry.contentVersion,
      contentRef: objectId,
      wordCount: text.length,
    );
    if (!attached) throw const PersistenceConflictError();
  }

  Future<void> _putManga({required CatalogEntryId entryId, required List<_SerializedMangaPage> pages}) =>
      _library._withStorageMaintenance(() => _putMangaLocked(entryId: entryId, pages: pages));

  Future<void> _putMangaLocked({required CatalogEntryId entryId, required List<_SerializedMangaPage> pages}) async {
    final objectId = _id();
    final serialized = jsonEncode({'pages': pages.map((p) => p.toJson()).toList(growable: false)});
    await _library._persistence.contentObjects.put(
      objectId: objectId,
      contentKind: 'manga',
      objectType: 'manifest',
      generation: 1,
      payload: serialized,
    );
    await _attach(entryId, objectId);
  }

  Future<void> _attach(CatalogEntryId id, String objectId, {int? wordCount}) async {
    final chapter = await _library._persistence.metadataRecords.contentLibrary.chapterById(id.value);
    if (chapter == null) throw StateError('Missing catalog entry.');
    final attached = await _library._persistence.metadataRecords.contentLibrary.attachContent(
      chapterPk: chapter.chapterPk,
      expectedVersion: chapter.values['content_version']! as int,
      contentRef: objectId,
      wordCount: wordCount,
    );
    if (!attached) throw const PersistenceConflictError();
  }

  Future<ReadableContent?> _open(CatalogEntryId id) async {
    final record = await _library._persistence.metadataRecords.contentLibrary.chapterById(id.value);
    final objectId = record?.values['content_ref'];
    final kindCode = record?.values['content_kind'];
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
