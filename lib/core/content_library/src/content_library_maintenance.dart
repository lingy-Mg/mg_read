/// Content Library 数据库缓存扫描、清理与压缩。
///
/// 扫描只依据当前书架与 active catalog 引用；清理在共享维护屏障内重新扫描，
/// 先原子删除无效 metadata，再幂等删除无引用 immutable content objects。
part of 'content_library.dart';

final class StorageMaintenanceRepository {
  StorageMaintenanceRepository._(this._library);

  final ContentLibrary _library;

  Future<StorageCleanupPreview> inspect() => _library._trace(
    operation: 'storageMaintenanceInspect',
    action: () => _library._withStorageMaintenance(() async => (await _inspectLocked()).preview),
  );

  Future<StorageCleanupResult> clearAll() =>
      _library._trace(operation: 'storageMaintenanceClear', action: () => _library._withStorageMaintenance(_clearLocked));

  Future<StorageCompactionResult> compact() =>
      _library._trace(operation: 'storageMaintenanceCompact', action: () => _library._withStorageMaintenance(_compactLocked));

  Future<StorageCleanupResult> _clearLocked() async {
    final inspection = await _inspectLocked();
    final metadata = inspection.metadataCandidates;
    if (metadata.isNotEmpty) {
      await _library._persistence.metadataRecords.transaction(() async {
        for (var offset = 0; offset < metadata.length; offset += PersistenceRecordStore.maxWriteBatchSize) {
          final end = min(offset + PersistenceRecordStore.maxWriteBatchSize, metadata.length);
          await _library._persistence.metadataRecords.deleteBatch(metadata.sublist(offset, end));
        }
      });
    }

    var deletedObjects = 0;
    var deletedBytes = 0;
    try {
      for (var offset = 0; offset < inspection.orphanObjects.length; offset += 500) {
        final end = min(offset + 500, inspection.orphanObjects.length);
        final batch = inspection.orphanObjects.sublist(offset, end);
        final affected = await _library._persistence.contentObjects.deleteMany(batch.map((object) => object.objectId));
        deletedObjects += affected;
        deletedBytes += batch.fold<int>(0, (sum, object) => sum + object.byteLength);
      }
    } on Object {
      return StorageCleanupResult(
        staleCatalogRecords: inspection.preview.staleCatalogRecords,
        detachedMetadataRecords: inspection.preview.detachedMetadataRecords,
        deletedContentObjects: deletedObjects,
        releasedLogicalBytes: inspection.metadataBytes + deletedBytes,
        isPartial: true,
        failureCode: StorageMaintenanceFailureCode.contentDeleteFailed,
      );
    }
    return StorageCleanupResult(
      staleCatalogRecords: inspection.preview.staleCatalogRecords,
      detachedMetadataRecords: inspection.preview.detachedMetadataRecords,
      deletedContentObjects: deletedObjects,
      releasedLogicalBytes: inspection.metadataBytes + deletedBytes,
    );
  }

  Future<StorageCompactionResult> _compactLocked() async {
    final metadataBefore = await _library._persistence.metadataRecords.storageStats();
    final contentBefore = await _library._persistence.contentObjects.storageStats();
    await _library._persistence.metadataRecords.compact();
    await _library._persistence.contentObjects.compact();
    final metadataAfter = await _library._persistence.metadataRecords.storageStats();
    final contentAfter = await _library._persistence.contentObjects.storageStats();
    final before = metadataBefore.allocatedBytes + contentBefore.allocatedBytes;
    final after = metadataAfter.allocatedBytes + contentAfter.allocatedBytes;
    return StorageCompactionResult(allocatedBytesBefore: before, allocatedBytesAfter: after, releasedBytes: max(0, before - after));
  }

  Future<_StorageInspection> _inspectLocked() async {
    final items = await _loadRecords(_itemKind);
    final itemSnapshots = <String, String?>{
      for (final item in items) item.id: item.document['activeSnapshotId'] is String ? item.document['activeSnapshotId']! as String : null,
    };
    final activeItemIds = itemSnapshots.keys.toSet();
    final staleCatalog = <RecordEnvelope>[];
    final detached = <RecordEnvelope>[];
    final retainedCatalog = <RecordEnvelope>[];
    final catalog = await _loadRecords(_entryKind);
    for (final entry in catalog) {
      final parentId = entry.parentId;
      if (parentId == null || !activeItemIds.contains(parentId)) {
        detached.add(entry);
        continue;
      }
      final activeSnapshot = itemSnapshots[parentId];
      if (activeSnapshot == null || entry.stateKey != 'pending:$activeSnapshot') {
        staleCatalog.add(entry);
      } else {
        retainedCatalog.add(entry);
      }
    }
    for (final kind in <String>[_bindingKind, _readingProgressKind, _bookmarkKind, _mangaProgressKind, _mangaBookmarkKind]) {
      for (final record in await _loadRecords(kind)) {
        final parentId = record.parentId;
        if (parentId == null || !activeItemIds.contains(parentId)) detached.add(record);
      }
    }

    final liveContentReferences = <String>{
      for (final entry in retainedCatalog)
        if (entry.document['contentReference'] case final String reference when reference.isNotEmpty) reference,
    };
    final orphanObjects = <StoredContentObjectInfo>[];
    String? afterObjectId;
    do {
      final page = await _library._persistence.contentObjects.listInfo(afterObjectId: afterObjectId);
      for (final object in page.objects) {
        if (!liveContentReferences.contains(object.objectId)) orphanObjects.add(object);
      }
      afterObjectId = page.nextObjectId;
    } while (afterObjectId != null);

    final metadataCandidates = <RecordEnvelope>[...staleCatalog, ...detached];
    final metadataBytes = metadataCandidates.fold<int>(0, (sum, record) => sum + utf8.encode(jsonEncode(record.document)).length);
    final orphanBytes = orphanObjects.fold<int>(0, (sum, object) => sum + object.byteLength);
    final metadataStats = await _library._persistence.metadataRecords.storageStats();
    final contentStats = await _library._persistence.contentObjects.storageStats();
    return _StorageInspection(
      preview: StorageCleanupPreview(
        staleCatalogRecords: staleCatalog.length,
        detachedMetadataRecords: detached.length,
        orphanContentObjects: orphanObjects.length,
        reclaimableContentBytes: orphanBytes,
        estimatedReclaimableBytes: metadataBytes + orphanBytes,
        compactableDatabaseBytes: metadataStats.reclaimableBytes + contentStats.reclaimableBytes,
      ),
      metadataCandidates: metadataCandidates,
      orphanObjects: orphanObjects,
      metadataBytes: metadataBytes,
    );
  }

  Future<List<RecordEnvelope>> _loadRecords(String recordKind) async {
    final records = <RecordEnvelope>[];
    RecordCursor? cursor;
    do {
      final page = await _library._persistence.metadataRecords.list(
        RecordQuery(recordKind: recordKind, scope: _scope, after: cursor, limit: 1000),
      );
      records.addAll(page.records);
      cursor = page.nextCursor;
    } while (cursor != null);
    return records;
  }
}

final class StorageCleanupPreview {
  const StorageCleanupPreview({
    required this.staleCatalogRecords,
    required this.detachedMetadataRecords,
    required this.orphanContentObjects,
    required this.reclaimableContentBytes,
    required this.estimatedReclaimableBytes,
    required this.compactableDatabaseBytes,
  });

  final int staleCatalogRecords;
  final int detachedMetadataRecords;
  final int orphanContentObjects;
  final int reclaimableContentBytes;
  final int estimatedReclaimableBytes;
  final int compactableDatabaseBytes;

  bool get isEmpty => staleCatalogRecords == 0 && detachedMetadataRecords == 0 && orphanContentObjects == 0;
}

final class StorageCleanupResult {
  const StorageCleanupResult({
    required this.staleCatalogRecords,
    required this.detachedMetadataRecords,
    required this.deletedContentObjects,
    required this.releasedLogicalBytes,
    this.isPartial = false,
    this.failureCode,
  });

  final int staleCatalogRecords;
  final int detachedMetadataRecords;
  final int deletedContentObjects;
  final int releasedLogicalBytes;
  final bool isPartial;
  final StorageMaintenanceFailureCode? failureCode;
}

enum StorageMaintenanceFailureCode { contentDeleteFailed }

final class StorageCompactionResult {
  const StorageCompactionResult({required this.allocatedBytesBefore, required this.allocatedBytesAfter, required this.releasedBytes});

  final int allocatedBytesBefore;
  final int allocatedBytesAfter;
  final int releasedBytes;
}

final class _StorageInspection {
  const _StorageInspection({
    required this.preview,
    required this.metadataCandidates,
    required this.orphanObjects,
    required this.metadataBytes,
  });

  final StorageCleanupPreview preview;
  final List<RecordEnvelope> metadataCandidates;
  final List<StoredContentObjectInfo> orphanObjects;
  final int metadataBytes;
}

final class _ContentLibraryMaintenanceBarrier {
  final Object _zoneKey = Object();
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() action) {
    if (Zone.current[_zoneKey] == this) return action();
    final previous = _tail;
    final completed = Completer<void>();
    _tail = completed.future;
    return previous.then((_) => runZoned(action, zoneValues: <Object, Object>{_zoneKey: this})).whenComplete(completed.complete);
  }
}
