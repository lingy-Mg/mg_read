part of 'content_library.dart';

final class CatalogRepository {
  CatalogRepository._(this._library);
  final ContentLibrary _library;
  Future<void> replaceSnapshot({
    required LibraryItemId itemId,
    required SourceBindingId bindingId,
    required Iterable<IngestCatalogEntry> entries,
  }) {
    final copied = List<IngestCatalogEntry>.of(entries);
    return _library._trace(
      operation: 'catalogReplaceSnapshot',
      itemCount: copied.length,
      action: () => _replaceSnapshot(itemId: itemId, bindingId: bindingId, entries: copied),
    );
  }

  /// Synchronizes a manga catalog using only stable host-owned fields.
  Future<int> syncMangaCatalog({required LibraryItemId itemId, required Iterable<MangaChapterDescriptor> chapters}) {
    final values = chapters.toList(growable: false);
    return _library._withStorageMaintenance(() async {
      final item = await _library.getLibraryItem(itemId);
      final source = item?.source;
      if (item == null || item.kind != ContentKind.manga || source == null) {
        throw StateError('The shelf item is not a manga item with source identity.');
      }
      final ingest = ContentLibraryIngest(
        pluginId: source.pluginId,
        producerPluginVersion: source.pluginVersion,
        dataVersion: 1,
        opaqueData: {'remoteBookId': source.remoteContentId},
      );
      return _replaceSnapshot(
        itemId: itemId,
        bindingId: SourceBindingId(_id()),
        entries: values.map(
          (chapter) => IngestCatalogEntry(
            remoteIdentity: chapter.remoteIdentity,
            title: chapter.title,
            orderKey: _catalogOrderKey(chapter.index),
            index: chapter.index,
            kindCode: ContentKind.manga.code,
            source: ingest,
          ),
        ),
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

  /// Returns the active catalog for one item without leaking persistence cursors.
  Future<List<CatalogEntry>> listAll(LibraryItemId itemId) => _library._trace(
    operation: 'catalogListAll',
    action: () => _listAll(itemId),
    resultCount: (result) => result.length,
    resultState: (result) => result.isEmpty ? 'empty' : 'content',
  );

  /// Initializes a persisted novel catalog once, preserving downloaded chapter
  /// content on all later reader launches.
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

  /// Replaces the active novel catalog while preserving cached chapter bodies.
  ///
  /// Source chapter IDs are stored explicitly, rather than reconstructed from
  /// the internal binding key, so IDs containing `:` remain lossless.
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

  Future<int> _replaceSnapshot({
    required LibraryItemId itemId,
    required SourceBindingId bindingId,
    required Iterable<IngestCatalogEntry> entries,
    Map<String, CatalogEntry> previousByRemoteIdentity = const <String, CatalogEntry>{},
  }) => _library._withStorageMaintenance(
    () =>
        _replaceSnapshotLocked(itemId: itemId, bindingId: bindingId, entries: entries, previousByRemoteIdentity: previousByRemoteIdentity),
  );

  Future<int> _replaceSnapshotLocked({
    required LibraryItemId itemId,
    required SourceBindingId bindingId,
    required Iterable<IngestCatalogEntry> entries,
    required Map<String, CatalogEntry> previousByRemoteIdentity,
  }) async {
    final snapshot = _id();
    var ordinal = 0;
    final batch = <RecordDraft>[];
    for (final input in entries) {
      final previous = previousByRemoteIdentity[input.remoteIdentity];
      batch.add(
        RecordDraft(
          id: input.id ?? _id(),
          recordKind: _entryKind,
          scope: _scope,
          parentId: itemId.value,
          identityKey: '${bindingId.value}:${input.remoteIdentity}',
          orderKey: input.index == null ? input.orderKey : _catalogOrderKey(input.index!),
          stateKey: 'pending:$snapshot',
          document: {
            'bindingId': bindingId.value,
            'snapshotId': snapshot,
            'remoteIdentity': input.remoteIdentity,
            'title': input.title,
            'kind': input.kindCode,
            if (input.index != null) 'index': input.index,
            if (input.chapterUrl != null) 'chapterUrl': input.chapterUrl.toString(),
            'plugin': _plugin(input.source),
            'contentStatus': 'missing',
            if (input.wordCount != null) 'wordCount': input.wordCount,
            if (input.wordCount == null && previous?.wordCount != null) 'wordCount': previous!.wordCount,
            if (previous != null && previous.contentStatus == 'ready') 'contentStatus': 'ready',
          },
        ),
      );
      if (previous != null && previous.contentReference != null) {
        final record = batch.last.document;
        // The object reference is deliberately retained across catalog
        // snapshots; the app-owned content object remains immutable.
        record['contentReference'] = previous.contentReference;
        if (previous.kind != null) {
          record['contentKind'] = previous.kind!.code;
        }
      }
      ordinal++;
      // PersistenceRecordStore rejects batches larger than 128 records.
      // Keep catalog snapshot writes below that contract so a source can
      // return a whole 166-chapter page without failing reader launch.
      if (batch.length == PersistenceRecordStore.maxWriteBatchSize) {
        await _library._persistence.metadataRecords.createBatch(batch);
        batch.clear();
      }
    }
    if (batch.isNotEmpty) {
      await _library._persistence.metadataRecords.createBatch(batch);
    }
    if (ordinal == 0) {
      throw ArgumentError('A catalog snapshot cannot be empty.');
    }
    // Atomic visibility is a single CAS update of the item projection.
    final item = await _library._persistence.metadataRecords.read(id: itemId.value, scope: _scope);
    if (item == null) throw StateError('Missing item.');
    await _library._persistence.metadataRecords.update(
      previous: item,
      document: {...item.document, 'activeSnapshotId': snapshot, 'catalogCount': ordinal},
    );
    return ordinal;
  }

  Future<CatalogEntry?> _findInSnapshot({
    required LibraryItemId itemId,
    required String snapshot,
    required SourceBindingId bindingId,
    String? remoteIdentity,
    String? orderKey,
  }) async {
    final identityKey = remoteIdentity == null ? null : '${bindingId.value}:$remoteIdentity';
    final page = await _library._persistence.metadataRecords.list(
      RecordQuery(
        recordKind: _entryKind,
        scope: _scope,
        parentId: itemId.value,
        stateKey: 'pending:$snapshot',
        identityKey: identityKey,
        orderKey: orderKey,
        limit: 1,
      ),
    );
    return page.records.isEmpty ? null : _entry(page.records.single);
  }

  Future<Map<String, CatalogEntry>> _findManyInSnapshot({
    required LibraryItemId itemId,
    required String snapshot,
    required SourceBindingId bindingId,
    required Iterable<String> remoteIdentities,
  }) async {
    final identities = remoteIdentities.toSet();
    if (identities.isEmpty) return const <String, CatalogEntry>{};
    final records = await _library._persistence.metadataRecords.listByIdentityKeys(
      recordKind: _entryKind,
      scope: _scope,
      identityKeys: identities.map((identity) => '${bindingId.value}:$identity'),
      parentId: itemId.value,
      stateKey: 'pending:$snapshot',
    );
    return Map<String, CatalogEntry>.unmodifiable({
      for (final record in records)
        if (record.document['remoteIdentity'] case final String identity) identity: _entry(record),
    });
  }

  Future<CatalogEntry?> _activeEntryByRemoteIdentity(LibraryItemId itemId, String remoteIdentity) async {
    final item = await _library._persistence.metadataRecords.read(id: itemId.value, scope: _scope);
    final snapshot = item?.document['activeSnapshotId'];
    if (snapshot is! String || snapshot.isEmpty) return null;
    final bindings = await _library._persistence.metadataRecords.list(
      RecordQuery(recordKind: _bindingKind, scope: _scope, parentId: itemId.value, limit: 1),
    );
    if (bindings.records.isEmpty) return null;
    var bindingId = SourceBindingId(bindings.records.single.id);
    final firstEntry = await _library._persistence.metadataRecords.list(
      RecordQuery(recordKind: _entryKind, scope: _scope, parentId: itemId.value, stateKey: 'pending:$snapshot', limit: 1),
    );
    if (firstEntry.records.isNotEmpty) {
      final storedBinding = firstEntry.records.single.document['bindingId'];
      if (storedBinding is String && storedBinding.isNotEmpty) {
        bindingId = SourceBindingId(storedBinding);
      }
    }
    return _findInSnapshot(itemId: itemId, snapshot: snapshot, bindingId: bindingId, remoteIdentity: remoteIdentity);
  }

  Future<Page<CatalogEntry>> _pageInSnapshot({
    required LibraryItemId itemId,
    required String snapshot,
    required String? after,
    required int limit,
  }) async {
    final page = await _library._persistence.metadataRecords.list(
      RecordQuery(
        recordKind: _entryKind,
        scope: _scope,
        parentId: itemId.value,
        stateKey: 'pending:$snapshot',
        after: _cursor(after),
        limit: limit,
      ),
    );
    return Page(items: page.records.map(_entry).toList(growable: false), nextCursor: _cursorText(page.nextCursor));
  }

  Future<Page<CatalogEntry>> _list(LibraryItemId itemId, CatalogQuery query) async {
    final item = await _library._persistence.metadataRecords.read(id: itemId.value, scope: _scope);
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
    return Page(items: page.records.map(_entry).toList(growable: false), nextCursor: _cursorText(page.nextCursor));
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
    final item = await _library._persistence.metadataRecords.read(id: itemId.value, scope: _scope);
    final activeSnapshot = item?.document['activeSnapshotId'];
    final storedCatalogCount = item?.document['catalogCount'];
    if (activeSnapshot is String && activeSnapshot.isNotEmpty) {
      if (storedCatalogCount is int && storedCatalogCount > 0) return storedCatalogCount;
      final existingCount = await _library._persistence.metadataRecords.count(
        RecordQuery(recordKind: _entryKind, scope: _scope, parentId: itemId.value, stateKey: 'pending:$activeSnapshot', limit: 1),
      );
      if (existingCount > 0) return existingCount;
    }
    if (chapters.isEmpty) {
      throw ArgumentError.value(chapters, 'chapters', 'Cannot persist an empty catalog.');
    }
    final seen = <String>{};
    for (final chapter in chapters) {
      if (!seen.add(chapter.remoteIdentity)) {
        throw ArgumentError.value(chapter.remoteIdentity, 'chapters');
      }
    }
    final source = item == null ? null : _itemSource(item.document['plugin']);
    if (source == null) {
      throw StateError('The shelf item has no source identity.');
    }
    final bindings = await _library._persistence.metadataRecords.list(
      RecordQuery(recordKind: _bindingKind, scope: _scope, parentId: itemId.value, limit: 1),
    );
    if (bindings.records.isEmpty) {
      throw StateError('The shelf item has no source binding.');
    }
    final ingest = ContentLibraryIngest(
      pluginId: source.pluginId,
      producerPluginVersion: source.pluginVersion,
      dataVersion: 1,
      opaqueData: <String, Object?>{'remoteBookId': source.remoteContentId},
    );
    return _replaceSnapshot(
      itemId: itemId,
      bindingId: SourceBindingId(bindings.records.single.id),
      entries: chapters.map(
        (chapter) => IngestCatalogEntry(
          remoteIdentity: chapter.remoteIdentity,
          title: chapter.title,
          orderKey: chapter.index.toString().padLeft(12, '0'),
          kindCode: ContentKind.novel.code,
          source: ingest,
          index: chapter.index,
          wordCount: chapter.wordCount,
          chapterUrl: chapter.chapterUrl,
        ),
      ),
    );
  }

  Future<int> _syncNovelCatalog(LibraryItemId itemId, List<SourceNovelCatalogChapter> chapters) async {
    if (chapters.isEmpty) {
      throw ArgumentError.value(chapters, 'chapters', 'Cannot persist an empty catalog.');
    }
    final seen = <String>{};
    for (final chapter in chapters) {
      if (!seen.add(chapter.remoteIdentity)) {
        throw ArgumentError.value(chapter.remoteIdentity, 'chapters');
      }
    }
    final item = await _library._persistence.metadataRecords.read(id: itemId.value, scope: _scope);
    final source = item == null ? null : _itemSource(item.document['plugin']);
    if (source == null) {
      throw StateError('The shelf item has no source identity.');
    }
    final bindings = await _library._persistence.metadataRecords.list(
      RecordQuery(recordKind: _bindingKind, scope: _scope, parentId: itemId.value, limit: 1),
    );
    if (bindings.records.isEmpty) {
      throw StateError('The shelf item has no source binding.');
    }
    final previous = {for (final entry in await _listAll(itemId)) entry.remoteIdentity: entry};
    final ingest = ContentLibraryIngest(
      pluginId: source.pluginId,
      producerPluginVersion: source.pluginVersion,
      dataVersion: 1,
      opaqueData: <String, Object?>{'remoteBookId': source.remoteContentId},
    );
    return _replaceSnapshot(
      itemId: itemId,
      bindingId: SourceBindingId(bindings.records.single.id),
      previousByRemoteIdentity: previous,
      entries: chapters.map(
        (chapter) => IngestCatalogEntry(
          remoteIdentity: chapter.remoteIdentity,
          title: chapter.title,
          orderKey: chapter.index.toString().padLeft(12, '0'),
          kindCode: ContentKind.novel.code,
          source: ingest,
          index: chapter.index,
          wordCount: chapter.wordCount,
          chapterUrl: chapter.chapterUrl,
        ),
      ),
    );
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
    this.index,
    this.wordCount,
    this.chapterUrl,
  });
  final String? id;
  final String remoteIdentity, title, orderKey, kindCode;
  final ContentLibraryIngest source;
  final int? index, wordCount;
  final Uri? chapterUrl;
}

final class IngestMangaPage {
  const IngestMangaPage({
    required this.pageId,
    required this.order,
    required this.resource,
    required this.source,
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
  final ContentLibraryIngest source;
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
    'plugin': _plugin(source),
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
  coverUrl: _uriFromSummary(r.document, 'coverUrl'),
  sourceName: _stringFromSummary(r.document, 'sourceName'),
  sourceUrl: _uriFromSummary(r.document, 'sourceUrl'),
  description: _stringFromSummary(r.document, 'description'),
  language: _stringFromSummary(r.document, 'language'),
  accessCode: _stringFromSummary(r.document, 'accessCode'),
  wordCount: _intFromSummary(r.document, 'wordCount'),
  chapterCount: _intFromSummary(r.document, 'chapterCount'),
  publishedAt: _dateTimeFromSummary(r.document, 'publishedAt'),
  updatedAt: _dateTimeFromSummary(r.document, 'updatedAt'),
  statusLabel: _stringFromSummary(r.document, 'statusLabel'),
  latestChapterId: _stringFromSummary(r.document, 'latestChapterId'),
  latestChapterTitle: _stringFromSummary(r.document, 'latestChapterTitle'),
  latestChapterUrl: _uriFromSummary(r.document, 'latestChapterUrl'),
  latestChapterUpdatedAt: _dateTimeFromSummary(r.document, 'latestChapterUpdatedAt'),
  categories: _stringListFromSummary(r.document, 'categories'),
  tags: _stringListFromSummary(r.document, 'tags'),
  attributes: _attributesFromSummary(r.document),
  labels: _stringListFromSummary(r.document, 'labels'),
  source: _itemSource(r.document['plugin']),
  visibility: _visibilityFromDocument(r.document),
);

LibraryVisibility _visibilityFromDocument(Map<String, Object?> document) =>
    LibraryVisibility.fromWireValue(document['visibility'] as String?);

Map<String, Object?> _shelfSummary(ContentLibraryIngest source) {
  final summary = <String, Object?>{};
  final stringKeys = <String>[
    'coverUrl',
    'sourceName',
    'sourceUrl',
    'description',
    'language',
    'accessCode',
    'statusLabel',
    'publishedAt',
    'updatedAt',
    'latestChapterId',
    'latestChapterTitle',
    'latestChapterUrl',
    'latestChapterUpdatedAt',
  ];
  for (final key in stringKeys) {
    final value = source.opaqueData[key];
    if (value is String && value.isNotEmpty) summary[key] = value;
  }
  for (final key in ['wordCount', 'chapterCount']) {
    final value = source.opaqueData[key];
    if (value is int && value >= 0) summary[key] = value;
  }
  for (final key in ['categories', 'tags', 'labels']) {
    final raw = source.opaqueData[key];
    if (raw is List<Object?>) {
      final values = raw.whereType<String>().where((value) => value.isNotEmpty);
      if (values.isNotEmpty) summary[key] = values.toList(growable: false);
    }
  }
  final attributes = source.opaqueData['attributes'];
  if (attributes is List<Object?>) {
    final values = <Map<String, String>>[];
    for (final raw in attributes) {
      if (raw is! Map) continue;
      final key = raw['key'];
      final label = raw['label'];
      final value = raw['value'];
      if (key is String && key.isNotEmpty && label is String && label.isNotEmpty && value is String && value.isNotEmpty) {
        values.add(<String, String>{'key': key, 'label': label, 'value': value});
      }
    }
    if (values.isNotEmpty) summary['attributes'] = values;
  }
  return summary;
}

Map<String, Object?> _summaryFromDocument(Map<String, Object?> document) {
  final raw = document['summary'];
  return raw is Map<String, Object?> ? Map<String, Object?>.from(raw) : <String, Object?>{};
}

String? _stringFromSummary(Map<String, Object?> document, String key) {
  final value = _summaryFromDocument(document)[key];
  return value is String && value.isNotEmpty ? value : null;
}

DateTime? _dateTimeFromSummary(Map<String, Object?> document, String key) {
  final value = _stringFromSummary(document, key);
  return value == null ? null : DateTime.tryParse(value);
}

List<LibraryItemAttribute> _attributesFromSummary(Map<String, Object?> document) {
  final raw = _summaryFromDocument(document)['attributes'];
  if (raw is! List<Object?>) return const <LibraryItemAttribute>[];
  return <LibraryItemAttribute>[
    for (final value in raw)
      if (value is Map &&
          value['key'] is String &&
          (value['key']! as String).isNotEmpty &&
          value['label'] is String &&
          (value['label']! as String).isNotEmpty &&
          value['value'] is String &&
          (value['value']! as String).isNotEmpty)
        LibraryItemAttribute(key: value['key']! as String, label: value['label']! as String, value: value['value']! as String),
  ];
}

Uri? _uriFromSummary(Map<String, Object?> document, String key) {
  final value = _stringFromSummary(document, key);
  return value == null ? null : Uri.tryParse(value);
}

Uri? _uriFromValue(Object? value) {
  if (value is! String || value.isEmpty) return null;
  return Uri.tryParse(value);
}

int? _intFromSummary(Map<String, Object?> document, String key) {
  final value = _summaryFromDocument(document)[key];
  return value is int && value >= 0 ? value : null;
}

List<String> _stringListFromSummary(Map<String, Object?> document, String key) {
  final value = _summaryFromDocument(document)[key];
  if (value is! List<Object?>) return const <String>[];
  return List<String>.unmodifiable(value.whereType<String>().where((item) => item.isNotEmpty));
}

LibraryItemSource? _itemSource(Object? rawPlugin) {
  if (rawPlugin is! Map<String, Object?>) return null;
  final Object? rawData = rawPlugin['data'];
  if (rawData is! Map<String, Object?>) return null;
  final pluginId = rawPlugin['pluginId'];
  final pluginVersion = rawPlugin['producerPluginVersion'];
  final remoteContentId = rawData['remoteBookId'];
  if (pluginId is! String ||
      pluginVersion is! String ||
      remoteContentId is! String ||
      pluginId.isEmpty ||
      pluginVersion.isEmpty ||
      remoteContentId.isEmpty) {
    return null;
  }
  return LibraryItemSource(pluginId: pluginId, pluginVersion: pluginVersion, remoteContentId: remoteContentId);
}

Map<String, Object?> _readingProgressDocument(LibraryReadingProgress progress) => <String, Object?>{
  'chapterId': progress.chapterId,
  'paragraphId': progress.paragraphId,
  'characterOffset': progress.characterOffset,
  'chapterIndex': progress.chapterIndex,
  'chapterFraction': progress.chapterFraction,
  'bookFraction': progress.bookFraction,
  'updatedAtUtc': progress.updatedAtUtc.toUtc().toIso8601String(),
  'totalReadingSeconds': progress.totalReadingSeconds,
};

Map<String, Object?> _audioProgressDocument(LibraryAudioPlaybackProgress progress) => <String, Object?>{
  'chapterId': progress.chapterId,
  'positionMilliseconds': progress.position.inMilliseconds,
  'updatedAtUtc': progress.updatedAtUtc.toUtc().toIso8601String(),
};

Map<String, Object?> _videoProgressDocument(LibraryVideoPlaybackProgress progress) => <String, Object?>{
  'groupId': progress.groupId,
  'episodeId': progress.episodeId,
  'positionMilliseconds': progress.position.inMilliseconds,
  'durationMilliseconds': progress.duration.inMilliseconds,
  'updatedAtUtc': progress.updatedAtUtc.toUtc().toIso8601String(),
};

LibraryAudioPlaybackProgress _audioProgress(RecordEnvelope record) {
  final document = record.document;
  final updatedAt = DateTime.tryParse(document['updatedAtUtc'] as String? ?? '');
  final positionMilliseconds = document['positionMilliseconds'];
  final chapterId = document['chapterId'];
  if (updatedAt == null || chapterId is! String || chapterId.isEmpty || positionMilliseconds is! int || positionMilliseconds < 0) {
    throw const PersistenceCorruptionError();
  }
  return LibraryAudioPlaybackProgress(
    itemId: LibraryItemId(record.parentId ?? record.identityKey ?? ''),
    chapterId: chapterId,
    position: Duration(milliseconds: positionMilliseconds),
    updatedAtUtc: updatedAt.toUtc(),
  );
}

LibraryVideoPlaybackProgress _videoProgress(RecordEnvelope record) {
  final document = record.document;
  final updatedAt = DateTime.tryParse(document['updatedAtUtc'] as String? ?? '');
  final groupId = document['groupId'];
  final episodeId = document['episodeId'];
  final positionMilliseconds = document['positionMilliseconds'];
  final durationMilliseconds = document['durationMilliseconds'];
  if (updatedAt == null ||
      groupId is! String ||
      groupId.isEmpty ||
      episodeId is! String ||
      episodeId.isEmpty ||
      positionMilliseconds is! int ||
      positionMilliseconds < 0 ||
      durationMilliseconds is! int ||
      durationMilliseconds < 0) {
    throw const PersistenceCorruptionError();
  }
  return LibraryVideoPlaybackProgress(
    itemId: LibraryItemId(record.parentId ?? record.identityKey ?? ''),
    groupId: groupId,
    episodeId: episodeId,
    position: Duration(milliseconds: positionMilliseconds),
    duration: Duration(milliseconds: durationMilliseconds),
    updatedAtUtc: updatedAt.toUtc(),
  );
}

LibraryReadingProgress _readingProgress(RecordEnvelope record) {
  final document = record.document;
  final updatedAt = DateTime.tryParse(document['updatedAtUtc'] as String? ?? '');
  if (updatedAt == null ||
      document['chapterId'] is! String ||
      document['paragraphId'] is! String ||
      document['characterOffset'] is! int ||
      document['chapterIndex'] is! int ||
      document['chapterFraction'] is! num ||
      document['bookFraction'] is! num) {
    throw const PersistenceCorruptionError();
  }
  return LibraryReadingProgress(
    itemId: LibraryItemId(record.parentId ?? record.identityKey ?? ''),
    chapterId: document['chapterId']! as String,
    paragraphId: document['paragraphId']! as String,
    characterOffset: document['characterOffset']! as int,
    chapterIndex: document['chapterIndex']! as int,
    chapterFraction: (document['chapterFraction']! as num).toDouble(),
    bookFraction: (document['bookFraction']! as num).toDouble(),
    updatedAtUtc: updatedAt.toUtc(),
    totalReadingSeconds: document['totalReadingSeconds'] as int? ?? 0,
  );
}

String _timestampOrderKey(DateTime value) => value.toUtc().microsecondsSinceEpoch.toString().padLeft(20, '0');
CatalogEntry _entry(RecordEnvelope r) => CatalogEntry(
  id: CatalogEntryId(r.id),
  itemId: LibraryItemId(r.parentId!),
  bindingId: SourceBindingId(r.document['bindingId'] as String),
  remoteIdentity: r.document['remoteIdentity'] is String ? r.document['remoteIdentity']! as String : _remoteIdentity(r.identityKey),
  title: r.document['title'] as String,
  orderKey: r.orderKey ?? '',
  index: r.document['index'] as int? ?? 0,
  kind: ContentKind.fromCode(r.document['kind'] as String),
  contentStatus: r.document['contentStatus'] as String? ?? 'missing',
  wordCount: r.document['wordCount'] as int?,
  chapterUrl: _uriFromValue(r.document['chapterUrl']),
  hasExplicitRemoteIdentity: r.document['remoteIdentity'] is String,
  contentReference: r.document['contentReference'] as String?,
);

String _remoteIdentity(String? identityKey) {
  if (identityKey == null) return '';
  final separator = identityKey.indexOf(':');
  return separator < 0 ? identityKey : identityKey.substring(separator + 1);
}

RecordCursor? _cursor(String? input) {
  if (input == null) return null;
  final parts = input.split('|');
  return parts.length == 2 ? RecordCursor(orderKey: parts[0], id: parts[1]) : null;
}

String? _cursorText(RecordCursor? c) => c == null ? null : '${c.orderKey}|${c.id}';
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
