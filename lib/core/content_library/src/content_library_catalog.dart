part of 'content_library.dart';

final class _CatalogOperations {
  _CatalogOperations(this._library);
  final ContentLibrary _library;

  /// Synchronizes a manga catalog using only stable host-owned fields.
  Future<int> syncMangaCatalog({required LibraryItemId itemId, required Iterable<MangaChapterDescriptor> chapters}) {
    final values = chapters.toList(growable: false);
    final writes = <ContentLibraryCatalogWrite>[
      for (final chapter in values)
        ContentLibraryCatalogWrite(
          chapterId: _id(),
          remoteIdentity: chapter.remoteIdentity,
          title: chapter.title,
          sourceIndex: chapter.index,
        ),
    ];
    _validateCatalogWrites(writes);
    return _library._withStorageMaintenance(() async {
      return _library._persistence.metadataRecords.contentLibrary.appendCatalog(
        itemId: itemId.value,
        contentKind: ContentKind.manga.code,
        chapters: writes,
      );
    });
  }

  Future<Page<CatalogEntry>> list(LibraryItemId itemId, CatalogQuery query) => _library._trace(
    operation: 'catalogList',
    itemCount: query.limit,
    action: () => _list(itemId, query),
    resultCount: (result) => result.items.length,
    resultState: (result) => result.items.isEmpty ? 'empty' : 'content',
  );

  /// Returns the sole append-only catalog without leaking persistence cursors.
  Future<List<CatalogEntry>> listAll(LibraryItemId itemId) => _library._trace(
    operation: 'catalogListAll',
    action: () => _listAll(itemId),
    resultCount: (result) => result.length,
    resultState: (result) => result.isEmpty ? 'empty' : 'content',
  );

  /// Appends unseen chapters to the sole durable catalog for this item.
  Future<int> ensureNovelCatalog({required LibraryItemId itemId, required Iterable<SourceNovelCatalogChapter> chapters}) {
    final copied = List<SourceNovelCatalogChapter>.of(chapters);
    return _library._trace(
      operation: 'catalogEnsureNovel',
      contentKind: ContentKind.novel.code,
      itemCount: copied.length,
      action: () => _library._withStorageMaintenance(() => _ensureNovelCatalog(itemId, copied)),
      resultCount: (result) => result,
      resultState: (result) => result == 0 ? 'empty' : 'content',
    );
  }

  /// Appends unseen chapters without rewriting or deleting existing rows.
  Future<int> syncNovelCatalog({required LibraryItemId itemId, required Iterable<SourceNovelCatalogChapter> chapters}) {
    final copied = List<SourceNovelCatalogChapter>.of(chapters);
    return _library._trace(
      operation: 'catalogSyncNovel',
      contentKind: ContentKind.novel.code,
      itemCount: copied.length,
      action: () => _library._withStorageMaintenance(() => _syncNovelCatalog(itemId, copied)),
      resultCount: (result) => result,
      resultState: (result) => result == 0 ? 'empty' : 'content',
    );
  }

  Future<CatalogEntry?> _findBounded({
    required LibraryItemId itemId,
    required int upperBound,
    String? remoteIdentity,
    int? position,
  }) async {
    final row = remoteIdentity == null
        ? await _library._persistence.metadataRecords.contentLibrary.chapterAt(itemId.value, position ?? -1, upperBound)
        : await _library._persistence.metadataRecords.contentLibrary.chapterByRemote(itemId.value, remoteIdentity, upperBound);
    return row == null ? null : _storedEntry(row, itemId);
  }

  Future<Map<String, CatalogEntry>> _findManyBounded({
    required LibraryItemId itemId,
    required int upperBound,
    required Iterable<String> remoteIdentities,
  }) async {
    final identities = remoteIdentities.toSet();
    if (identities.isEmpty) return const <String, CatalogEntry>{};
    final records = await _library._persistence.metadataRecords.contentLibrary.chaptersByRemote(itemId.value, identities, upperBound);
    return Map<String, CatalogEntry>.unmodifiable({
      for (final record in records) record.values['remote_identity']! as String: _storedEntry(record, itemId),
    });
  }

  Future<CatalogEntry?> _activeEntryByRemoteIdentity(LibraryItemId itemId, String remoteIdentity) async {
    final item = await _library._persistence.metadataRecords.contentLibrary.readItem(itemId.value);
    if (item == null) return null;
    final row = await _library._persistence.metadataRecords.contentLibrary.chapterByRemote(
      itemId.value,
      remoteIdentity,
      item.values['catalog_count']! as int,
    );
    return row == null ? null : _storedEntry(row, itemId);
  }

  Future<Page<CatalogEntry>> _pageBounded({
    required LibraryItemId itemId,
    required int upperBound,
    required String? after,
    required int limit,
  }) async {
    final afterPosition = int.tryParse(after ?? '') ?? -1;
    final pageSize = limit.clamp(1, 500);
    final rows = await _library._persistence.metadataRecords.contentLibrary.listCatalog(
      itemId: itemId.value,
      upperBound: upperBound,
      afterPosition: afterPosition,
      limit: pageSize,
    );
    final next = rows.length == pageSize && (rows.last.values['position']! as int) + 1 < upperBound
        ? (rows.last.values['position']! as int).toString()
        : null;
    return Page(items: List<CatalogEntry>.unmodifiable(rows.map((row) => _storedEntry(row, itemId))), nextCursor: next);
  }

  Future<Page<CatalogEntry>> _list(LibraryItemId itemId, CatalogQuery query) async {
    final item = await _library._persistence.metadataRecords.contentLibrary.readItem(itemId.value);
    if (item == null) return const Page(items: <CatalogEntry>[]);
    return _pageBounded(itemId: itemId, upperBound: item.values['catalog_count']! as int, after: query.after, limit: query.limit);
  }

  Future<List<CatalogEntry>> _listAll(LibraryItemId itemId) async {
    final entries = <CatalogEntry>[];
    String? cursor;
    do {
      final page = await _list(itemId, CatalogQuery(after: cursor, limit: 500));
      entries.addAll(page.items);
      cursor = page.nextCursor;
    } while (cursor != null);
    return List<CatalogEntry>.unmodifiable(entries);
  }

  Future<int> _ensureNovelCatalog(LibraryItemId itemId, List<SourceNovelCatalogChapter> chapters) async {
    return _syncNovelCatalog(itemId, chapters);
  }

  Future<int> _syncNovelCatalog(LibraryItemId itemId, List<SourceNovelCatalogChapter> chapters) async {
    final seen = <String>{};
    for (final chapter in chapters) {
      if (chapter.remoteIdentity.isEmpty || chapter.title.isEmpty || !seen.add(chapter.remoteIdentity)) {
        throw ArgumentError.value(chapter.remoteIdentity, 'chapters');
      }
    }
    final writes = <ContentLibraryCatalogWrite>[
      for (final chapter in chapters)
        ContentLibraryCatalogWrite(
          chapterId: _id(),
          remoteIdentity: chapter.remoteIdentity,
          title: chapter.title,
          sourceIndex: chapter.index,
          chapterUrl: chapter.chapterUrl?.toString(),
          wordCount: chapter.wordCount,
        ),
    ];
    _validateCatalogWrites(writes);
    return _library._persistence.metadataRecords.contentLibrary.appendCatalog(
      itemId: itemId.value,
      contentKind: ContentKind.novel.code,
      chapters: writes,
    );
  }
}

void _validateCatalogWrites(List<ContentLibraryCatalogWrite> writes) {
  final seen = <String>{};
  for (final write in writes) {
    if (write.remoteIdentity.isEmpty || write.title.isEmpty || !seen.add(write.remoteIdentity)) {
      throw ArgumentError.value(write.remoteIdentity, 'chapters', 'Chapter identities must be non-empty and unique.');
    }
  }
}

final class _SerializedMangaPage {
  const _SerializedMangaPage({
    required this.pageId,
    required this.order,
    required this.resource,
    this.downloadedAssetId,
    this.mimeType = 'image/unknown',
    this.width,
    this.height,
    this.byteLength,
    this.contentVersion = 1,
  });
  final String pageId;
  final int order;
  final SourceResource resource;
  final ContentAssetId? downloadedAssetId;
  final String mimeType;
  final int? width, height, byteLength;
  final int contentVersion;
  Map<String, Object?> toJson() => {
    'pageId': pageId,
    'order': order,
    'policy': resource.persistencePolicy.name,
    if (resource.url != null) 'url': resource.url.toString(),
    if (resource.expiresAtUtc != null) 'expiresAtUtc': resource.expiresAtUtc!.toUtc().toIso8601String(),
    if (downloadedAssetId != null) 'assetId': downloadedAssetId!.value,
    'mimeType': mimeType,
    if (width != null) 'width': width,
    if (height != null) 'height': height,
    if (byteLength != null) 'byteLength': byteLength,
    'contentVersion': contentVersion,
  };
}

DiagnosticObjectValue _libraryAttributes({
  required String operation,
  String? contentKind,
  int? itemCount,
  int? bytes,
  String? resultState,
  String? errorCode,
}) => DiagnosticObjectValue(<String, DiagnosticValue>{
  'operation': DiagnosticValue.string(operation),
  if (contentKind != null) 'contentKind': DiagnosticValue.string(contentKind),
  if (itemCount != null) 'itemCount': DiagnosticValue.int64(itemCount),
  if (bytes != null) 'bytes': DiagnosticValue.int64(bytes),
  if (resultState != null) 'resultState': DiagnosticValue.string(resultState),
  if (errorCode != null) 'errorCode': DiagnosticValue.string(errorCode),
  'thresholdMicros': DiagnosticValue.int64(AppDiagnosticThresholds.libraryOperation.inMicroseconds),
});

LibraryItem _storedItem(StoredLibraryItem row) {
  final values = row.values;
  final rawDetails = jsonDecode(values['details_json']! as String);
  final details = rawDetails is Map<String, Object?> ? rawDetails : const <String, Object?>{};
  return LibraryItem(
    id: LibraryItemId(values['item_id']! as String),
    title: values['title']! as String,
    author: values['author'] as String?,
    kind: ContentKind.fromCode(values['content_kind']! as String) ?? ContentKind.novel,
    state: values['shelf_state']! as String,
    revision: values['item_revision']! as int,
    visibility: LibraryVisibility.fromWireValue(values['visibility'] as String?),
    coverUrl: _uriFromValue(values['cover_url']),
    sourceName: values['source_name'] as String?,
    sourceUrl: _uriFromValue(details['sourceUrl']),
    description: details['description'] as String?,
    language: details['language'] as String?,
    accessCode: details['accessCode'] as String?,
    wordCount: details['wordCount'] as int?,
    chapterCount: values['source_chapter_count'] as int?,
    publishedAt: _dateTimeValue(details['publishedAt']),
    updatedAt: _dateTimeValue(details['updatedAt']),
    statusLabel: details['statusLabel'] as String?,
    latestChapterId: details['latestChapterId'] as String?,
    latestChapterTitle: details['latestChapterTitle'] as String?,
    latestChapterUrl: _uriFromValue(details['latestChapterUrl']),
    latestChapterUpdatedAt: _dateTimeValue(details['latestChapterUpdatedAt']),
    categories: _stringList(details['categories']),
    tags: _stringList(details['tags']),
    attributes: _storedAttributes(details['attributes']),
    sourceDetail: _stringObjectMap(details['sourceDetail']),
    labels: _stringList(details['labels']),
    source: LibraryItemSource(
      pluginId: values['source_plugin_id']! as String,
      pluginVersion: values['source_plugin_version']! as String,
      remoteContentId: values['remote_item_id']! as String,
    ),
  );
}

LibraryShelfProjection _storedShelfProjection(StoredShelfItem row) {
  final values = row.values;
  final progressUpdated = values['progress_updated_at_utc'] as int?;
  return LibraryShelfProjection(
    itemId: LibraryItemId(values['item_id']! as String),
    kind: ContentKind.fromCode(values['content_kind']! as String) ?? ContentKind.novel,
    title: values['title']! as String,
    author: values['author'] as String?,
    coverUrl: _uriFromValue(values['cover_url']),
    sourceName: values['source_name'] as String?,
    source: LibraryItemSource(
      pluginId: values['source_plugin_id']! as String,
      pluginVersion: values['source_plugin_version']! as String,
      remoteContentId: values['remote_item_id']! as String,
    ),
    sourceChapterCount: values['source_chapter_count'] as int?,
    catalogCount: values['catalog_count']! as int,
    summaryExcerpt: values['summary_excerpt'] as String?,
    progressKind: values['progress_kind'] == null ? null : ContentKind.fromCode(values['progress_kind']! as String),
    chapterPosition: values['chapter_position'] as int?,
    bookFraction: (values['book_fraction'] as num?)?.toDouble(),
    totalReadingSeconds: values['total_reading_seconds'] as int?,
    progressUpdatedAtUtc: progressUpdated == null ? null : DateTime.fromMillisecondsSinceEpoch(progressUpdated, isUtc: true),
  );
}

String? _summaryExcerpt(String? value) {
  if (value == null || value.isEmpty) return null;
  return value.length <= 240 ? value : value.substring(0, 240);
}

DateTime? _dateTimeValue(Object? value) => value is String ? DateTime.tryParse(value) : null;

List<String> _stringList(Object? value) =>
    value is List<Object?> ? List<String>.unmodifiable(value.whereType<String>().where((item) => item.isNotEmpty)) : const <String>[];

List<LibraryItemAttribute> _storedAttributes(Object? value) {
  if (value is! List<Object?>) return const <LibraryItemAttribute>[];
  return <LibraryItemAttribute>[
    for (final raw in value)
      if (raw is Map && raw['key'] is String && raw['label'] is String && raw['value'] is String)
        LibraryItemAttribute(key: raw['key']! as String, label: raw['label']! as String, value: raw['value']! as String),
  ];
}

Map<String, Object?> _stringObjectMap(Object? value) => value is Map
    ? Map<String, Object?>.unmodifiable(<String, Object?>{
        for (final entry in value.entries)
          if (entry.key is String) entry.key as String: entry.value,
      })
    : const <String, Object?>{};

Map<String, Object?> _shelfSummary(BookshelfAddRequest request) => <String, Object?>{
  if (request.coverUrl != null) 'coverUrl': request.coverUrl.toString(),
  if (request.sourceName != null) 'sourceName': request.sourceName,
  if (request.sourceUrl != null) 'sourceUrl': request.sourceUrl.toString(),
  if (request.description != null) 'description': request.description,
  if (request.language != null) 'language': request.language,
  if (request.accessCode != null) 'accessCode': request.accessCode,
  if (request.wordCount != null) 'wordCount': request.wordCount,
  if (request.chapterCount != null) 'chapterCount': request.chapterCount,
  if (request.publishedAt != null) 'publishedAt': request.publishedAt!.toIso8601String(),
  if (request.updatedAt != null) 'updatedAt': request.updatedAt!.toIso8601String(),
  if (request.statusLabel != null) 'statusLabel': request.statusLabel,
  if (request.latestChapterId != null) 'latestChapterId': request.latestChapterId,
  if (request.latestChapterTitle != null) 'latestChapterTitle': request.latestChapterTitle,
  if (request.latestChapterUrl != null) 'latestChapterUrl': request.latestChapterUrl.toString(),
  if (request.latestChapterUpdatedAt != null) 'latestChapterUpdatedAt': request.latestChapterUpdatedAt!.toIso8601String(),
  if (request.categories.isNotEmpty) 'categories': request.categories,
  if (request.tags.isNotEmpty) 'tags': request.tags,
  if (request.attributes.isNotEmpty)
    'attributes': <Map<String, String>>[
      for (final attribute in request.attributes)
        <String, String>{'key': attribute.key, 'label': attribute.label, 'value': attribute.value},
    ],
  if (request.sourceDetail.isNotEmpty) 'sourceDetail': request.sourceDetail,
  if (request.labels.isNotEmpty) 'labels': request.labels,
};

Uri? _uriFromValue(Object? value) {
  if (value is! String || value.isEmpty) return null;
  return Uri.tryParse(value);
}

CatalogEntry _storedEntry(StoredCatalogChapter row, LibraryItemId itemId) {
  final values = row.values;
  final position = values['position']! as int;
  return CatalogEntry(
    id: CatalogEntryId(values['chapter_id']! as String),
    itemId: itemId,
    remoteIdentity: values['remote_identity']! as String,
    title: values['title']! as String,
    orderKey: _catalogOrderKey(position),
    index: position,
    kind: ContentKind.fromCode(values['content_kind']! as String),
    contentStatus: values['content_status']! as String,
    wordCount: values['word_count'] as int?,
    chapterUrl: _uriFromValue(values['chapter_url']),
    contentReference: values['content_ref'] as String?,
    storageKey: row.chapterPk,
    contentVersion: values['content_version']! as int,
  );
}

String _id() {
  final random = Random.secure();
  return List.generate(24, (_) => 'abcdefghijklmnopqrstuvwxyz0123456789'[random.nextInt(36)]).join();
}

void _safeText(String text) {
  if (text.isEmpty || text.length > 32768) {
    throw ArgumentError.value(text, 'text');
  }
}

void _validateCover(List<int> bytes, String mimeType) {
  if (bytes.isEmpty || bytes.length > 5 * 1024 * 1024) {
    throw ArgumentError.value(bytes.length, 'bytes');
  }
  if (mimeType.isEmpty || mimeType.length > 128) {
    throw ArgumentError.value(mimeType, 'mimeType');
  }
}

String _storageKey(CoverKey key) {
  final digest = DiagnosticSha256()..add(utf8.encode(key.canonicalValue));
  return digest.closeHex();
}
