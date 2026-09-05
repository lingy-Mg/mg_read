part of 'content_library.dart';

final class _BookshelfOperations {
  _BookshelfOperations(this._library);
  final ContentLibrary _library;
  Future<LibraryItem> add(BookshelfAddRequest request) async {
    final result = await _library._trace(
      operation: 'bookshelfAdd',
      contentKind: request.kind.code,
      itemCount: 1,
      action: () => _library._withStorageMaintenance(() => _add(request)),
    );
    if (result.created) {
      _library._enqueueNotification(kind: LibraryNotificationKind.bookshelfAdded, title: result.item.title);
    }
    return result.item;
  }

  /// Adds or returns the item identified by a typed source reference.
  ///
  /// Feature adapters use this public operation instead of seeing the
  /// Runtime-facing ingest payload used by the persistence implementation.
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
      final row = await _library._persistence.metadataRecords.contentLibrary.readItem(id.value);
      return row == null ? null : _storedItem(row);
    },
    resultCount: (result) => result == null ? 0 : 1,
    resultState: (result) => result == null ? 'empty' : 'content',
  );

  Future<void> remove(LibraryItemId id, LibraryRemovalPolicy policy) async {
    final removed = await _library._trace(
      operation: 'bookshelfRemove',
      itemCount: 1,
      action: () => _library._withStorageMaintenance(() => _remove(id, policy)),
    );
    if (removed != null) {
      _library._enqueueNotification(kind: LibraryNotificationKind.bookshelfRemoved, title: removed.title);
    }
  }

  /// Changes only the local shelf visibility for one item.
  ///
  /// The retained catalog, cached content, covers, and reading progress are
  /// deliberately unaffected.
  Future<void> setVisibility(LibraryItemId id, LibraryVisibility visibility) =>
      _library._trace(operation: 'bookshelfSetVisibility', itemCount: 1, action: () => _setVisibility(id, visibility));

  Future<_BookshelfAddResult> _add(BookshelfAddRequest request) async {
    _safeText(request.title);
    final details = _shelfSummary(request);
    try {
      final result = await _library._persistence.metadataRecords.contentLibrary.putItem(
        itemId: _id(),
        contentKind: request.kind.code,
        title: request.title,
        author: request.author,
        visibility: LibraryVisibility.normal.wireValue,
        coverUrl: details['coverUrl'] as String?,
        sourceName: details['sourceName'] as String?,
        pluginId: request.pluginId,
        pluginVersion: request.pluginVersion,
        remoteItemId: request.remoteContentId,
        sourceChapterCount: details['chapterCount'] as int?,
        summaryExcerpt: _summaryExcerpt(details['description'] as String?),
        detailsJson: jsonEncode(details),
        maximumActiveItems: bookshelfMaxItemCount,
      );
      return _BookshelfAddResult(item: _storedItem(result.item), created: result.created);
    } on PersistenceCapacityError {
      throw const BookshelfCapacityExceededException(currentCount: bookshelfMaxItemCount, requestedNewItems: 1);
    }
  }

  Future<Page<LibraryItem>> _list(LibraryQuery query) async {
    if (query.after != null) return const Page(items: <LibraryItem>[]);
    final rows = await _library._persistence.metadataRecords.contentLibrary.listItems(
      visibility: query.visibility?.wireValue,
      limit: query.limit,
    );
    return Page(items: List<LibraryItem>.unmodifiable(rows.map(_storedItem)));
  }

  Future<void> _setVisibility(LibraryItemId id, LibraryVisibility visibility) async {
    await _library._persistence.metadataRecords.contentLibrary.setVisibility(id.value, visibility.wireValue);
  }

  Future<LibraryItem?> _remove(LibraryItemId id, LibraryRemovalPolicy policy) async {
    final row = await _library._persistence.metadataRecords.contentLibrary.readItem(id.value);
    if (row == null) return null;
    final removedItem = _storedItem(row);
    if (policy == LibraryRemovalPolicy.removeFromShelfKeepContent) {
      await _library._persistence.metadataRecords.contentLibrary.retainItem(id.value);
      return removedItem;
    }
    await _library._persistence.metadataRecords.contentLibrary.deleteItem(id.value);
    await _library._storageMaintenance.clearLocked();
    try {
      if (removedItem.kind == ContentKind.manga) {
        await _library._persistence.fileObjects.deleteMangaAssets(id.value);
      }
      await _library._persistence.fileObjects.deleteCover(id.value);
    } on Object {
      // Metadata is already authoritative. A later cache clear can retry files.
    }
    return removedItem;
  }
}

final class _BookshelfAddResult {
  const _BookshelfAddResult({required this.item, required this.created});

  final LibraryItem item;
  final bool created;
}

/// Typed, metadata-only LAN synchronization for source-bound shelf items.
///
/// This repository intentionally has no import/export format or persistence
/// envelope API.  The caller supplies already typed snapshots and plugin
/// availability; all writes are owned by [ContentLibrary].
final class _LibrarySyncOperations {
  _LibrarySyncOperations(this._library);
  final ContentLibrary _library;

  Future<LibrarySyncSnapshot> createSnapshot() => _library._trace(
    operation: 'syncSnapshotCreate',
    itemCount: bookshelfMaxItemCount,
    action: _createSnapshot,
    resultCount: (result) => result.items.length,
    resultState: (result) => result.items.isEmpty ? 'empty' : 'content',
  );

  Future<LibrarySyncSnapshot> _createSnapshot() async {
    final page = await _library._bookshelf.list(const LibraryQuery(limit: bookshelfMaxItemCount));
    final items = <LibrarySyncItem>[];
    for (final item in page.items) {
      final source = item.source;
      final localProgress = switch (await _library.loadProgress(item.id)) {
        final LibraryReadingProgress value => value,
        _ => null,
      };
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
    return LibrarySyncSnapshot(items: List<LibrarySyncItem>.unmodifiable(items));
  }

  Future<LibrarySyncPreview> preview(LibrarySyncSnapshot snapshot, {required Set<String> availablePluginIds}) => _library._trace(
    operation: 'syncPreview',
    itemCount: snapshot.items.length,
    action: () => _preview(snapshot, availablePluginIds),
    resultCount: (result) => result.newItems.length + result.conflicts.length + result.blocked.length,
    resultState: (result) => result.blocked.isEmpty ? 'ready' : 'blocked',
  );

  Future<LibrarySyncPreview> _preview(LibrarySyncSnapshot snapshot, Set<String> availablePluginIds) async {
    final page = await _library._bookshelf.list(const LibraryQuery(limit: bookshelfMaxItemCount));
    final localByIdentity = <LibrarySyncIdentity, LibraryItem>{};
    for (final item in page.items) {
      final source = item.source;
      localByIdentity[LibrarySyncIdentity(pluginId: source.pluginId, remoteContentId: source.remoteContentId)] = item;
    }
    final progress = await _library._loadProgressMany(localByIdentity.values.map((item) => item.id));
    final progressById = <String, LibraryReadingProgress>{
      for (final value in progress)
        if (value is LibraryReadingProgress) value.itemId.value: value,
    };
    final newItems = <LibrarySyncItem>[];
    final conflicts = <LibrarySyncConflict>[];
    final blocked = <LibrarySyncBlockedItem>[];
    final seen = <LibrarySyncIdentity>{};
    if (snapshot.version != 1 || snapshot.items.length > bookshelfMaxItemCount) {
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
    action: () => _library._withStorageMaintenance(() => _apply(snapshot, preview: preview, choices: choices)),
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
    final localPage = await _library._bookshelf.list(const LibraryQuery(limit: bookshelfMaxItemCount));
    final localByIdentity = <LibrarySyncIdentity, LibraryItem>{
      for (final item in localPage.items)
        LibrarySyncIdentity(pluginId: item.source.pluginId, remoteContentId: item.source.remoteContentId): item,
    };
    final requestedNewItems = validItems.where((item) => !localByIdentity.containsKey(item.identity)).length;
    if (localPage.items.length + requestedNewItems > bookshelfMaxItemCount) {
      throw BookshelfCapacityExceededException(currentCount: localPage.items.length, requestedNewItems: requestedNewItems);
    }
    for (final conflict in preview.conflicts) {
      if (localByIdentity[conflict.identity]?.revision != conflict.expectedLocalRevision) {
        return const LibrarySyncApplyResult(code: LibrarySyncResultCode.staleRevision);
      }
    }
    var added = 0;
    var updated = 0;
    var progressApplied = 0;
    for (final sender in validItems) {
      final identity = sender.identity;
      final local = localByIdentity[identity];
      final choice = choices[identity];
      if (local != null && choice == LibrarySyncConflictChoice.keepLocal) continue;
      final saved = await _library._bookshelf.add(_syncAddRequest(sender));
      if (local == null) {
        added++;
      } else {
        updated++;
      }
      final incoming = sender.progress;
      if (incoming == null) continue;
      final current = switch (await _library.loadProgress(saved.id)) {
        final LibraryReadingProgress value => value,
        _ => null,
      };
      if (local == null ||
          choice == LibrarySyncConflictChoice.useSender ||
          (choice == LibrarySyncConflictChoice.smartMerge && (current == null || incoming.updatedAtUtc.isAfter(current.updatedAtUtc)))) {
        await _library.saveProgress(incoming.toLocal(saved.id));
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
  }
}

BookshelfAddRequest _syncAddRequest(LibrarySyncItem item) => BookshelfAddRequest(
  pluginId: item.pluginId,
  pluginVersion: item.producerPluginVersion,
  remoteContentId: item.remoteContentId,
  kind: item.kind,
  title: item.title,
  author: item.author,
  coverUrl: item.coverUrl,
  sourceName: item.sourceName,
);

bool _validSnapshot(LibrarySyncSnapshot snapshot) =>
    snapshot.version == 1 &&
    snapshot.skippedSourceLessItems >= 0 &&
    snapshot.skippedSourceLessItems <= bookshelfMaxItemCount &&
    snapshot.items.length <= bookshelfMaxItemCount &&
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
  if (source.pluginId != sender.pluginId ||
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

/// App-owned, cross-feature persistence for regenerable source covers.
///
/// Search, discovery, detail and bookshelf adapters all address the same
/// source cover through [CoverKey]. The public API exposes bytes only; file
/// paths and eviction details remain inside the persistence boundary.
