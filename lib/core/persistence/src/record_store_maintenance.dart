/// metadata record 的有界 CAS 批量删除、空间统计与显式压缩。
///
/// 所有操作复用 PersistenceRecordStore 的生命周期、诊断和后台 SQLite 执行器。
part of 'record_store.dart';

extension PersistenceRecordStoreMaintenance on PersistenceRecordStore {
  Future<void> _deleteBatch(List<RecordEnvelope> previous) async {
    _ensureOpen();
    _validateWriteBatchSize(previous.length);
    if (previous.isEmpty) return;
    final identities = <(String, ScopeKey)>{};
    for (final record in previous) {
      if (record.id.isEmpty || record.scope.kind.isEmpty || record.scope.id.isEmpty || record.revision < 1) {
        throw const PersistenceValidationError('CAS deletes require valid IDs, scope, and revision.');
      }
      if (!identities.add((record.id, record.scope))) {
        throw const PersistenceValidationError('A CAS delete batch cannot contain the same record twice.');
      }
    }
    final where = List<String>.filled(previous.length, '(record_id = ? AND scope_kind = ? AND scope_id = ? AND revision = ?)').join(' OR ');
    await _database.transaction(() async {
      final affected = await _database.customUpdate(
        'DELETE FROM metadata_records WHERE $where',
        variables: <Variable<Object>>[
          for (final record in previous) ...<Variable<Object>>[
            Variable.withString(record.id),
            Variable.withString(record.scope.kind),
            Variable.withString(record.scope.id),
            Variable.withInt(record.revision),
          ],
        ],
        updates: {},
      );
      if (affected != previous.length) throw const PersistenceConflictError();
    });
  }

  Future<DatabaseStorageStats> storageStats() => _instrument(
    operation: 'storageStats',
    action: () async {
      _ensureOpen();
      final pageCount = await _pragmaInt('page_count');
      final freePages = await _pragmaInt('freelist_count');
      final pageSize = await _pragmaInt('page_size');
      return DatabaseStorageStats(allocatedBytes: pageCount * pageSize, reclaimableBytes: freePages * pageSize);
    },
  );

  Future<void> compact() => _instrument(
    operation: 'compact',
    action: () async {
      _ensureOpen();
      await _database.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
      await _database.customStatement('VACUUM');
      await _database.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
    },
  );

  /// Test-only evidence for connection-level SQLite configuration.
  Future<Object?> debugPragmaForTest(String pragma) => _withOperation(() async {
    _ensureOpen();
    if (!RegExp(r'^[a-z_]+$').hasMatch(pragma)) throw ArgumentError.value(pragma, 'pragma');
    final row = await _database.customSelect('PRAGMA $pragma').getSingle();
    return row.data.values.single;
  });

  Future<int> _pragmaInt(String pragma) async {
    final row = await _database.customSelect('PRAGMA $pragma').getSingle();
    return row.data.values.single as int;
  }
}
