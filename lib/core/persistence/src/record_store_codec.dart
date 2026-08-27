/// PersistenceRecordStore 的文档编解码、升级与 envelope 映射。
///
/// 不改变 JSON 限额、codec registry、revision 或时间戳语义。
part of 'record_store.dart';

extension _PersistenceRecordCodec on PersistenceRecordStore {
  void _validateDraft(RecordDraft draft) {
    if (draft.id.isEmpty || draft.recordKind.isEmpty || draft.scope.kind.isEmpty || draft.scope.id.isEmpty) {
      throw const PersistenceValidationError('Record identifiers and scope values cannot be empty.');
    }
  }

  Future<RecordEnvelope> _rowToEnvelope(Map<String, dynamic> row) async {
    final kind = row['record_kind'] as String;
    final scope = ScopeKey(kind: row['scope_kind'] as String, id: row['scope_id'] as String);
    final codec = _registry.require(kind, scope.kind);
    final prepared = await codec.decodeAndUpgrade(version: row['format_version'] as int, payloadJson: row['payload_json'] as String);
    _lastCodecWorkerIsolateId = prepared.workerIsolateId;
    return _preparedRowToEnvelope(row, codec, prepared);
  }

  Future<List<RecordEnvelope>> _rowsToEnvelopes(Iterable<Map<String, dynamic>> rows) async {
    final copied = List<Map<String, dynamic>>.of(rows);
    if (copied.isEmpty) return const <RecordEnvelope>[];
    final prepared = await _registry.decodeAndUpgradeMany(
      documents: copied
          .map(
            (row) => (
              recordKind: row['record_kind'] as String,
              scopeKind: row['scope_kind'] as String,
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
        (index) => _preparedRowToEnvelope(
          copied[index],
          _registry.require(copied[index]['record_kind'] as String, copied[index]['scope_kind'] as String),
          prepared[index],
        ),
      ),
    );
  }

  RecordEnvelope _preparedRowToEnvelope(Map<String, dynamic> row, RecordDocumentCodec codec, PreparedJsonDocument prepared) =>
      RecordEnvelope(
        id: row['record_id'] as String,
        recordKind: row['record_kind'] as String,
        scope: ScopeKey(kind: row['scope_kind'] as String, id: row['scope_id'] as String),
        parentId: row['parent_id'] as String?,
        identityKey: row['identity_key'] as String?,
        orderKey: row['order_key'] as String?,
        stateKey: row['state_key'] as String?,
        formatVersion: codec.currentVersion,
        revision: row['revision'] as int,
        document: prepared.document,
        createdAtUtc: DateTime.fromMillisecondsSinceEpoch(row['created_at_utc'] as int, isUtc: true),
        updatedAtUtc: DateTime.fromMillisecondsSinceEpoch(row['updated_at_utc'] as int, isUtc: true),
      );

  Future<_PreparedDraft> _prepareDraft(RecordDraft draft) async {
    _validateDraft(draft);
    final codec = _registry.require(draft.recordKind, draft.scope.kind);
    final document = await codec.prepareCurrent(draft.document);
    _lastCodecWorkerIsolateId = document.workerIsolateId;
    return _PreparedDraft(draft: draft, codec: codec, document: document, now: _clock().toUtc());
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
    return _envelopeFromDraft(draft, prepared.codec.currentVersion, 1, prepared.document.document, prepared.now, prepared.now);
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

final class _PreparedDraft {
  const _PreparedDraft({required this.draft, required this.codec, required this.document, required this.now});

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
