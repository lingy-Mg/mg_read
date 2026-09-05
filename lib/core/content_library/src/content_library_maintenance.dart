/// Content Library 数据库缓存扫描、清理与压缩。
///
/// 扫描只依据章节正文引用；清理在共享维护屏障内重新扫描，再幂等删除
/// 无引用 immutable content objects。追加目录没有可清理的历史版本。
part of 'content_library.dart';

final class _StorageMaintenanceOperations {
  _StorageMaintenanceOperations(this._library);

  final ContentLibrary _library;

  Future<StorageCleanupPreview> inspect() => _library._trace(
    operation: 'storageMaintenanceInspect',
    action: () => _library._withStorageMaintenance(() async => (await _inspectLocked()).preview),
  );

  Future<StorageCleanupResult> clearAll() =>
      _library._trace(operation: 'storageMaintenanceClear', action: () => _library._withStorageMaintenance(clearLocked));

  Future<StorageCompactionResult> compact() =>
      _library._trace(operation: 'storageMaintenanceCompact', action: () => _library._withStorageMaintenance(_compactLocked));

  Future<StorageCleanupResult> clearLocked() async {
    final inspection = await _inspectLocked();
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
        deletedContentObjects: deletedObjects,
        releasedLogicalBytes: deletedBytes,
        isPartial: true,
        failureCode: StorageMaintenanceFailureCode.contentDeleteFailed,
      );
    }
    return StorageCleanupResult(deletedContentObjects: deletedObjects, releasedLogicalBytes: deletedBytes);
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
    final liveContentReferences = await _library._persistence.metadataRecords.contentLibrary.referencedContentObjects();
    final orphanObjects = <StoredContentObjectInfo>[];
    String? afterObjectId;
    do {
      final page = await _library._persistence.contentObjects.listInfo(afterObjectId: afterObjectId);
      for (final object in page.objects) {
        if (!liveContentReferences.contains(object.objectId)) orphanObjects.add(object);
      }
      afterObjectId = page.nextObjectId;
    } while (afterObjectId != null);

    final orphanBytes = orphanObjects.fold<int>(0, (sum, object) => sum + object.byteLength);
    final metadataStats = await _library._persistence.metadataRecords.storageStats();
    final contentStats = await _library._persistence.contentObjects.storageStats();
    return _StorageInspection(
      preview: StorageCleanupPreview(
        orphanContentObjects: orphanObjects.length,
        reclaimableContentBytes: orphanBytes,
        estimatedReclaimableBytes: orphanBytes,
        compactableDatabaseBytes: metadataStats.reclaimableBytes + contentStats.reclaimableBytes,
      ),
      orphanObjects: orphanObjects,
    );
  }
}

final class StorageCleanupPreview {
  const StorageCleanupPreview({
    required this.orphanContentObjects,
    required this.reclaimableContentBytes,
    required this.estimatedReclaimableBytes,
    required this.compactableDatabaseBytes,
  });

  final int orphanContentObjects;
  final int reclaimableContentBytes;
  final int estimatedReclaimableBytes;
  final int compactableDatabaseBytes;

  bool get isEmpty => orphanContentObjects == 0;
}

final class StorageCleanupResult {
  const StorageCleanupResult({
    required this.deletedContentObjects,
    required this.releasedLogicalBytes,
    this.isPartial = false,
    this.failureCode,
  });

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
  const _StorageInspection({required this.preview, required this.orphanObjects});

  final StorageCleanupPreview preview;
  final List<StoredContentObjectInfo> orphanObjects;
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
