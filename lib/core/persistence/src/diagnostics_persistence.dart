import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:mg_read/core/diagnostics/src/diagnostic_event.dart';
import 'package:mg_read/core/diagnostics/src/diagnostic_ports.dart';

import 'diagnostic_object_store.dart';

final class DiagnosticStoredCaptureSession {
  DiagnosticStoredCaptureSession({
    required this.session,
    required this.maxStoredBytes,
    required Set<String> components,
    required Set<String> origins,
    required this.isDefault,
  }) : components = Set<String>.unmodifiable(components),
       origins = Set<String>.unmodifiable(origins);

  final DiagnosticSession session;
  final int maxStoredBytes;
  final Set<String> components;
  final Set<String> origins;
  final bool isDefault;

  int get remainingBytes {
    final remaining = maxStoredBytes - session.storedBytes;
    return remaining > 0 ? remaining : 0;
  }
}

final class DiagnosticCommittedAttachment {
  const DiagnosticCommittedAttachment({
    required this.descriptor,
    required this.objectKey,
  });

  final DiagnosticAttachmentDescriptor descriptor;
  final String? objectKey;
}

/// SQLite index and schema lifecycle for app-owned diagnostics.
final class DiagnosticsPersistence {
  DiagnosticsPersistence._(
    this._database,
    this.objectStore,
    this.databasePath,
    this._clock,
  );

  static const int schemaVersion = 1;
  static const int maxWriteBatchSize = 128;
  static const int maxQueryPageSize = 200;

  final _DiagnosticsDatabase _database;
  final DiagnosticObjectStore objectStore;
  final String databasePath;
  final DateTime Function() _clock;
  final DiagnosticEventCodec _eventCodec = const DiagnosticEventCodec();
  bool _closed = false;
  int? _lastEncoderWorkerIsolateId;

  bool get usesBackgroundExecutor => true;

  int? get lastEncoderWorkerIsolateIdForTest => _lastEncoderWorkerIsolateId;

  static Future<DiagnosticsPersistence> open({
    required Directory dataRoot,
    DateTime Function() clock = _utcNow,
  }) async {
    final diagnosticsRoot = Directory(
      '${dataRoot.path}${Platform.pathSeparator}diagnostics',
    );
    await diagnosticsRoot.create(recursive: true);
    final objectStore = await DiagnosticObjectStore.open(diagnosticsRoot);
    final path = '${diagnosticsRoot.path}${Platform.pathSeparator}index.sqlite';
    final database = _DiagnosticsDatabase(
      NativeDatabase.createInBackground(File(path)),
    );
    try {
      await database.customStatement('PRAGMA foreign_keys = ON');
      await database.customStatement('PRAGMA journal_mode = WAL');
      await database.customStatement('PRAGMA synchronous = NORMAL');
      await database.customStatement('PRAGMA busy_timeout = 5000');
      await _createSchema(database);
      final store = DiagnosticsPersistence._(
        database,
        objectStore,
        path,
        clock,
      );
      await store.recoverInterruptedState();
      await store.reconcileObjects();
      return store;
    } catch (_) {
      await database.close().catchError((_) {});
      await objectStore.close();
      rethrow;
    }
  }

  static Future<void> _createSchema(_DiagnosticsDatabase database) async {
    await database.customStatement('''
      CREATE TABLE IF NOT EXISTS diagnostic_schema (
        singleton INTEGER PRIMARY KEY NOT NULL CHECK (singleton = 1),
        schema_version INTEGER NOT NULL
      )
    ''');
    await database.customStatement(
      'INSERT OR IGNORE INTO diagnostic_schema (singleton, schema_version) VALUES (1, ?)',
      <Object?>[schemaVersion],
    );
    final versionRows = await database
        .customSelect(
          'SELECT schema_version FROM diagnostic_schema WHERE singleton = 1',
        )
        .get();
    final storedVersion = versionRows.single.data['schema_version'] as int;
    if (storedVersion > schemaVersion) {
      throw StateError(
        'Diagnostics schema $storedVersion is newer than $schemaVersion.',
      );
    }
    if (storedVersion < schemaVersion) {
      throw StateError('Diagnostics schema migration is incomplete.');
    }
    await database.customStatement('''
      CREATE TABLE IF NOT EXISTS diagnostic_runs (
        source_run_id TEXT PRIMARY KEY NOT NULL,
        source TEXT NOT NULL,
        started_at_utc_micros INTEGER NOT NULL,
        ended_at_utc_micros INTEGER,
        state TEXT NOT NULL,
        event_count INTEGER NOT NULL DEFAULT 0,
        attachment_count INTEGER NOT NULL DEFAULT 0,
        stored_bytes INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await database.customStatement('''
      CREATE TABLE IF NOT EXISTS diagnostic_capture_sessions (
        session_id TEXT PRIMARY KEY NOT NULL,
        source_run_id TEXT NOT NULL REFERENCES diagnostic_runs(source_run_id) ON DELETE CASCADE,
        payload_kind TEXT NOT NULL,
        state TEXT NOT NULL,
        started_at_utc_micros INTEGER NOT NULL,
        ended_at_utc_micros INTEGER,
        expires_at_utc_micros INTEGER,
        max_stored_bytes INTEGER NOT NULL,
        stored_bytes INTEGER NOT NULL DEFAULT 0,
        event_count INTEGER NOT NULL DEFAULT 0,
        attachment_count INTEGER NOT NULL DEFAULT 0,
        component_allowlist_json TEXT NOT NULL,
        origin_allowlist_json TEXT NOT NULL,
        is_default INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await database.customStatement('''
      CREATE TABLE IF NOT EXISTS diagnostic_events (
        event_id TEXT PRIMARY KEY NOT NULL,
        source_run_id TEXT NOT NULL REFERENCES diagnostic_runs(source_run_id) ON DELETE CASCADE,
        capture_session_id TEXT NOT NULL REFERENCES diagnostic_capture_sessions(session_id) ON DELETE CASCADE,
        source_sequence INTEGER NOT NULL,
        occurred_at_utc_micros INTEGER NOT NULL,
        monotonic_offset_micros INTEGER NOT NULL,
        severity INTEGER NOT NULL,
        component TEXT NOT NULL,
        event_name TEXT NOT NULL,
        event_schema_version INTEGER NOT NULL,
        trace_id TEXT,
        span_id TEXT,
        parent_span_id TEXT,
        phase TEXT NOT NULL,
        outcome TEXT,
        duration_micros INTEGER,
        summary TEXT NOT NULL,
        attachment_count INTEGER NOT NULL DEFAULT 0,
        captured_bytes INTEGER NOT NULL DEFAULT 0,
        envelope_json TEXT NOT NULL,
        UNIQUE(source_run_id, source_sequence)
      )
    ''');
    await database.customStatement('''
      CREATE TABLE IF NOT EXISTS diagnostic_objects (
        object_key TEXT PRIMARY KEY NOT NULL,
        sha256 TEXT NOT NULL,
        privacy_class TEXT NOT NULL,
        storage_codec TEXT NOT NULL,
        stored_byte_length INTEGER NOT NULL,
        reference_count INTEGER NOT NULL,
        created_at_utc_micros INTEGER NOT NULL
      )
    ''');
    await database.customStatement('''
      CREATE TABLE IF NOT EXISTS diagnostic_attachments (
        attachment_id TEXT PRIMARY KEY NOT NULL,
        event_id TEXT NOT NULL REFERENCES diagnostic_events(event_id) ON DELETE CASCADE,
        object_key TEXT REFERENCES diagnostic_objects(object_key),
        kind TEXT NOT NULL,
        media_type TEXT NOT NULL,
        charset TEXT,
        format_id TEXT NOT NULL,
        format_version INTEGER NOT NULL,
        schema_id TEXT,
        schema_version INTEGER,
        privacy_class TEXT NOT NULL,
        capture_state TEXT NOT NULL,
        raw_byte_length INTEGER NOT NULL,
        stored_byte_length INTEGER NOT NULL,
        sha256 TEXT,
        storage_codec TEXT NOT NULL,
        redaction_version INTEGER NOT NULL,
        truncation_reason TEXT
      )
    ''');
    for (final statement in <String>[
      'CREATE INDEX IF NOT EXISTS diagnostic_sessions_time ON diagnostic_capture_sessions(started_at_utc_micros DESC, session_id DESC)',
      'CREATE INDEX IF NOT EXISTS diagnostic_events_session_time ON diagnostic_events(capture_session_id, occurred_at_utc_micros DESC, event_id DESC)',
      'CREATE INDEX IF NOT EXISTS diagnostic_events_trace_time ON diagnostic_events(trace_id, occurred_at_utc_micros, event_id)',
      'CREATE INDEX IF NOT EXISTS diagnostic_events_severity_time ON diagnostic_events(severity, occurred_at_utc_micros DESC)',
      'CREATE INDEX IF NOT EXISTS diagnostic_events_component_name_time ON diagnostic_events(component, event_name, occurred_at_utc_micros DESC)',
      'CREATE INDEX IF NOT EXISTS diagnostic_attachments_event ON diagnostic_attachments(event_id, attachment_id)',
      'CREATE INDEX IF NOT EXISTS diagnostic_attachments_object ON diagnostic_attachments(object_key)',
    ]) {
      await database.customStatement(statement);
    }
  }

  Future<void> beginRun({
    required String sourceRunId,
    required DiagnosticSource source,
    required int regularSessionMaxBytes,
    required Duration regularSessionAge,
  }) async {
    _ensureOpen();
    validateDiagnosticOpaqueId(sourceRunId, 'sourceRunId');
    final now = _clock().toUtc().microsecondsSinceEpoch;
    await _database.transaction(() async {
      await _database.customStatement(
        '''INSERT INTO diagnostic_runs (
          source_run_id, source, started_at_utc_micros, state
        ) VALUES (?, ?, ?, ?)''',
        <Object?>[sourceRunId, source.name, now, 'active'],
      );
      await _database.customStatement(
        '''INSERT INTO diagnostic_capture_sessions (
          session_id, source_run_id, payload_kind, state,
          started_at_utc_micros, expires_at_utc_micros, max_stored_bytes,
          component_allowlist_json, origin_allowlist_json, is_default
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1)''',
        <Object?>[
          sourceRunId,
          sourceRunId,
          DiagnosticPayloadKind.metadataOnly.name,
          DiagnosticSessionState.active.name,
          now,
          now + regularSessionAge.inMicroseconds,
          regularSessionMaxBytes,
          '[]',
          '[]',
        ],
      );
    });
  }

  Future<void> endRun(String sourceRunId) async {
    _ensureOpen();
    final now = _clock().toUtc().microsecondsSinceEpoch;
    await _database.transaction(() async {
      await _database.customStatement(
        '''UPDATE diagnostic_capture_sessions
           SET state = ?, ended_at_utc_micros = COALESCE(ended_at_utc_micros, ?)
           WHERE source_run_id = ? AND state = ?''',
        <Object?>[
          DiagnosticSessionState.ended.name,
          now,
          sourceRunId,
          DiagnosticSessionState.active.name,
        ],
      );
      await _database.customStatement(
        '''UPDATE diagnostic_runs SET state = ?, ended_at_utc_micros = ?
           WHERE source_run_id = ? AND state = ?''',
        <Object?>['ended', now, sourceRunId, 'active'],
      );
    });
  }

  Future<void> insertEvents(List<DiagnosticEvent> events) async {
    _ensureOpen();
    if (events.isEmpty) return;
    if (events.length > maxWriteBatchSize) {
      throw ArgumentError(
        'At most $maxWriteBatchSize events may be committed.',
      );
    }
    final storedEvents = events
        .map(
          (event) => event.captureSessionId == null
              ? event.copyWith(captureSessionId: event.sourceRunId)
              : event,
        )
        .toList(growable: false);
    final encoded = await Isolate.run(
      _DiagnosticEventEncodeTask(storedEvents).call,
      debugName: 'mg-read-diagnostics-encode',
    );
    _lastEncoderWorkerIsolateId = encoded.workerIsolateId;
    final byRun = <String, int>{};
    final byRunBytes = <String, int>{};
    final bySession = <String, int>{};
    final bySessionBytes = <String, int>{};
    await _database.transaction(() async {
      for (var index = 0; index < storedEvents.length; index += 1) {
        final event = storedEvents[index];
        final sessionId = event.captureSessionId!;
        await _database.customStatement(
          '''INSERT INTO diagnostic_events (
            event_id, source_run_id, capture_session_id, source_sequence,
            occurred_at_utc_micros, monotonic_offset_micros, severity,
            component, event_name, event_schema_version, trace_id, span_id,
            parent_span_id, phase, outcome, duration_micros, summary,
            attachment_count, captured_bytes, envelope_json
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
          <Object?>[
            event.eventId,
            event.sourceRunId,
            sessionId,
            event.sourceSequence,
            event.occurredAtUtcMicros,
            event.monotonicOffsetMicros,
            event.severity.index,
            event.component,
            event.eventName,
            event.eventSchemaVersion,
            event.traceId,
            event.spanId,
            event.parentSpanId,
            event.phase.name,
            event.outcome?.name,
            event.durationMicros,
            event.summary,
            event.attachmentCount,
            event.capturedBytes,
            encoded.payloads[index],
          ],
        );
        byRun.update(
          event.sourceRunId,
          (value) => value + 1,
          ifAbsent: () => 1,
        );
        final encodedBytes = utf8.encode(encoded.payloads[index]).length;
        byRunBytes.update(
          event.sourceRunId,
          (value) => value + encodedBytes,
          ifAbsent: () => encodedBytes,
        );
        bySession.update(sessionId, (value) => value + 1, ifAbsent: () => 1);
        bySessionBytes.update(
          sessionId,
          (value) => value + encodedBytes,
          ifAbsent: () => encodedBytes,
        );
      }
      for (final entry in byRun.entries) {
        await _database.customStatement(
          '''UPDATE diagnostic_runs
             SET event_count = event_count + ?, stored_bytes = stored_bytes + ?
             WHERE source_run_id = ?''',
          <Object?>[entry.value, byRunBytes[entry.key], entry.key],
        );
      }
      for (final entry in bySession.entries) {
        await _database.customStatement(
          '''UPDATE diagnostic_capture_sessions
             SET event_count = event_count + ?, stored_bytes = stored_bytes + ?
             WHERE session_id = ?''',
          <Object?>[entry.value, bySessionBytes[entry.key], entry.key],
        );
      }
    });
  }

  Future<DiagnosticPage<DiagnosticSession>> listSessions({
    DiagnosticSessionFilter filter = const DiagnosticSessionFilter(),
    DiagnosticCursor? cursor,
    int limit = 100,
  }) async {
    _ensureOpen();
    _validateLimit(limit);
    final where = <String>[];
    final variables = <Variable<Object>>[];
    if (filter.sources.isNotEmpty) {
      where.add('r.source IN (${_placeholders(filter.sources.length)})');
      variables.addAll(
        filter.sources.map((source) => Variable.withString(source.name)),
      );
    }
    if (filter.states.isNotEmpty) {
      where.add('s.state IN (${_placeholders(filter.states.length)})');
      variables.addAll(
        filter.states.map((state) => Variable.withString(state.name)),
      );
    }
    if (filter.startedAfterUtcMicros case final value?) {
      where.add('s.started_at_utc_micros >= ?');
      variables.add(Variable.withInt(value));
    }
    if (filter.startedBeforeUtcMicros case final value?) {
      where.add('s.started_at_utc_micros <= ?');
      variables.add(Variable.withInt(value));
    }
    if (cursor case final value?) {
      final decoded = _decodeCursor(value, 'sessions');
      where.add(
        '(s.started_at_utc_micros < ? OR '
        '(s.started_at_utc_micros = ? AND s.session_id < ?))',
      );
      variables.addAll(<Variable<Object>>[
        Variable.withInt(decoded.$1),
        Variable.withInt(decoded.$1),
        Variable.withString(decoded.$2),
      ]);
    }
    final rows = await _database
        .customSelect(
          '''SELECT s.*, r.source FROM diagnostic_capture_sessions s
             JOIN diagnostic_runs r ON r.source_run_id = s.source_run_id
             ${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'}
             ORDER BY s.started_at_utc_micros DESC, s.session_id DESC
             LIMIT ?''',
          variables: <Variable<Object>>[
            ...variables,
            Variable.withInt(limit + 1),
          ],
        )
        .get();
    final hasMore = rows.length > limit;
    final selected = hasMore ? rows.take(limit) : rows;
    final sessions = selected.map((row) => _sessionFromRow(row.data)).toList();
    final tail = sessions.isEmpty ? null : sessions.last;
    return DiagnosticPage<DiagnosticSession>(
      items: sessions,
      nextCursor: hasMore && tail != null
          ? _encodeCursor('sessions', tail.startedAtUtcMicros, tail.sessionId)
          : null,
    );
  }

  Future<DiagnosticPage<DiagnosticEvent>> listEvents({
    required DiagnosticEventFilter filter,
    DiagnosticCursor? cursor,
    int limit = 100,
  }) async {
    _ensureOpen();
    _validateLimit(limit);
    final where = <String>[];
    final variables = <Variable<Object>>[];
    void addString(String column, String? value) {
      if (value == null) return;
      where.add('$column = ?');
      variables.add(Variable.withString(value));
    }

    addString('capture_session_id', filter.sessionId);
    addString('trace_id', filter.traceId);
    if (filter.minimumSeverity case final severity?) {
      where.add('severity >= ?');
      variables.add(Variable.withInt(severity.index));
    }
    _addStringSetFilter(where, variables, 'component', filter.components);
    _addStringSetFilter(where, variables, 'event_name', filter.eventNames);
    if (filter.occurredAfterUtcMicros case final value?) {
      where.add('occurred_at_utc_micros >= ?');
      variables.add(Variable.withInt(value));
    }
    if (filter.occurredBeforeUtcMicros case final value?) {
      where.add('occurred_at_utc_micros <= ?');
      variables.add(Variable.withInt(value));
    }
    if (cursor case final value?) {
      final decoded = _decodeCursor(value, 'events');
      where.add(
        '(occurred_at_utc_micros < ? OR '
        '(occurred_at_utc_micros = ? AND event_id < ?))',
      );
      variables.addAll(<Variable<Object>>[
        Variable.withInt(decoded.$1),
        Variable.withInt(decoded.$1),
        Variable.withString(decoded.$2),
      ]);
    }
    final rows = await _database
        .customSelect(
          '''SELECT * FROM diagnostic_events
             ${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'}
             ORDER BY occurred_at_utc_micros DESC, event_id DESC LIMIT ?''',
          variables: <Variable<Object>>[
            ...variables,
            Variable.withInt(limit + 1),
          ],
        )
        .get();
    final hasMore = rows.length > limit;
    final selected = hasMore ? rows.take(limit) : rows;
    final events = selected.map((row) => _eventFromRow(row.data)).toList();
    final tail = events.isEmpty ? null : events.last;
    return DiagnosticPage<DiagnosticEvent>(
      items: events,
      nextCursor: hasMore && tail != null
          ? _encodeCursor('events', tail.occurredAtUtcMicros, tail.eventId)
          : null,
    );
  }

  Future<DiagnosticEvent?> getEvent(String eventId) async {
    _ensureOpen();
    validateDiagnosticOpaqueId(eventId, 'eventId');
    final rows = await _database
        .customSelect(
          'SELECT * FROM diagnostic_events WHERE event_id = ?',
          variables: <Variable<Object>>[Variable.withString(eventId)],
        )
        .get();
    return rows.isEmpty ? null : _eventFromRow(rows.single.data);
  }

  Future<DiagnosticStoredCaptureSession?> getCaptureSession(
    String sessionId,
  ) async {
    _ensureOpen();
    validateDiagnosticOpaqueId(sessionId, 'sessionId');
    final rows = await _database
        .customSelect(
          '''SELECT s.*, r.source FROM diagnostic_capture_sessions s
             JOIN diagnostic_runs r ON r.source_run_id = s.source_run_id
             WHERE s.session_id = ?''',
          variables: <Variable<Object>>[Variable.withString(sessionId)],
        )
        .get();
    if (rows.isEmpty) return null;
    final row = rows.single.data;
    return DiagnosticStoredCaptureSession(
      session: _sessionFromRow(row),
      maxStoredBytes: row['max_stored_bytes'] as int,
      components: _decodeStringSet(row['component_allowlist_json'] as String),
      origins: _decodeStringSet(row['origin_allowlist_json'] as String),
      isDefault: (row['is_default'] as int) != 0,
    );
  }

  Future<DiagnosticSession> createCaptureSession({
    required String sessionId,
    required String sourceRunId,
    required DiagnosticCapturePolicy policy,
  }) async {
    _ensureOpen();
    final now = _clock().toUtc().microsecondsSinceEpoch;
    await _database.customStatement(
      '''INSERT INTO diagnostic_capture_sessions (
        session_id, source_run_id, payload_kind, state, started_at_utc_micros,
        expires_at_utc_micros, max_stored_bytes, component_allowlist_json,
        origin_allowlist_json, is_default
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0)''',
      <Object?>[
        sessionId,
        sourceRunId,
        policy.payloadKind.name,
        DiagnosticSessionState.active.name,
        now,
        now + policy.duration.inMicroseconds,
        policy.maxStoredBytes,
        jsonEncode(policy.components.toList()..sort()),
        jsonEncode(policy.origins.toList()..sort()),
      ],
    );
    return (await getCaptureSession(sessionId))!.session;
  }

  Future<void> stopCaptureSession(String sessionId) async {
    _ensureOpen();
    final now = _clock().toUtc().microsecondsSinceEpoch;
    await _database.customStatement(
      '''UPDATE diagnostic_capture_sessions SET state = ?, ended_at_utc_micros = ?
         WHERE session_id = ? AND state = ?''',
      <Object?>[
        DiagnosticSessionState.ended.name,
        now,
        sessionId,
        DiagnosticSessionState.active.name,
      ],
    );
  }

  Future<DiagnosticAttachmentDescriptor> commitAttachment({
    required DiagnosticAttachmentDescriptor descriptor,
    required String? objectKey,
  }) async {
    _ensureOpen();
    final event = await getEvent(descriptor.eventId);
    if (event == null) throw StateError('Attachment event does not exist.');
    final updatedEvent = event.copyWith(
      attachmentCount: event.attachmentCount + 1,
      capturedBytes: event.capturedBytes + descriptor.storedByteLength,
      flags: <DiagnosticEventFlag>{
        ...event.flags,
        if (descriptor.captureState == DiagnosticCaptureState.truncated)
          DiagnosticEventFlag.truncated,
        if (descriptor.captureState == DiagnosticCaptureState.policyBlocked ||
            descriptor.captureState == DiagnosticCaptureState.pressureDropped)
          DiagnosticEventFlag.droppedPayload,
      },
    );
    await _database.transaction(() async {
      if (objectKey != null) {
        await _database.customStatement(
          '''INSERT OR IGNORE INTO diagnostic_objects (
            object_key, sha256, privacy_class, storage_codec,
            stored_byte_length, reference_count, created_at_utc_micros
          ) VALUES (?, ?, ?, ?, ?, 0, ?)''',
          <Object?>[
            objectKey,
            descriptor.sha256,
            descriptor.privacyClass.name,
            descriptor.storageCodec.name,
            descriptor.storedByteLength,
            _clock().toUtc().microsecondsSinceEpoch,
          ],
        );
        final rows = await _database
            .customSelect(
              '''SELECT sha256, privacy_class, storage_codec, stored_byte_length
                 FROM diagnostic_objects WHERE object_key = ?''',
              variables: <Variable<Object>>[Variable.withString(objectKey)],
            )
            .get();
        final row = rows.single.data;
        if (row['sha256'] != descriptor.sha256 ||
            row['privacy_class'] != descriptor.privacyClass.name ||
            row['storage_codec'] != descriptor.storageCodec.name ||
            row['stored_byte_length'] != descriptor.storedByteLength) {
          throw StateError('Diagnostic object metadata collision.');
        }
      }
      await _database.customStatement(
        '''INSERT INTO diagnostic_attachments (
          attachment_id, event_id, object_key, kind, media_type, charset,
          format_id, format_version, schema_id, schema_version, privacy_class,
          capture_state, raw_byte_length, stored_byte_length, sha256,
          storage_codec, redaction_version, truncation_reason
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
        <Object?>[
          descriptor.attachmentId,
          descriptor.eventId,
          objectKey,
          descriptor.kind,
          descriptor.mediaType,
          descriptor.charset,
          descriptor.formatId,
          descriptor.formatVersion,
          descriptor.schemaId,
          descriptor.schemaVersion,
          descriptor.privacyClass.name,
          descriptor.captureState.name,
          descriptor.rawByteLength,
          descriptor.storedByteLength,
          descriptor.sha256,
          descriptor.storageCodec.name,
          descriptor.redactionVersion,
          descriptor.truncationReason,
        ],
      );
      if (objectKey != null) {
        await _database.customStatement(
          'UPDATE diagnostic_objects SET reference_count = reference_count + 1 WHERE object_key = ?',
          <Object?>[objectKey],
        );
      }
      await _database.customStatement(
        '''UPDATE diagnostic_events
           SET attachment_count = ?, captured_bytes = ?, envelope_json = ?
           WHERE event_id = ?''',
        <Object?>[
          updatedEvent.attachmentCount,
          updatedEvent.capturedBytes,
          jsonEncode(_eventCodec.encode(updatedEvent)),
          descriptor.eventId,
        ],
      );
      await _database.customStatement(
        '''UPDATE diagnostic_capture_sessions
           SET attachment_count = attachment_count + 1,
               stored_bytes = stored_bytes + ?
           WHERE session_id = ?''',
        <Object?>[descriptor.storedByteLength, event.captureSessionId],
      );
      await _database.customStatement(
        '''UPDATE diagnostic_runs
           SET attachment_count = attachment_count + 1,
               stored_bytes = stored_bytes + ?
           WHERE source_run_id = ?''',
        <Object?>[descriptor.storedByteLength, event.sourceRunId],
      );
    });
    return descriptor;
  }

  Future<List<DiagnosticAttachmentDescriptor>> listAttachments(
    String eventId,
  ) async {
    _ensureOpen();
    validateDiagnosticOpaqueId(eventId, 'eventId');
    final rows = await _database
        .customSelect(
          '''SELECT * FROM diagnostic_attachments WHERE event_id = ?
             ORDER BY attachment_id ASC''',
          variables: <Variable<Object>>[Variable.withString(eventId)],
        )
        .get();
    return rows.map((row) => _attachmentFromRow(row.data)).toList();
  }

  Stream<List<int>> openAttachment(
    String attachmentId, {
    DiagnosticByteRange? range,
  }) async* {
    _ensureOpen();
    validateDiagnosticOpaqueId(attachmentId, 'attachmentId');
    final rows = await _database
        .customSelect(
          'SELECT object_key FROM diagnostic_attachments WHERE attachment_id = ?',
          variables: <Variable<Object>>[Variable.withString(attachmentId)],
        )
        .get();
    if (rows.isEmpty) throw StateError('Diagnostic attachment does not exist.');
    final objectKey = rows.single.data['object_key'] as String?;
    if (objectKey == null) {
      throw StateError('Diagnostic attachment payload was not captured.');
    }
    yield* objectStore.openObject(objectKey, range: range);
  }

  Future<void> recoverInterruptedState() async {
    _ensureOpen();
    final now = _clock().toUtc().microsecondsSinceEpoch;
    await _database.transaction(() async {
      await _database.customStatement(
        '''UPDATE diagnostic_capture_sessions SET state = ?,
           ended_at_utc_micros = COALESCE(ended_at_utc_micros, ?)
           WHERE state = ?''',
        <Object?>[
          DiagnosticSessionState.ended.name,
          now,
          DiagnosticSessionState.active.name,
        ],
      );
      await _database.customStatement(
        '''UPDATE diagnostic_runs SET state = ?,
           ended_at_utc_micros = COALESCE(ended_at_utc_micros, ?)
           WHERE state = ?''',
        <Object?>['incomplete', now, 'active'],
      );
    });
    await objectStore.cleanStaging();
  }

  Future<void> reconcileObjects() async {
    _ensureOpen();
    final references = await _database.customSelect(
      '''SELECT object_key, COUNT(*) AS actual_count
             FROM diagnostic_attachments WHERE object_key IS NOT NULL
             GROUP BY object_key''',
    ).get();
    final referenced = <String>{};
    for (final row in references) {
      final objectKey = row.data['object_key'] as String;
      referenced.add(objectKey);
      await _database.customStatement(
        'UPDATE diagnostic_objects SET reference_count = ? WHERE object_key = ?',
        <Object?>[row.data['actual_count'] as int, objectKey],
      );
    }
    final objectRows = await _database
        .customSelect('SELECT object_key FROM diagnostic_objects')
        .get();
    for (final row in objectRows) {
      final objectKey = row.data['object_key'] as String;
      if (referenced.contains(objectKey)) continue;
      if (await objectStore.delete(objectKey)) {
        await _database.customStatement(
          'DELETE FROM diagnostic_objects WHERE object_key = ?',
          <Object?>[objectKey],
        );
      }
    }
    final files = await objectStore.listObjectKeys();
    final indexed = objectRows
        .map((row) => row.data['object_key'] as String)
        .toSet();
    for (final objectKey in files.difference(indexed)) {
      await objectStore.delete(objectKey);
    }
  }

  Future<DiagnosticMaintenanceResult> enforceRetention(
    DiagnosticRetentionPolicy policy,
  ) async {
    _ensureOpen();
    policy.validate();
    final now = _clock().toUtc().microsecondsSinceEpoch;
    final candidates = await _database
        .customSelect(
          '''SELECT session_id FROM diagnostic_capture_sessions
             WHERE state != ? AND (
               (is_default = 1 AND started_at_utc_micros <= ?)
               OR
               (is_default = 0 AND COALESCE(ended_at_utc_micros,
                 started_at_utc_micros) <= ?)
             ) ORDER BY started_at_utc_micros ASC''',
          variables: <Variable<Object>>[
            Variable.withString(DiagnosticSessionState.active.name),
            Variable.withInt(now - policy.regularEventAge.inMicroseconds),
            Variable.withInt(now - policy.captureAge.inMicroseconds),
          ],
        )
        .get();
    var deletedSessions = 0;
    var deletedEvents = 0;
    var deletedObjects = 0;
    var reclaimedBytes = 0;
    for (final row in candidates) {
      final result = await deleteSession(row.data['session_id'] as String);
      deletedSessions += 1;
      deletedEvents += result.deletedEvents;
      deletedObjects += result.deletedObjects;
      reclaimedBytes += result.reclaimedBytes;
    }

    Future<void> trimEndedSessions({
      required String where,
      required int byteLimit,
    }) async {
      while (true) {
        final totalRows = await _database.customSelect(
          '''SELECT COALESCE(SUM(stored_bytes), 0) AS total
                 FROM diagnostic_capture_sessions WHERE $where''',
        ).get();
        if ((totalRows.single.data['total'] as int) <= byteLimit) return;
        final oldest = await _database
            .customSelect(
              '''SELECT session_id FROM diagnostic_capture_sessions
                 WHERE state != ? AND $where
                 ORDER BY started_at_utc_micros ASC, session_id ASC LIMIT 1''',
              variables: <Variable<Object>>[
                Variable.withString(DiagnosticSessionState.active.name),
              ],
            )
            .get();
        if (oldest.isEmpty) return;
        final result = await deleteSession(
          oldest.single.data['session_id'] as String,
        );
        deletedSessions += result.deletedSessions;
        deletedEvents += result.deletedEvents;
        deletedObjects += result.deletedObjects;
        reclaimedBytes += result.reclaimedBytes;
      }
    }

    await trimEndedSessions(
      where: 'is_default = 0',
      byteLimit: policy.captureBytes,
    );
    await trimEndedSessions(
      where: 'is_default = 1',
      byteLimit: policy.regularEventBytes,
    );
    await trimEndedSessions(where: '1 = 1', byteLimit: policy.globalHardBytes);
    await reconcileObjects();
    await checkpointWal();
    return DiagnosticMaintenanceResult(
      deletedSessions: deletedSessions,
      deletedEvents: deletedEvents,
      deletedObjects: deletedObjects,
      reclaimedBytes: reclaimedBytes,
    );
  }

  Future<DiagnosticMaintenanceResult> deleteSession(String sessionId) async {
    _ensureOpen();
    validateDiagnosticOpaqueId(sessionId, 'sessionId');
    final sessionRows = await _database
        .customSelect(
          '''SELECT source_run_id, is_default, state, event_count,
             attachment_count, stored_bytes
             FROM diagnostic_capture_sessions WHERE session_id = ?''',
          variables: <Variable<Object>>[Variable.withString(sessionId)],
        )
        .get();
    if (sessionRows.isEmpty) {
      return const DiagnosticMaintenanceResult(
        deletedSessions: 0,
        deletedEvents: 0,
        deletedObjects: 0,
        reclaimedBytes: 0,
      );
    }
    final sessionRow = sessionRows.single.data;
    if (sessionRow['state'] == DiagnosticSessionState.active.name) {
      throw StateError('An active diagnostic session cannot be deleted.');
    }
    final isDefault = (sessionRow['is_default'] as int) != 0;
    final sourceRunId = sessionRow['source_run_id'] as String;
    final deletedSessionRows = isDefault
        ? await _database
              .customSelect(
                '''SELECT COUNT(*) AS count FROM diagnostic_capture_sessions
                   WHERE source_run_id = ?''',
                variables: <Variable<Object>>[Variable.withString(sourceRunId)],
              )
              .get()
        : null;
    final eventCountRows = await _database
        .customSelect(
          isDefault
              ? 'SELECT COUNT(*) AS count FROM diagnostic_events WHERE source_run_id = ?'
              : 'SELECT COUNT(*) AS count FROM diagnostic_events WHERE capture_session_id = ?',
          variables: <Variable<Object>>[
            Variable.withString(isDefault ? sourceRunId : sessionId),
          ],
        )
        .get();
    final eventCount = eventCountRows.single.data['count'] as int;
    final objectRows = await _database
        .customSelect(
          isDefault
              ? '''SELECT DISTINCT a.object_key FROM diagnostic_attachments a
                   JOIN diagnostic_events e ON e.event_id = a.event_id
                   WHERE e.source_run_id = ? AND a.object_key IS NOT NULL'''
              : '''SELECT DISTINCT a.object_key FROM diagnostic_attachments a
                   JOIN diagnostic_events e ON e.event_id = a.event_id
                   WHERE e.capture_session_id = ? AND a.object_key IS NOT NULL''',
          variables: <Variable<Object>>[
            Variable.withString(isDefault ? sourceRunId : sessionId),
          ],
        )
        .get();
    final objectKeys = objectRows
        .map((row) => row.data['object_key'] as String)
        .toList();
    await _database.transaction(() async {
      await _database.customStatement(
        'UPDATE diagnostic_capture_sessions SET state = ? WHERE session_id = ?',
        <Object?>[DiagnosticSessionState.deleting.name, sessionId],
      );
      if (isDefault) {
        await _database.customStatement(
          'DELETE FROM diagnostic_runs WHERE source_run_id = ?',
          <Object?>[sourceRunId],
        );
      } else {
        await _database.customStatement(
          'DELETE FROM diagnostic_capture_sessions WHERE session_id = ?',
          <Object?>[sessionId],
        );
        await _database.customStatement(
          '''UPDATE diagnostic_runs SET
               event_count = MAX(0, event_count - ?),
               attachment_count = MAX(0, attachment_count - ?),
               stored_bytes = MAX(0, stored_bytes - ?)
             WHERE source_run_id = ?''',
          <Object?>[
            sessionRow['event_count'] as int,
            sessionRow['attachment_count'] as int,
            sessionRow['stored_bytes'] as int,
            sourceRunId,
          ],
        );
      }
      for (final objectKey in objectKeys) {
        final countRows = await _database
            .customSelect(
              'SELECT COUNT(*) AS count FROM diagnostic_attachments WHERE object_key = ?',
              variables: <Variable<Object>>[Variable.withString(objectKey)],
            )
            .get();
        final count = countRows.single.data['count'] as int;
        await _database.customStatement(
          'UPDATE diagnostic_objects SET reference_count = ? WHERE object_key = ?',
          <Object?>[count, objectKey],
        );
      }
    });
    var deletedObjects = 0;
    var reclaimedBytes = 0;
    for (final objectKey in objectKeys) {
      final rows = await _database
          .customSelect(
            '''SELECT stored_byte_length, reference_count FROM diagnostic_objects
               WHERE object_key = ?''',
            variables: <Variable<Object>>[Variable.withString(objectKey)],
          )
          .get();
      if (rows.isEmpty || (rows.single.data['reference_count'] as int) > 0) {
        continue;
      }
      if (await objectStore.delete(objectKey)) {
        reclaimedBytes += rows.single.data['stored_byte_length'] as int;
        deletedObjects += 1;
        await _database.customStatement(
          'DELETE FROM diagnostic_objects WHERE object_key = ?',
          <Object?>[objectKey],
        );
      }
    }
    return DiagnosticMaintenanceResult(
      deletedSessions: isDefault
          ? deletedSessionRows!.single.data['count'] as int
          : 1,
      deletedEvents: eventCount,
      deletedObjects: deletedObjects,
      reclaimedBytes: reclaimedBytes,
    );
  }

  Future<DiagnosticStorageStatistics> getStatistics() async {
    _ensureOpen();
    Future<int> scalar(String sql) async {
      final rows = await _database.customSelect(sql).get();
      return rows.single.data.values.single as int;
    }

    final wal = File('$databasePath-wal');
    final index = File(databasePath);
    return DiagnosticStorageStatistics(
      runCount: await scalar('SELECT COUNT(*) FROM diagnostic_runs'),
      sessionCount: await scalar(
        'SELECT COUNT(*) FROM diagnostic_capture_sessions',
      ),
      eventCount: await scalar('SELECT COUNT(*) FROM diagnostic_events'),
      attachmentCount: await scalar(
        'SELECT COUNT(*) FROM diagnostic_attachments',
      ),
      objectCount: await scalar('SELECT COUNT(*) FROM diagnostic_objects'),
      objectBytes: await scalar(
        'SELECT COALESCE(SUM(stored_byte_length), 0) FROM diagnostic_objects',
      ),
      logicalStoredBytes: await scalar(
        'SELECT COALESCE(SUM(stored_bytes), 0) FROM diagnostic_runs',
      ),
      indexBytes: await index.exists() ? await index.length() : 0,
      walBytes: await wal.exists() ? await wal.length() : 0,
    );
  }

  Future<void> checkpointWal() async {
    _ensureOpen();
    await _database.customSelect('PRAGMA wal_checkpoint(PASSIVE)').get();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _database.close();
    await objectStore.close();
  }

  DiagnosticEvent _eventFromRow(Map<String, Object?> row) {
    final decoded = jsonDecode(row['envelope_json'] as String);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Diagnostic event envelope is invalid.');
    }
    return _eventCodec.decode(decoded);
  }

  DiagnosticSession _sessionFromRow(Map<String, Object?> row) =>
      DiagnosticSession(
        sessionId: row['session_id'] as String,
        source: _enumByName(
          DiagnosticSource.values,
          row['source'] as String,
          'source',
        ),
        sourceRunId: row['source_run_id'] as String,
        startedAtUtcMicros: row['started_at_utc_micros'] as int,
        endedAtUtcMicros: row['ended_at_utc_micros'] as int?,
        expiresAtUtcMicros: row['expires_at_utc_micros'] as int?,
        state: _enumByName(
          DiagnosticSessionState.values,
          row['state'] as String,
          'session state',
        ),
        payloadKind: _enumByName(
          DiagnosticPayloadKind.values,
          row['payload_kind'] as String,
          'payload kind',
        ),
        eventCount: row['event_count'] as int,
        attachmentCount: row['attachment_count'] as int,
        storedBytes: row['stored_bytes'] as int,
      );

  DiagnosticAttachmentDescriptor _attachmentFromRow(Map<String, Object?> row) =>
      DiagnosticAttachmentDescriptor(
        attachmentId: row['attachment_id'] as String,
        eventId: row['event_id'] as String,
        kind: row['kind'] as String,
        mediaType: row['media_type'] as String,
        charset: row['charset'] as String?,
        formatId: row['format_id'] as String,
        formatVersion: row['format_version'] as int,
        schemaId: row['schema_id'] as String?,
        schemaVersion: row['schema_version'] as int?,
        privacyClass: _enumByName(
          DiagnosticPrivacyClass.values,
          row['privacy_class'] as String,
          'privacy class',
        ),
        captureState: _enumByName(
          DiagnosticCaptureState.values,
          row['capture_state'] as String,
          'capture state',
        ),
        rawByteLength: row['raw_byte_length'] as int,
        storedByteLength: row['stored_byte_length'] as int,
        sha256: row['sha256'] as String?,
        storageCodec: _enumByName(
          DiagnosticStorageCodec.values,
          row['storage_codec'] as String,
          'storage codec',
        ),
        redactionVersion: row['redaction_version'] as int,
        truncationReason: row['truncation_reason'] as String?,
      );

  void _validateLimit(int limit) {
    if (limit <= 0 || limit > maxQueryPageSize) {
      throw RangeError.range(limit, 1, maxQueryPageSize, 'limit');
    }
  }

  void _ensureOpen() {
    if (_closed) throw StateError('DiagnosticsPersistence is closed.');
  }
}

final class _DiagnosticsDatabase extends GeneratedDatabase {
  _DiagnosticsDatabase(super.executor);

  @override
  int get schemaVersion => DiagnosticsPersistence.schemaVersion;

  @override
  Iterable<TableInfo<Table, dynamic>> get allTables => const [];
}

final class _EncodedDiagnosticEvents {
  const _EncodedDiagnosticEvents(this.payloads, this.workerIsolateId);

  final List<String> payloads;
  final int workerIsolateId;
}

final class _DiagnosticEventEncodeTask {
  const _DiagnosticEventEncodeTask(this.events);

  final List<DiagnosticEvent> events;

  _EncodedDiagnosticEvents call() {
    const codec = DiagnosticEventCodec();
    return _EncodedDiagnosticEvents(
      events
          .map((event) => jsonEncode(codec.encode(event)))
          .toList(growable: false),
      Isolate.current.hashCode,
    );
  }
}

void _addStringSetFilter(
  List<String> where,
  List<Variable<Object>> variables,
  String column,
  Set<String> values,
) {
  if (values.isEmpty) return;
  where.add('$column IN (${_placeholders(values.length)})');
  variables.addAll(values.map(Variable.withString));
}

String _placeholders(int count) => List<String>.filled(count, '?').join(', ');

DiagnosticCursor _encodeCursor(String kind, int micros, String id) {
  final bytes = utf8.encode(jsonEncode(<Object?>[kind, micros, id]));
  return DiagnosticCursor(base64Url.encode(bytes).replaceAll('=', ''));
}

(int, String) _decodeCursor(DiagnosticCursor cursor, String expectedKind) {
  final padding = '=' * ((4 - cursor.value.length % 4) % 4);
  final decoded = jsonDecode(
    utf8.decode(base64Url.decode('${cursor.value}$padding')),
  );
  if (decoded is! List<Object?> ||
      decoded.length != 3 ||
      decoded[0] != expectedKind ||
      decoded[1] is! int ||
      decoded[2] is! String) {
    throw const FormatException('Diagnostic cursor does not match the query.');
  }
  return (decoded[1]! as int, decoded[2]! as String);
}

Set<String> _decodeStringSet(String encoded) {
  final value = jsonDecode(encoded);
  if (value is! List<Object?> || value.any((item) => item is! String)) {
    throw const FormatException('Diagnostic allowlist is invalid.');
  }
  return value.cast<String>().toSet();
}

T _enumByName<T extends Enum>(List<T> values, String name, String label) {
  for (final value in values) {
    if (value.name == name) return value;
  }
  throw FormatException('Unknown diagnostic $label: $name.');
}

DateTime _utcNow() => DateTime.now().toUtc();
