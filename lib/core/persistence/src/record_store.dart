import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';

import 'json_codec.dart';
import 'persistence_error.dart';
import 'record.dart';

typedef UtcClock = DateTime Function();

final class PersistenceRecordStore {
  static const int maxWriteBatchSize = 128;

  PersistenceRecordStore._(
    this._database,
    this._registry,
    this._clock,
    this.databasePath,
  );

  final _PersistenceDatabase _database;
  final RecordDocumentRegistry _registry;
  final UtcClock _clock;
  final String databasePath;
  bool _closed = false;
  int? _lastCodecWorkerIsolateId;
  int _batchReadCount = 0;

  /// Native Drift hosts all SQL work on a dedicated background isolate.
  bool get usesBackgroundExecutor => true;

  /// Test evidence that JSON preparation ran outside the calling isolate.
  int? get lastCodecWorkerIsolateIdForTest => _lastCodecWorkerIsolateId;

  /// Test-only evidence that an ID set was read with one SQL statement.
  int get batchReadCountForTest => _batchReadCount;

  static Future<PersistenceRecordStore> open({
    required Directory dataRoot,
    required RecordDocumentRegistry registry,
    UtcClock clock = _utcNow,
  }) async {
    await dataRoot.create(recursive: true);
    final path = '${dataRoot.path}${Platform.pathSeparator}app_metadata.sqlite';
    final database = _PersistenceDatabase(
      NativeDatabase.createInBackground(File(path)),
    );
    await database.customStatement('''
      CREATE TABLE IF NOT EXISTS metadata_records (
        record_id TEXT PRIMARY KEY NOT NULL,
        record_kind TEXT NOT NULL,
        scope_kind TEXT NOT NULL,
        scope_id TEXT NOT NULL,
        parent_id TEXT,
        identity_key TEXT,
        order_key TEXT,
        state_key TEXT,
        format_version INTEGER NOT NULL,
        revision INTEGER NOT NULL,
        payload_json TEXT NOT NULL,
        created_at_utc INTEGER NOT NULL,
        updated_at_utc INTEGER NOT NULL
      )
    ''');
    await database.customStatement(
      'CREATE INDEX IF NOT EXISTS metadata_records_scope ON metadata_records(scope_kind, scope_id)',
    );
    await database.customStatement(
      'CREATE INDEX IF NOT EXISTS metadata_records_kind_scope ON metadata_records(record_kind, scope_kind, scope_id)',
    );
    await database.customStatement(
      'CREATE INDEX IF NOT EXISTS metadata_records_parent_order ON metadata_records(record_kind, scope_kind, scope_id, parent_id, order_key, record_id)',
    );
    await database.customStatement(
      'CREATE INDEX IF NOT EXISTS metadata_records_identity ON metadata_records(record_kind, scope_kind, scope_id, identity_key)',
    );
    await database.customStatement(
      'CREATE INDEX IF NOT EXISTS metadata_records_state_order ON metadata_records(record_kind, scope_kind, scope_id, state_key, order_key, record_id)',
    );
    return PersistenceRecordStore._(database, registry, clock, path);
  }

  Future<RecordEnvelope> create(RecordDraft draft) async {
    _ensureOpen();
    final prepared = await _prepareDraft(draft);
    try {
      return await _insertPreparedDraft(prepared);
    } catch (error) {
      if (error.toString().contains('UNIQUE constraint failed')) {
        throw const PersistenceConflictError();
      }
      rethrow;
    }
  }

  Future<RecordEnvelope?> read({
    required String id,
    required ScopeKey scope,
  }) async {
    _ensureOpen();
    final rows = await _database
        .customSelect(
          'SELECT * FROM metadata_records WHERE record_id = ? AND scope_kind = ? AND scope_id = ?',
          variables: [
            Variable.withString(id),
            Variable.withString(scope.kind),
            Variable.withString(scope.id),
          ],
        )
        .get();
    if (rows.isEmpty) return null;
    return _rowToEnvelope(rows.single.data);
  }

  Future<RecordReadBatchResult> readMany({
    required Iterable<String> ids,
    required ScopeKey scope,
  }) async {
    _ensureOpen();
    final requested = ids.toSet();
    if (requested.isEmpty) {
      return const RecordReadBatchResult(records: {}, failures: {});
    }
    if (requested.length > 900 || requested.any((id) => id.isEmpty)) {
      throw const PersistenceValidationError(
        'Batch reads require 1 to 900 non-empty record IDs.',
      );
    }
    _batchReadCount++;
    final placeholders = List.filled(requested.length, '?').join(', ');
    final rows = await _database
        .customSelect(
          'SELECT * FROM metadata_records WHERE scope_kind = ? AND scope_id = ? '
          'AND record_id IN ($placeholders)',
          variables: [
            Variable.withString(scope.kind),
            Variable.withString(scope.id),
            for (final id in requested) Variable.withString(id),
          ],
        )
        .get();
    final records = <String, RecordEnvelope>{};
    final failures = <String, PersistenceError>{};
    for (final row in rows) {
      final id = row.data['record_id'] as String;
      try {
        records[id] = await _rowToEnvelope(row.data);
      } on PersistenceError catch (error) {
        failures[id] = error;
      }
    }
    return RecordReadBatchResult(records: records, failures: failures);
  }

  Future<RecordPage> list(RecordQuery query) async {
    _ensureOpen();
    final where = <String>['record_kind = ?', 'scope_kind = ?', 'scope_id = ?'];
    final variables = <Variable<Object>>[
      Variable.withString(query.recordKind),
      Variable.withString(query.scope.kind),
      Variable.withString(query.scope.id),
    ];
    void addNullable(String column, String? value) {
      if (value == null) return;
      where.add('$column = ?');
      variables.add(Variable.withString(value));
    }

    addNullable('parent_id', query.parentId);
    addNullable('state_key', query.stateKey);
    addNullable('identity_key', query.identityKey);
    if (query.after case final after?) {
      where.add(
        '(COALESCE(order_key, \'\') > ? OR (COALESCE(order_key, \'\') = ? AND record_id > ?))',
      );
      variables.addAll([
        Variable.withString(after.orderKey),
        Variable.withString(after.orderKey),
        Variable.withString(after.id),
      ]);
    }
    final rows = await _database
        .customSelect(
          'SELECT * FROM metadata_records WHERE ${where.join(' AND ')} '
          'ORDER BY COALESCE(order_key, \'\') ASC, record_id ASC LIMIT ?',
          variables: [...variables, Variable.withInt(query.limit + 1)],
        )
        .get();
    final hasMore = rows.length > query.limit;
    final pageRows = hasMore ? rows.take(query.limit).toList() : rows;
    final records = <RecordEnvelope>[];
    for (final row in pageRows) {
      records.add(await _rowToEnvelope(row.data));
    }
    final tail = records.isEmpty ? null : records.last;
    return RecordPage(
      records: List.unmodifiable(records),
      nextCursor: hasMore && tail != null
          ? RecordCursor(orderKey: tail.orderKey ?? '', id: tail.id)
          : null,
    );
  }

  Future<RecordEnvelope> update({
    required RecordEnvelope previous,
    required JsonObject document,
  }) async {
    _ensureOpen();
    final codec = _registry.require(previous.recordKind, previous.scope.kind);
    final prepared = await codec.prepareCurrent(document);
    _lastCodecWorkerIsolateId = prepared.workerIsolateId;
    final now = _clock().toUtc();
    final affected = await _database.customUpdate(
      '''UPDATE metadata_records SET payload_json = ?, format_version = ?, revision = revision + 1,
          updated_at_utc = ? WHERE record_id = ? AND scope_kind = ? AND scope_id = ? AND revision = ?''',
      variables: [
        Variable.withString(prepared.payloadJson),
        Variable.withInt(codec.currentVersion),
        Variable.withInt(now.millisecondsSinceEpoch),
        Variable.withString(previous.id),
        Variable.withString(previous.scope.kind),
        Variable.withString(previous.scope.id),
        Variable.withInt(previous.revision),
      ],
      updates: {},
    );
    if (affected != 1) throw const PersistenceConflictError();
    return _envelopeFromPrevious(
      previous,
      codec.currentVersion,
      previous.revision + 1,
      prepared.document,
      previous.createdAtUtc,
      now,
    );
  }

  Future<void> delete({required RecordEnvelope previous}) async {
    _ensureOpen();
    final affected = await _database.customUpdate(
      'DELETE FROM metadata_records WHERE record_id = ? AND scope_kind = ? AND scope_id = ? AND revision = ?',
      variables: [
        Variable.withString(previous.id),
        Variable.withString(previous.scope.kind),
        Variable.withString(previous.scope.id),
        Variable.withInt(previous.revision),
      ],
      updates: {},
    );
    if (affected != 1) throw const PersistenceConflictError();
  }

  Future<void> createBatch(List<RecordDraft> drafts) async {
    _ensureOpen();
    _validateWriteBatchSize(drafts.length);
    final prepared = <_PreparedDraft>[];
    for (final draft in drafts) {
      prepared.add(await _prepareDraft(draft));
    }
    try {
      await _database.transaction(() async {
        for (final draft in prepared) {
          await _insertPreparedDraft(draft);
        }
      });
    } catch (error) {
      if (error.toString().contains('UNIQUE constraint failed')) {
        throw const PersistenceConflictError();
      }
      rethrow;
    }
  }

  Future<List<RecordDocumentWriteResult>> writeDocumentsCas(
    List<RecordDocumentWrite> writes,
  ) async {
    _ensureOpen();
    _validateWriteBatchSize(writes.length);
    final identities = <(String, ScopeKey)>{};
    for (final write in writes) {
      if (write.id.isEmpty ||
          write.recordKind.isEmpty ||
          write.scope.kind.isEmpty ||
          write.scope.id.isEmpty ||
          (write.expectedRevision != null && write.expectedRevision! < 1)) {
        throw const PersistenceValidationError(
          'CAS writes require valid IDs, scope, kind, and revision.',
        );
      }
      if (!identities.add((write.id, write.scope))) {
        throw const PersistenceValidationError(
          'A CAS batch cannot contain the same record twice.',
        );
      }
    }
    final prepared = <_PreparedDocumentWrite>[];
    for (final write in writes) {
      final codec = _registry.require(write.recordKind, write.scope.kind);
      final document = await codec.prepareCurrent(write.document);
      _lastCodecWorkerIsolateId = document.workerIsolateId;
      prepared.add(_PreparedDocumentWrite(write, codec, document));
    }
    final now = _clock().toUtc().millisecondsSinceEpoch;
    try {
      return await _database.transaction(() async {
        final results = <RecordDocumentWriteResult>[];
        for (final item in prepared) {
          final write = item.write;
          final expected = write.expectedRevision;
          if (expected == null) {
            await _database.customStatement(
              '''INSERT INTO metadata_records (
                record_id, record_kind, scope_kind, scope_id, format_version,
                revision, payload_json, created_at_utc, updated_at_utc
              ) VALUES (?, ?, ?, ?, ?, 1, ?, ?, ?)''',
              [
                write.id,
                write.recordKind,
                write.scope.kind,
                write.scope.id,
                item.codec.currentVersion,
                item.document.payloadJson,
                now,
                now,
              ],
            );
            results.add(
              RecordDocumentWriteResult(
                id: write.id,
                scope: write.scope,
                revision: 1,
                document: item.document.document,
              ),
            );
            continue;
          }
          final affected = await _database.customUpdate(
            '''UPDATE metadata_records SET payload_json = ?, format_version = ?,
              revision = revision + 1, updated_at_utc = ?
              WHERE record_id = ? AND record_kind = ? AND scope_kind = ?
              AND scope_id = ? AND revision = ?''',
            variables: [
              Variable.withString(item.document.payloadJson),
              Variable.withInt(item.codec.currentVersion),
              Variable.withInt(now),
              Variable.withString(write.id),
              Variable.withString(write.recordKind),
              Variable.withString(write.scope.kind),
              Variable.withString(write.scope.id),
              Variable.withInt(expected),
            ],
            updates: {},
          );
          if (affected != 1) {
            throw const PersistenceConflictError();
          }
          results.add(
            RecordDocumentWriteResult(
              id: write.id,
              scope: write.scope,
              revision: expected + 1,
              document: item.document.document,
            ),
          );
        }
        return results;
      });
    } catch (error) {
      if (error is PersistenceConflictError ||
          error.toString().contains('UNIQUE constraint failed')) {
        throw const PersistenceConflictError();
      }
      rethrow;
    }
  }

  void _validateWriteBatchSize(int length) {
    if (length > maxWriteBatchSize) {
      throw const PersistenceValidationError(
        'A write batch cannot contain more than 128 documents.',
      );
    }
  }

  Future<T> transaction<T>(Future<T> Function() action) async {
    _ensureOpen();
    return _database.transaction(action);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _database.close();
  }

  /// Test-only fault injection. It is intentionally not exported by the facade.
  Future<void> debugReplacePayloadForTest({
    required String id,
    required ScopeKey scope,
    required int version,
    required String payloadJson,
  }) async {
    _ensureOpen();
    await _database.customStatement(
      'UPDATE metadata_records SET format_version = ?, payload_json = ? WHERE record_id = ? AND scope_kind = ? AND scope_id = ?',
      [version, payloadJson, id, scope.kind, scope.id],
    );
  }

  void _ensureOpen() {
    if (_closed) throw const PersistenceClosedError();
  }

  void _validateDraft(RecordDraft draft) {
    if (draft.id.isEmpty ||
        draft.recordKind.isEmpty ||
        draft.scope.kind.isEmpty ||
        draft.scope.id.isEmpty) {
      throw const PersistenceValidationError(
        'Record identifiers and scope values cannot be empty.',
      );
    }
  }

  Future<RecordEnvelope> _rowToEnvelope(Map<String, dynamic> row) async {
    final kind = row['record_kind'] as String;
    final scope = ScopeKey(
      kind: row['scope_kind'] as String,
      id: row['scope_id'] as String,
    );
    final codec = _registry.require(kind, scope.kind);
    final prepared = await codec.decodeAndUpgrade(
      version: row['format_version'] as int,
      payloadJson: row['payload_json'] as String,
    );
    _lastCodecWorkerIsolateId = prepared.workerIsolateId;
    return RecordEnvelope(
      id: row['record_id'] as String,
      recordKind: kind,
      scope: scope,
      parentId: row['parent_id'] as String?,
      identityKey: row['identity_key'] as String?,
      orderKey: row['order_key'] as String?,
      stateKey: row['state_key'] as String?,
      formatVersion: codec.currentVersion,
      revision: row['revision'] as int,
      document: prepared.document,
      createdAtUtc: DateTime.fromMillisecondsSinceEpoch(
        row['created_at_utc'] as int,
        isUtc: true,
      ),
      updatedAtUtc: DateTime.fromMillisecondsSinceEpoch(
        row['updated_at_utc'] as int,
        isUtc: true,
      ),
    );
  }

  Future<_PreparedDraft> _prepareDraft(RecordDraft draft) async {
    _validateDraft(draft);
    final codec = _registry.require(draft.recordKind, draft.scope.kind);
    final document = await codec.prepareCurrent(draft.document);
    _lastCodecWorkerIsolateId = document.workerIsolateId;
    return _PreparedDraft(
      draft: draft,
      codec: codec,
      document: document,
      now: _clock().toUtc(),
    );
  }

  Future<RecordEnvelope> _insertPreparedDraft(_PreparedDraft prepared) async {
    final draft = prepared.draft;
    await _database.customStatement(
      '''INSERT INTO metadata_records (
        record_id, record_kind, scope_kind, scope_id, parent_id, identity_key,
        order_key, state_key, format_version, revision, payload_json,
        created_at_utc, updated_at_utc
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?)''',
      [
        draft.id,
        draft.recordKind,
        draft.scope.kind,
        draft.scope.id,
        draft.parentId,
        draft.identityKey,
        draft.orderKey,
        draft.stateKey,
        prepared.codec.currentVersion,
        prepared.document.payloadJson,
        prepared.now.millisecondsSinceEpoch,
        prepared.now.millisecondsSinceEpoch,
      ],
    );
    return _envelopeFromDraft(
      draft,
      prepared.codec.currentVersion,
      1,
      prepared.document.document,
      prepared.now,
      prepared.now,
    );
  }

  RecordEnvelope _envelopeFromDraft(
    RecordDraft draft,
    int version,
    int revision,
    JsonObject document,
    DateTime created,
    DateTime updated,
  ) => RecordEnvelope(
    id: draft.id,
    recordKind: draft.recordKind,
    scope: draft.scope,
    formatVersion: version,
    revision: revision,
    document: document,
    createdAtUtc: created,
    updatedAtUtc: updated,
    parentId: draft.parentId,
    identityKey: draft.identityKey,
    orderKey: draft.orderKey,
    stateKey: draft.stateKey,
  );

  RecordEnvelope _envelopeFromPrevious(
    RecordEnvelope previous,
    int version,
    int revision,
    JsonObject document,
    DateTime created,
    DateTime updated,
  ) => RecordEnvelope(
    id: previous.id,
    recordKind: previous.recordKind,
    scope: previous.scope,
    formatVersion: version,
    revision: revision,
    document: document,
    createdAtUtc: created,
    updatedAtUtc: updated,
    parentId: previous.parentId,
    identityKey: previous.identityKey,
    orderKey: previous.orderKey,
    stateKey: previous.stateKey,
  );
}

final class _PersistenceDatabase extends GeneratedDatabase {
  _PersistenceDatabase(super.executor);
  @override
  int get schemaVersion => 1;
  @override
  Iterable<TableInfo<Table, dynamic>> get allTables => const [];
}

final class RecordReadBatchResult {
  const RecordReadBatchResult({required this.records, required this.failures});

  final Map<String, RecordEnvelope> records;
  final Map<String, PersistenceError> failures;
}

final class RecordDocumentWrite {
  const RecordDocumentWrite({
    required this.id,
    required this.recordKind,
    required this.scope,
    required this.expectedRevision,
    required this.document,
  });

  final String id;
  final String recordKind;
  final ScopeKey scope;
  final int? expectedRevision;
  final JsonObject document;
}

final class RecordDocumentWriteResult {
  const RecordDocumentWriteResult({
    required this.id,
    required this.scope,
    required this.revision,
    required this.document,
  });

  final String id;
  final ScopeKey scope;
  final int revision;
  final JsonObject document;
}

final class _PreparedDraft {
  const _PreparedDraft({
    required this.draft,
    required this.codec,
    required this.document,
    required this.now,
  });

  final RecordDraft draft;
  final RecordDocumentCodec codec;
  final PreparedJsonDocument document;
  final DateTime now;
}

final class _PreparedDocumentWrite {
  const _PreparedDocumentWrite(this.write, this.codec, this.document);

  final RecordDocumentWrite write;
  final RecordDocumentCodec codec;
  final PreparedJsonDocument document;
}

DateTime _utcNow() => DateTime.now().toUtc();
