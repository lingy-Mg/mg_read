import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';

import 'json_codec.dart';
import 'persistence_error.dart';
import 'record.dart';

typedef UtcClock = DateTime Function();

final class PersistenceRecordStore {
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

  /// Native Drift hosts all SQL work on a dedicated background isolate.
  bool get usesBackgroundExecutor => true;

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
    _validateDraft(draft);
    final codec = _registry.require(draft.recordKind, draft.scope.kind);
    final document = codec.validateCurrent(draft.document);
    final now = _clock().toUtc();
    try {
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
          codec.currentVersion,
          jsonEncode(document),
          now.millisecondsSinceEpoch,
          now.millisecondsSinceEpoch,
        ],
      );
    } catch (error) {
      if (error.toString().contains('UNIQUE constraint failed')) {
        throw const PersistenceConflictError();
      }
      rethrow;
    }
    return _envelopeFromDraft(
      draft,
      codec.currentVersion,
      1,
      document,
      now,
      now,
    );
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
    final normalized = codec.validateCurrent(document);
    final now = _clock().toUtc();
    final affected = await _database.customUpdate(
      '''UPDATE metadata_records SET payload_json = ?, format_version = ?, revision = revision + 1,
          updated_at_utc = ? WHERE record_id = ? AND scope_kind = ? AND scope_id = ? AND revision = ?''',
      variables: [
        Variable.withString(jsonEncode(normalized)),
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
      normalized,
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
    await _database.transaction(() async {
      for (final draft in drafts) {
        await create(draft);
      }
    });
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
    final document = codec.decodeAndUpgrade(
      version: row['format_version'] as int,
      payloadJson: row['payload_json'] as String,
    );
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
      document: document,
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

DateTime _utcNow() => DateTime.now().toUtc();
