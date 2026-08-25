import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:mg_read/core/diagnostics/diagnostics.dart';

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
    this._diagnostics,
  );

  final _PersistenceDatabase _database;
  final RecordDocumentRegistry _registry;
  final UtcClock _clock;
  final String databasePath;
  final DiagnosticsManager? _diagnostics;
  bool _closed = false;
  bool _closing = false;
  int _activeOperations = 0;
  Completer<void>? _idleOperations;
  Future<void>? _closeFuture;
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
    DiagnosticsManager? diagnostics,
  }) async {
    Future<PersistenceRecordStore> openStore() async {
      await dataRoot.create(recursive: true);
      final path =
          '${dataRoot.path}${Platform.pathSeparator}app_metadata.sqlite';
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
      await database.customStatement(
        'CREATE INDEX IF NOT EXISTS metadata_records_parent_state_order ON metadata_records(record_kind, scope_kind, scope_id, parent_id, state_key, order_key, record_id)',
      );
      return PersistenceRecordStore._(
        database,
        registry,
        clock,
        path,
        diagnostics,
      );
    }

    if (diagnostics == null) return openStore();
    return diagnostics.runSpan<PersistenceRecordStore>(
      AppDiagnosticEvents.persistenceOpen,
      (_) => openStore(),
      startAttributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
        'store': DiagnosticValue.string('metadata'),
        'schemaVersion': DiagnosticValue.int64(1),
      }),
      successAttributes: (_) => DiagnosticObjectValue(<String, DiagnosticValue>{
        'store': DiagnosticValue.string('metadata'),
        'schemaVersion': DiagnosticValue.int64(1),
      }),
      errorAttributes: (_) => DiagnosticObjectValue(<String, DiagnosticValue>{
        'store': DiagnosticValue.string('metadata'),
        'schemaVersion': DiagnosticValue.int64(1),
        'errorCode': DiagnosticValue.string('open_failed'),
      }),
    );
  }

  Future<RecordEnvelope> create(RecordDraft draft) => _instrument(
    operation: 'create',
    recordKind: draft.recordKind,
    count: 1,
    action: () => _create(draft),
    revision: (result) => result.revision,
  );

  Future<RecordEnvelope?> read({required String id, required ScopeKey scope}) =>
      _instrument(
        operation: 'read',
        action: () => _read(id: id, scope: scope),
        resultCount: (result) => result == null ? 0 : 1,
        revision: (result) => result?.revision,
      );

  Future<RecordReadBatchResult> readMany({
    required Iterable<String> ids,
    required ScopeKey scope,
  }) {
    final requested = List<String>.of(ids);
    return _instrument(
      operation: 'readMany',
      count: requested.length,
      action: () => _readMany(ids: requested, scope: scope),
      resultCount: (result) => result.records.length,
    );
  }

  Future<RecordPage> list(RecordQuery query) => _instrument(
    operation: 'list',
    recordKind: query.recordKind,
    count: query.limit,
    action: () => _list(query),
    resultCount: (result) => result.records.length,
  );

  /// Counts matching records without decoding their versioned documents.
  /// Typed repositories use this for legacy snapshot metadata compatibility.
  Future<int> count(RecordQuery query) => _instrument(
    operation: 'count',
    recordKind: query.recordKind,
    action: () => _count(query),
  );

  /// Reads records for a bounded set of identity keys with one SQL statement.
  ///
  /// This is an infrastructure primitive for typed repositories that need to
  /// project several related records at once. Callers keep the record kind and
  /// scope explicit so this does not become a cross-scope lookup API.
  Future<List<RecordEnvelope>> listByIdentityKeys({
    required String recordKind,
    required ScopeKey scope,
    required Iterable<String> identityKeys,
  }) {
    final requested = identityKeys.toSet();
    return _instrument(
      operation: 'listByIdentityKeys',
      recordKind: recordKind,
      count: requested.length,
      action: () => _listByIdentityKeys(
        recordKind: recordKind,
        scope: scope,
        identityKeys: requested,
      ),
      resultCount: (result) => result.length,
    );
  }

  Future<RecordEnvelope> update({
    required RecordEnvelope previous,
    required JsonObject document,
  }) => _instrument(
    operation: 'update',
    recordKind: previous.recordKind,
    count: 1,
    action: () => _update(previous: previous, document: document),
    revision: (result) => result.revision,
  );

  Future<void> delete({required RecordEnvelope previous}) => _instrument(
    operation: 'delete',
    recordKind: previous.recordKind,
    count: 1,
    action: () => _delete(previous: previous),
  );

  Future<void> createBatch(List<RecordDraft> drafts) {
    final copied = List<RecordDraft>.of(drafts);
    return _instrument(
      operation: 'createBatch',
      recordKind: _singleRecordKind(copied.map((draft) => draft.recordKind)),
      count: copied.length,
      action: () => _createBatch(copied),
    );
  }

  Future<List<RecordDocumentWriteResult>> writeDocumentsCas(
    List<RecordDocumentWrite> writes,
  ) {
    final copied = List<RecordDocumentWrite>.of(writes);
    return _instrument(
      operation: 'writeDocumentsCas',
      recordKind: _singleRecordKind(copied.map((write) => write.recordKind)),
      count: copied.length,
      action: () => _writeDocumentsCas(copied),
      resultCount: (result) => result.length,
    );
  }

  Future<T> transaction<T>(Future<T> Function() action) =>
      _instrument(operation: 'transaction', action: () => _transaction(action));

  Future<void> close() => _closeFuture ??= _beginClose();

  Future<void> _beginClose() async {
    _closing = true;
    if (_activeOperations != 0) {
      await (_idleOperations ??= Completer<void>()).future;
    }
    final diagnostics = _diagnostics;
    if (diagnostics == null || diagnostics.isClosed) {
      await _close();
      return;
    }
    await diagnostics.runSpan<void>(
      AppDiagnosticEvents.persistenceClose,
      (_) => _close(),
      startAttributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
        'store': DiagnosticValue.string('metadata'),
      }),
      successAttributes: (_) => DiagnosticObjectValue(<String, DiagnosticValue>{
        'store': DiagnosticValue.string('metadata'),
      }),
      errorAttributes: (_) => DiagnosticObjectValue(<String, DiagnosticValue>{
        'store': DiagnosticValue.string('metadata'),
        'errorCode': DiagnosticValue.string('close_failed'),
      }),
    );
  }

  Future<RecordEnvelope> _create(RecordDraft draft) async {
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

  Future<RecordEnvelope?> _read({
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

  Future<RecordReadBatchResult> _readMany({
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

  Future<RecordPage> _list(RecordQuery query) async {
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
    addNullable('order_key', query.orderKey);
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
    final records = await _rowsToEnvelopes(
      pageRows.map((row) => row.data).toList(growable: false),
    );
    final tail = records.isEmpty ? null : records.last;
    return RecordPage(
      records: List.unmodifiable(records),
      nextCursor: hasMore && tail != null
          ? RecordCursor(orderKey: tail.orderKey ?? '', id: tail.id)
          : null,
    );
  }

  Future<int> _count(RecordQuery query) async {
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
    addNullable('order_key', query.orderKey);
    final rows = await _database
        .customSelect(
          'SELECT COUNT(*) AS record_count FROM metadata_records WHERE ${where.join(' AND ')}',
          variables: variables,
        )
        .get();
    return rows.single.data['record_count'] as int;
  }

  Future<List<RecordEnvelope>> _listByIdentityKeys({
    required String recordKind,
    required ScopeKey scope,
    required Set<String> identityKeys,
  }) async {
    _ensureOpen();
    if (identityKeys.isEmpty) return const <RecordEnvelope>[];
    if (identityKeys.length > 900 || identityKeys.any((key) => key.isEmpty)) {
      throw const PersistenceValidationError(
        'Identity batch reads require 1 to 900 non-empty keys.',
      );
    }
    final placeholders = List.filled(identityKeys.length, '?').join(', ');
    final rows = await _database
        .customSelect(
          'SELECT * FROM metadata_records '
          'WHERE record_kind = ? AND scope_kind = ? AND scope_id = ? '
          'AND identity_key IN ($placeholders) '
          'ORDER BY identity_key ASC, COALESCE(order_key, \'\') ASC, record_id ASC',
          variables: <Variable<Object>>[
            Variable.withString(recordKind),
            Variable.withString(scope.kind),
            Variable.withString(scope.id),
            for (final key in identityKeys) Variable.withString(key),
          ],
        )
        .get();
    return _rowsToEnvelopes(rows.map((row) => row.data));
  }

  Future<RecordEnvelope> _update({
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

  Future<void> _delete({required RecordEnvelope previous}) async {
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

  Future<void> _createBatch(List<RecordDraft> drafts) async {
    _ensureOpen();
    _validateWriteBatchSize(drafts.length);
    final prepared = List<_PreparedDraft?>.filled(drafts.length, null);
    final groups = <(String, String), List<(int, RecordDraft)>>{};
    for (var index = 0; index < drafts.length; index++) {
      final draft = drafts[index];
      _validateDraft(draft);
      groups
          .putIfAbsent((
            draft.recordKind,
            draft.scope.kind,
          ), () => <(int, RecordDraft)>[])
          .add((index, draft));
    }
    for (final group in groups.values) {
      final codec = _registry.require(
        group.first.$2.recordKind,
        group.first.$2.scope.kind,
      );
      final documents = await codec.prepareCurrentMany(
        documents: group.map((entry) => entry.$2.document),
      );
      for (var index = 0; index < group.length; index++) {
        final entry = group[index];
        final document = documents[index];
        _lastCodecWorkerIsolateId = document.workerIsolateId;
        prepared[entry.$1] = _PreparedDraft(
          draft: entry.$2,
          codec: codec,
          document: document,
          now: _clock().toUtc(),
        );
      }
    }
    try {
      await _database.transaction(() async {
        for (final draft in prepared) {
          await _insertPreparedDraft(draft!);
        }
      });
    } catch (error) {
      if (error.toString().contains('UNIQUE constraint failed')) {
        throw const PersistenceConflictError();
      }
      rethrow;
    }
  }

  Future<List<RecordDocumentWriteResult>> _writeDocumentsCas(
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

  Future<T> _instrument<T>({
    required String operation,
    String? recordKind,
    int? count,
    required Future<T> Function() action,
    int? Function(T result)? resultCount,
    int? Function(T result)? revision,
  }) {
    return _withOperation(() {
      final diagnostics = _diagnostics;
      if (diagnostics == null || diagnostics.isClosed) return action();
      return diagnostics.runSpan<T>(
        AppDiagnosticEvents.persistenceOperation,
        (span) async {
          final stopwatch = Stopwatch()..start();
          try {
            final result = await action();
            stopwatch.stop();
            reportSlowDiagnostic(
              diagnostics,
              subjectComponent: 'app.persistence',
              operation: operation,
              elapsed: stopwatch.elapsed,
              threshold: AppDiagnosticThresholds.persistenceOperation,
              outcome: DiagnosticOutcome.success,
              traceContext: span.traceContext,
            );
            return result;
          } catch (_) {
            stopwatch.stop();
            reportSlowDiagnostic(
              diagnostics,
              subjectComponent: 'app.persistence',
              operation: operation,
              elapsed: stopwatch.elapsed,
              threshold: AppDiagnosticThresholds.persistenceOperation,
              outcome: DiagnosticOutcome.error,
              traceContext: span.traceContext,
            );
            rethrow;
          }
        },
        startAttributes: () => _operationAttributes(
          operation: operation,
          recordKind: recordKind,
          count: count,
        ),
        successAttributes: (result) => _operationAttributes(
          operation: operation,
          recordKind: recordKind,
          count: resultCount?.call(result) ?? count,
          revision: revision?.call(result),
        ),
        errorAttributes: (error) => _operationAttributes(
          operation: operation,
          recordKind: recordKind,
          count: count,
          errorCode: _persistenceErrorCode(error),
        ),
      );
    });
  }

  DiagnosticObjectValue _operationAttributes({
    required String operation,
    String? recordKind,
    int? count,
    int? revision,
    String? errorCode,
  }) => DiagnosticObjectValue(<String, DiagnosticValue>{
    'store': DiagnosticValue.string('metadata'),
    'operation': DiagnosticValue.string(operation),
    if (recordKind != null) 'recordKind': DiagnosticValue.string(recordKind),
    if (count != null) 'count': DiagnosticValue.int64(count),
    if (revision != null) 'revision': DiagnosticValue.int64(revision),
    if (errorCode != null) 'errorCode': DiagnosticValue.string(errorCode),
    'thresholdMicros': DiagnosticValue.int64(
      AppDiagnosticThresholds.persistenceOperation.inMicroseconds,
    ),
  });

  void _validateWriteBatchSize(int length) {
    if (length > maxWriteBatchSize) {
      throw const PersistenceValidationError(
        'A write batch cannot contain more than 128 documents.',
      );
    }
  }

  Future<T> _transaction<T>(Future<T> Function() action) async {
    _ensureOpen();
    return _database.transaction(action);
  }

  Future<void> _close() async {
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
  }) => _withOperation(() async {
    _ensureOpen();
    await _database.customStatement(
      'UPDATE metadata_records SET format_version = ?, payload_json = ? WHERE record_id = ? AND scope_kind = ? AND scope_id = ?',
      [version, payloadJson, id, scope.kind, scope.id],
    );
  });

  void _ensureOpen() {
    if (_closed ||
        (_closing && !identical(Zone.current[#persistenceRecordStore], this))) {
      throw const PersistenceClosedError();
    }
  }

  Future<T> _withOperation<T>(Future<T> Function() action) {
    if (identical(Zone.current[#persistenceRecordStore], this)) {
      return action();
    }
    if (_closed || _closing) {
      return Future<T>.error(const PersistenceClosedError());
    }
    _activeOperations++;
    return runZoned<Future<T>>(
      () => Future<T>.sync(action).whenComplete(() {
        _activeOperations--;
        if (_closing && _activeOperations == 0) {
          _idleOperations?.complete();
        }
      }),
      zoneValues: <Object?, Object?>{#persistenceRecordStore: this},
    );
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
    return _preparedRowToEnvelope(row, codec, prepared);
  }

  Future<List<RecordEnvelope>> _rowsToEnvelopes(
    Iterable<Map<String, dynamic>> rows,
  ) async {
    final copied = List<Map<String, dynamic>>.of(rows);
    if (copied.isEmpty) return const <RecordEnvelope>[];
    final first = copied.first;
    final recordKind = first['record_kind'] as String;
    final scopeKind = first['scope_kind'] as String;
    if (copied.any(
      (row) =>
          row['record_kind'] != recordKind || row['scope_kind'] != scopeKind,
    )) {
      return Future.wait(copied.map(_rowToEnvelope));
    }
    final codec = _registry.require(recordKind, scopeKind);
    final prepared = await codec.decodeAndUpgradeMany(
      documents: copied
          .map(
            (row) => (
              version: row['format_version'] as int,
              payloadJson: row['payload_json'] as String,
            ),
          )
          .toList(growable: false),
    );
    if (prepared.isNotEmpty) {
      _lastCodecWorkerIsolateId = prepared.last.workerIsolateId;
    }
    return List<RecordEnvelope>.unmodifiable(
      List<RecordEnvelope>.generate(
        copied.length,
        (index) =>
            _preparedRowToEnvelope(copied[index], codec, prepared[index]),
      ),
    );
  }

  RecordEnvelope _preparedRowToEnvelope(
    Map<String, dynamic> row,
    RecordDocumentCodec codec,
    PreparedJsonDocument prepared,
  ) => RecordEnvelope(
    id: row['record_id'] as String,
    recordKind: row['record_kind'] as String,
    scope: ScopeKey(
      kind: row['scope_kind'] as String,
      id: row['scope_id'] as String,
    ),
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

String? _singleRecordKind(Iterable<String> kinds) {
  final values = kinds.toSet();
  if (values.isEmpty) return null;
  return values.length == 1 ? values.single : 'mixed';
}

String _persistenceErrorCode(Object error) => switch (error) {
  PersistenceError(:final code) => code,
  FileSystemException() => 'file_io_failed',
  _ => 'operation_failed',
};

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
