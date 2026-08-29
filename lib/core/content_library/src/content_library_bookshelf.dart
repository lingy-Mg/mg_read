part of 'content_library.dart';

final class BookshelfRepository {
  BookshelfRepository._(this._library);
  final ContentLibrary _library;
  Future<LibraryItem> add({required String title, String? author, required ContentKind kind, required ContentLibraryIngest source}) =>
      _library._trace(
        operation: 'bookshelfAdd',
        contentKind: kind.code,
        itemCount: 1,
        action: () => _library._withStorageMaintenance(() => _add(title: title, author: author, kind: kind, source: source)),
      );

  /// Adds or returns the item identified by a typed source reference.
  ///
  /// Feature adapters use this public operation instead of seeing the
  /// Runtime-facing ingest payload used by the persistence implementation.
  Future<LibraryItem> addFromSource(BookshelfAddRequest request) => add(
    title: request.title,
    author: request.author,
    kind: request.kind,
    source: ContentLibraryIngest(
      pluginId: request.pluginId,
      producerPluginVersion: request.pluginVersion,
      dataVersion: 1,
      opaqueData: <String, Object?>{
        'remoteBookId': request.remoteContentId,
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
        if (request.labels.isNotEmpty) 'labels': request.labels,
      },
    ),
  );

  Future<Page<LibraryItem>> list(LibraryQuery query) => _library._trace(
    operation: 'bookshelfList',
    itemCount: query.limit,
    action: () => _list(query),
    resultCount: (result) => result.items.length,
    resultState: (result) => result.items.isEmpty ? 'empty' : 'content',
  );

  /// Reads one shelf item by its app-owned stable identifier.
  Future<LibraryItem?> get(LibraryItemId id) => _library._trace(
    operation: 'bookshelfGet',
    itemCount: 1,
    action: () async {
      final record = await _library._persistence.metadataRecords.read(id: id.value, scope: _scope);
      return record == null || record.recordKind != _itemKind ? null : _item(record);
    },
    resultCount: (result) => result == null ? 0 : 1,
    resultState: (result) => result == null ? 'empty' : 'content',
  );

  /// Reads the durable cover owned by [id], if the first-load fetch succeeded.
  ///
  /// The file object path remains private to the app-owned persistence layer.
  Future<List<int>?> readCover(LibraryItemId id) => _library._trace(
    operation: 'bookshelfCoverRead',
    contentKind: 'image',
    itemCount: 1,
    action: () => _library._persistence.fileObjects.readCoverBytes(id.value),
    resultCount: (result) => result == null ? 0 : 1,
    resultState: (result) => result == null ? 'miss' : 'hit',
  );

  /// Persists one validated cover after it has been fetched from its source.
  Future<void> saveCover({required LibraryItemId id, required List<int> bytes, required String mimeType}) => _library._trace(
    operation: 'bookshelfCoverSave',
    contentKind: 'image',
    itemCount: 1,
    bytes: bytes.length,
    action: () async {
      _validateCover(bytes, mimeType);
      await _library._persistence.fileObjects.commitCoverBytes(itemId: id.value, bytes: bytes, mimeType: mimeType);
    },
  );

  Future<void> remove(LibraryItemId id, LibraryRemovalPolicy policy) => _library._trace(
    operation: 'bookshelfRemove',
    itemCount: 1,
    action: () => _library._withStorageMaintenance(() => _remove(id, policy)),
  );

  /// Changes only the local shelf visibility for one item.
  ///
  /// The retained catalog, cached content, covers, and reading progress are
  /// deliberately unaffected.
  Future<void> setVisibility(LibraryItemId id, LibraryVisibility visibility) =>
      _library._trace(operation: 'bookshelfSetVisibility', itemCount: 1, action: () => _setVisibility(id, visibility));

  Future<LibraryItem> _add({required String title, String? author, required ContentKind kind, required ContentLibraryIngest source}) async {
    _safeText(title);
    final identity = '${source.pluginId}:${source.opaqueData['remoteBookId'] ?? title}';
    return _library._persistence.metadataRecords.transaction(() async {
      final existing = await _library._persistence.metadataRecords.list(
        RecordQuery(recordKind: _itemKind, scope: _scope, identityKey: identity, limit: 1),
      );
      final shelfSummary = _shelfSummary(source);
      if (existing.records.isNotEmpty) {
        final previous = existing.records.single;
        final updated = await _library._persistence.metadataRecords.update(
          previous: previous,
          document: <String, Object?>{
            ...previous.document,
            'title': title,
            'author': ?author,
            'summary': <String, Object?>{..._summaryFromDocument(previous.document), ...shelfSummary},
          },
        );
        return _item(updated);
      }
      final id = _id();
      final document = {'title': title, 'author': ?author, 'kind': kind.code, 'plugin': _plugin(source), 'summary': shelfSummary};
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
    });
  }

  Future<Page<LibraryItem>> _list(LibraryQuery query) async {
    final page = await _library._persistence.metadataRecords.list(
      RecordQuery(recordKind: _itemKind, scope: _scope, stateKey: query.state, after: _cursor(query.after), limit: query.limit),
    );
    final items = page.records
        .map(_item)
        .where((item) => query.visibility == null || item.visibility == query.visibility)
        .toList(growable: false);
    return Page(items: items, nextCursor: _cursorText(page.nextCursor));
  }

  Future<void> _setVisibility(LibraryItemId id, LibraryVisibility visibility) async {
    final record = await _library._persistence.metadataRecords.read(id: id.value, scope: _scope);
    if (record == null || record.recordKind != _itemKind) return;
    if (_visibilityFromDocument(record.document) == visibility) return;
    await _library._persistence.metadataRecords.update(
      previous: record,
      document: <String, Object?>{...record.document, 'visibility': visibility.wireValue},
    );
  }

  Future<void> _remove(LibraryItemId id, LibraryRemovalPolicy policy) async {
    final record = await _library._persistence.metadataRecords.read(id: id.value, scope: _scope);
    if (record == null) return;
    final records = <RecordEnvelope>[record];
    for (final kind in [_readingProgressKind, _bookmarkKind, _mangaProgressKind, _mangaBookmarkKind]) {
      final related = await _library._persistence.metadataRecords.list(
        RecordQuery(recordKind: kind, scope: _scope, parentId: id.value, limit: 1000),
      );
      records.addAll(related.records);
    }
    await _library._persistence.metadataRecords.transaction(() async {
      for (var offset = 0; offset < records.length; offset += PersistenceRecordStore.maxWriteBatchSize) {
        final end = min(offset + PersistenceRecordStore.maxWriteBatchSize, records.length);
        await _library._persistence.metadataRecords.deleteBatch(records.sublist(offset, end));
      }
    }); /* retained catalog/content is reclaimed only by explicit maintenance */
    if (policy == LibraryRemovalPolicy.removeIncludingUnreferencedContent) {
      await _library.storageMaintenance._clearLocked();
    }
    try {
      if (record.document['kind'] == ContentKind.manga.code) {
        await _library._persistence.fileObjects.deleteMangaAssets(id.value);
      }
      await _library._persistence.fileObjects.deleteCover(id.value);
    } on Object {
      // Metadata is already authoritative. A later cache clear can retry files.
    }
  }
}

/// Typed, metadata-only LAN synchronization for source-bound shelf items.
///
/// This repository intentionally has no import/export format or persistence
/// envelope API.  The caller supplies already typed snapshots and plugin
/// availability; all writes are owned by [ContentLibrary].
final class LibrarySyncRepository {
  LibrarySyncRepository._(this._library);
  final ContentLibrary _library;

  Future<LibrarySyncSnapshot> createSnapshot() => _library._trace(
    operation: 'syncSnapshotCreate',
    itemCount: 100,
    action: _createSnapshot,
    resultCount: (result) => result.items.length,
    resultState: (result) => result.items.isEmpty ? 'empty' : 'content',
  );

  Future<LibrarySyncSnapshot> _createSnapshot() async {
    final page = await _library.bookshelf.list(const LibraryQuery(limit: 100));
    final items = <LibrarySyncItem>[];
    var skipped = 0;
    for (final item in page.items) {
      final source = item.source;
      if (source == null) {
        skipped++;
        continue;
      }
      final localProgress = await _library.readingProgress.load(item.id);
      items.add(
        LibrarySyncItem(
          pluginId: source.pluginId,
          producerPluginVersion: source.pluginVersion,
          remoteContentId: source.remoteContentId,
          kind: item.kind,
          title: item.title,
          author: item.author,
          coverUrl: item.coverUrl,
          sourceName: item.sourceName,
          progress: localProgress == null ? null : LibrarySyncReadingProgress.fromLocal(localProgress),
        ),
      );
    }
    return LibrarySyncSnapshot(items: List<LibrarySyncItem>.unmodifiable(items), skippedSourceLessItems: skipped);
  }

  Future<LibrarySyncPreview> preview(LibrarySyncSnapshot snapshot, {required Set<String> availablePluginIds}) => _library._trace(
    operation: 'syncPreview',
    itemCount: snapshot.items.length,
    action: () => _preview(snapshot, availablePluginIds),
    resultCount: (result) => result.newItems.length + result.conflicts.length + result.blocked.length,
    resultState: (result) => result.blocked.isEmpty ? 'ready' : 'blocked',
  );

  Future<LibrarySyncPreview> _preview(LibrarySyncSnapshot snapshot, Set<String> availablePluginIds) async {
    final page = await _library.bookshelf.list(const LibraryQuery(limit: 100));
    final localByIdentity = <LibrarySyncIdentity, LibraryItem>{};
    for (final item in page.items) {
      final source = item.source;
      if (source != null) {
        localByIdentity[LibrarySyncIdentity(pluginId: source.pluginId, remoteContentId: source.remoteContentId)] = item;
      }
    }
    final progress = await _library.readingProgress.loadMany(localByIdentity.values.map((item) => item.id));
    final progressById = <String, LibraryReadingProgress>{for (final value in progress) value.itemId.value: value};
    final newItems = <LibrarySyncItem>[];
    final conflicts = <LibrarySyncConflict>[];
    final blocked = <LibrarySyncBlockedItem>[];
    final seen = <LibrarySyncIdentity>{};
    if (snapshot.version != 1 || snapshot.items.length > 100) {
      return LibrarySyncPreview(
        snapshot: snapshot,
        newItems: const <LibrarySyncItem>[],
        conflicts: const <LibrarySyncConflict>[],
        blocked: List<LibrarySyncBlockedItem>.unmodifiable(
          snapshot.items.map((item) => LibrarySyncBlockedItem(item: item, reason: LibrarySyncBlockedReason.invalidEntry)),
        ),
        skippedSourceLessItems: snapshot.skippedSourceLessItems,
      );
    }
    for (final item in snapshot.items) {
      if (!_validItem(item) || !seen.add(item.identity)) {
        blocked.add(LibrarySyncBlockedItem(item: item, reason: LibrarySyncBlockedReason.invalidEntry));
        continue;
      }
      if (!availablePluginIds.contains(item.pluginId)) {
        blocked.add(LibrarySyncBlockedItem(item: item, reason: LibrarySyncBlockedReason.missingPlugin));
        continue;
      }
      final local = localByIdentity[item.identity];
      if (local == null) {
        newItems.add(item);
        continue;
      }
      final localProgress = progressById[local.id.value];
      if (_sameSyncProjection(local, item, localProgress)) continue;
      conflicts.add(
        LibrarySyncConflict(
          identity: item.identity,
          local: local,
          sender: item,
          expectedLocalRevision: local.revision,
          localProgress: localProgress == null ? null : LibrarySyncReadingProgress.fromLocal(localProgress),
        ),
      );
    }
    return LibrarySyncPreview(
      snapshot: snapshot,
      newItems: List<LibrarySyncItem>.unmodifiable(newItems),
      conflicts: List<LibrarySyncConflict>.unmodifiable(conflicts),
      blocked: List<LibrarySyncBlockedItem>.unmodifiable(blocked),
      skippedSourceLessItems: snapshot.skippedSourceLessItems,
    );
  }

  Future<LibrarySyncApplyResult> apply(
    LibrarySyncSnapshot snapshot, {
    required LibrarySyncPreview preview,
    required Map<LibrarySyncIdentity, LibrarySyncConflictChoice> choices,
  }) => _library._trace(
    operation: 'syncApply',
    itemCount: snapshot.items.length,
    action: () => _apply(snapshot, preview: preview, choices: choices),
    resultCount: (result) => result.addedItems + result.updatedItems,
    resultState: (result) => result.code.name,
  );

  Future<LibrarySyncApplyResult> _apply(
    LibrarySyncSnapshot snapshot, {
    required LibrarySyncPreview preview,
    required Map<LibrarySyncIdentity, LibrarySyncConflictChoice> choices,
  }) async {
    if (!_validSnapshot(snapshot) || !identical(preview.snapshot, snapshot)) {
      return const LibrarySyncApplyResult(code: LibrarySyncResultCode.invalidRequest);
    }
    final conflictIdentities = preview.conflicts.map((item) => item.identity).toSet();
    if (choices.keys.any((key) => !conflictIdentities.contains(key)) ||
        choices.length != conflictIdentities.length ||
        preview.blocked.any((item) => !_validItem(item.item))) {
      return const LibrarySyncApplyResult(code: LibrarySyncResultCode.invalidRequest);
    }
    final blockedIdentities = preview.blocked.map((item) => item.item.identity).toSet();
    final validItems = _validSnapshotItems(snapshot).where((item) => !blockedIdentities.contains(item.identity)).toList(growable: false);
    final page = await _library.bookshelf.list(const LibraryQuery(limit: 100));
    if (page.items.length + preview.newItems.length > 100) {
      return const LibrarySyncApplyResult(code: LibrarySyncResultCode.invalidRequest);
    }
    try {
      return await _library._persistence.metadataRecords.transaction(() async {
        final records = await _library._persistence.metadataRecords.list(
          const RecordQuery(recordKind: _itemKind, scope: _scope, limit: 100),
        );
        final localRecords = <LibrarySyncIdentity, RecordEnvelope>{};
        for (final record in records.records) {
          final item = _item(record);
          final source = item.source;
          if (source != null) {
            localRecords[LibrarySyncIdentity(pluginId: source.pluginId, remoteContentId: source.remoteContentId)] = record;
          }
        }
        for (final conflict in preview.conflicts) {
          final record = localRecords[conflict.identity];
          if (record == null || record.revision != conflict.expectedLocalRevision) {
            throw const _SyncStaleRevision();
          }
        }
        final progressRecords = await _library._persistence.metadataRecords.listByIdentityKeys(
          recordKind: _readingProgressKind,
          scope: _scope,
          identityKeys: localRecords.values.map((record) => record.id),
        );
        final progressById = <String, RecordEnvelope>{
          for (final record in progressRecords)
            if (record.identityKey != null) record.identityKey!: record,
        };
        var added = 0;
        var updated = 0;
        var progressApplied = 0;
        for (final sender in validItems) {
          final identity = sender.identity;
          var record = localRecords[identity];
          LibrarySyncConflict? conflict;
          for (final value in preview.conflicts) {
            if (value.identity == identity) {
              conflict = value;
              break;
            }
          }
          final isNew = record == null;
          if (record == null) {
            final itemId = _id();
            final itemRecord = await _library._persistence.metadataRecords.create(
              RecordDraft(
                id: itemId,
                recordKind: _itemKind,
                scope: _scope,
                identityKey: _syncIdentityKey(identity),
                orderKey: itemId,
                stateKey: 'active',
                document: _syncItemDocument(sender),
              ),
            );
            await _library._persistence.metadataRecords.create(
              RecordDraft(
                id: _id(),
                recordKind: _bindingKind,
                scope: _scope,
                parentId: itemId,
                identityKey: _syncIdentityKey(identity),
                orderKey: '0',
                stateKey: 'available',
                document: {'itemId': itemId, 'plugin': _syncPlugin(sender)},
              ),
            );
            record = itemRecord;
            localRecords[identity] = itemRecord;
            added++;
          } else if (conflict != null && choices[identity] != LibrarySyncConflictChoice.keepLocal) {
            final merged = _syncItemDocument(sender, previous: record.document);
            if (!_sameDocumentProjection(record.document, merged)) updated++;
            record = await _library._persistence.metadataRecords.update(previous: record, document: merged);
            localRecords[identity] = record;
          }
          final choice = choices[identity];
          final incomingProgress = sender.progress;
          final currentProgress = progressById[record.id];
          final shouldApplyProgress =
              incomingProgress != null &&
              (isNew ||
                  choice == LibrarySyncConflictChoice.useSender ||
                  (choice == LibrarySyncConflictChoice.smartMerge &&
                      (currentProgress == null || incomingProgress.updatedAtUtc.isAfter(_progressDate(currentProgress)))));
          if (shouldApplyProgress) {
            final localProgress = incomingProgress.toLocal(LibraryItemId(record.id));
            final document = _readingProgressDocument(localProgress);
            if (currentProgress == null) {
              final progressRecord = await _library._persistence.metadataRecords.create(
                RecordDraft(
                  id: _id(),
                  recordKind: _readingProgressKind,
                  scope: _scope,
                  parentId: record.id,
                  identityKey: record.id,
                  orderKey: _timestampOrderKey(localProgress.updatedAtUtc),
                  stateKey: 'active',
                  document: document,
                ),
              );
              progressById[record.id] = progressRecord;
            } else {
              progressById[record.id] = await _library._persistence.metadataRecords.update(previous: currentProgress, document: document);
            }
            progressApplied++;
          }
        }
        return LibrarySyncApplyResult(
          code: LibrarySyncResultCode.applied,
          addedItems: added,
          updatedItems: updated,
          progressApplied: progressApplied,
          skippedItems: snapshot.skippedSourceLessItems,
          blockedItems: preview.blocked.length,
        );
      });
    } on _SyncStaleRevision {
      return const LibrarySyncApplyResult(code: LibrarySyncResultCode.staleRevision);
    } on PersistenceConflictError {
      return const LibrarySyncApplyResult(code: LibrarySyncResultCode.staleRevision);
    }
  }
}

final class _SyncStaleRevision implements Exception {
  const _SyncStaleRevision();
}

typedef ContentLibrarySyncRepository = LibrarySyncRepository;

bool _validSnapshot(LibrarySyncSnapshot snapshot) =>
    snapshot.version == 1 &&
    snapshot.skippedSourceLessItems >= 0 &&
    snapshot.skippedSourceLessItems <= 100 &&
    snapshot.items.length <= 100 &&
    _validSnapshotItems(snapshot).length == snapshot.items.length;

List<LibrarySyncItem> _validSnapshotItems(LibrarySyncSnapshot snapshot) {
  final seen = <LibrarySyncIdentity>{};
  final result = <LibrarySyncItem>[];
  for (final item in snapshot.items) {
    if (!_validItem(item) || !seen.add(item.identity)) continue;
    result.add(item);
  }
  return result;
}

bool _validItem(LibrarySyncItem item) =>
    _safeSyncString(item.pluginId) &&
    _safeSyncString(item.producerPluginVersion) &&
    _safeSyncString(item.remoteContentId) &&
    _safeSyncString(item.title) &&
    (item.author == null || _safeSyncString(item.author!)) &&
    (item.sourceName == null || _safeSyncString(item.sourceName!)) &&
    (item.coverUrl == null || _safeSyncString(item.coverUrl.toString())) &&
    (item.progress == null || _validProgress(item.progress!));

bool _safeSyncString(String value) => value.isNotEmpty && value.length <= 32768 && !value.contains('\u0000');

bool _validProgress(LibrarySyncReadingProgress value) =>
    _safeSyncString(value.chapterId) &&
    _safeSyncString(value.paragraphId) &&
    value.characterOffset >= 0 &&
    value.chapterIndex >= 0 &&
    value.chapterFraction.isFinite &&
    value.chapterFraction >= 0 &&
    value.chapterFraction <= 1 &&
    value.bookFraction.isFinite &&
    value.bookFraction >= 0 &&
    value.bookFraction <= 1 &&
    value.totalReadingSeconds >= 0;

bool _sameSyncProjection(LibraryItem local, LibrarySyncItem sender, LibraryReadingProgress? localProgress) {
  final source = local.source;
  if (source == null ||
      source.pluginId != sender.pluginId ||
      source.remoteContentId != sender.remoteContentId ||
      local.kind != sender.kind ||
      local.title != sender.title ||
      local.author != sender.author ||
      local.coverUrl?.toString() != sender.coverUrl?.toString() ||
      local.sourceName != sender.sourceName) {
    return false;
  }
  final incoming = sender.progress;
  if (localProgress == null || incoming == null) {
    return localProgress == null && incoming == null;
  }
  return _sameProgress(localProgress, incoming);
}

bool _sameProgress(LibraryReadingProgress local, LibrarySyncReadingProgress incoming) =>
    local.chapterId == incoming.chapterId &&
    local.paragraphId == incoming.paragraphId &&
    local.characterOffset == incoming.characterOffset &&
    local.chapterIndex == incoming.chapterIndex &&
    local.chapterFraction == incoming.chapterFraction &&
    local.bookFraction == incoming.bookFraction &&
    local.updatedAtUtc.toUtc() == incoming.updatedAtUtc.toUtc() &&
    local.totalReadingSeconds == incoming.totalReadingSeconds;

String _syncIdentityKey(LibrarySyncIdentity identity) => '${identity.pluginId}:${identity.remoteContentId}';

Map<String, Object?> _syncPlugin(LibrarySyncItem item) => <String, Object?>{
  'pluginId': item.pluginId,
  'producerPluginVersion': item.producerPluginVersion,
  'dataVersion': 1,
  'data': <String, Object?>{'remoteBookId': item.remoteContentId},
};

Map<String, Object?> _syncItemDocument(LibrarySyncItem item, {Map<String, Object?>? previous}) {
  final document = <String, Object?>{...?previous, 'title': item.title, 'kind': item.kind.code, 'plugin': _syncPlugin(item)};
  if (item.author == null) {
    document.remove('author');
  } else {
    document['author'] = item.author;
  }
  final summary = previous == null ? <String, Object?>{} : _summaryFromDocument(previous);
  _setSyncSummary(summary, 'coverUrl', item.coverUrl?.toString());
  _setSyncSummary(summary, 'sourceName', item.sourceName);
  document['summary'] = summary;
  return document;
}

void _setSyncSummary(Map<String, Object?> summary, String key, String? value) {
  if (value == null || value.isEmpty) {
    summary.remove(key);
  } else {
    summary[key] = value;
  }
}

bool _sameDocumentProjection(Map<String, Object?> previous, Map<String, Object?> next) {
  final oldSummary = _summaryFromDocument(previous);
  final newSummary = _summaryFromDocument(next);
  return previous['title'] == next['title'] &&
      previous['author'] == next['author'] &&
      previous['kind'] == next['kind'] &&
      oldSummary['coverUrl'] == newSummary['coverUrl'] &&
      oldSummary['sourceName'] == newSummary['sourceName'] &&
      (previous['plugin'] as Map?)?['producerPluginVersion'] == (next['plugin'] as Map?)?['producerPluginVersion'];
}

DateTime _progressDate(RecordEnvelope record) {
  final value = record.document['updatedAtUtc'];
  return value is String
      ? DateTime.tryParse(value)?.toUtc() ?? DateTime.fromMillisecondsSinceEpoch(0)
      : DateTime.fromMillisecondsSinceEpoch(0);
}

/// App-owned, cross-feature persistence for regenerable source covers.
///
/// Search, discovery, detail and bookshelf adapters all address the same
/// source cover through [CoverKey]. The repository exposes bytes only; file
/// paths and eviction details remain inside the persistence boundary.
