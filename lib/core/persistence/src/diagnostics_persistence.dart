/// 应用诊断 TXT 持久化库。
///
/// 职责：
/// - 写入、恢复和查询有界分段诊断记录。
/// - 管理详情附件、保留策略和旧日志清理。
///
/// 注意：
/// - 诊断失败不得影响业务结果，也不得形成 SQLite/WAL 索引。
/// - 默认只保存元数据；正文、凭据和原始异常不得进入持久化内容。
///
/// TODO:
/// - 无。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:mg_read/core/diagnostics/src/diagnostic_event.dart';
import 'package:mg_read/core/diagnostics/src/diagnostic_ports.dart';

import 'diagnostic_text_detail_store.dart';

part 'diagnostics_persistence_models.dart';
part 'diagnostics_persistence_text.dart';

/// App-owned segmented TXT diagnostics store.
///
/// Event records are newline-delimited JSON in bounded `.txt` segments. The
/// in-memory catalog is rebuilt in an isolate at startup and is never a second
/// persistent index.
final class DiagnosticsPersistence {
  DiagnosticsPersistence._(this.diagnosticsRoot, this.eventsRoot, this.detailStore, this._clock);

  static const int textFormatVersion = 1;
  static const int maxWriteBatchSize = 128;
  static const int maxQueryPageSize = 200;
  static const int maxSegmentBytes = 4 * 1024 * 1024;

  final Directory diagnosticsRoot;
  final Directory eventsRoot;
  final DiagnosticTextDetailStore detailStore;
  final DateTime Function() _clock;
  final DiagnosticEventCodec _eventCodec = const DiagnosticEventCodec();
  final Map<String, _RunRecord> _runs = <String, _RunRecord>{};
  final Map<String, _SessionRecord> _sessions = <String, _SessionRecord>{};
  final Map<String, DiagnosticEvent> _events = <String, DiagnosticEvent>{};
  final Map<String, _AttachmentRecord> _attachments = <String, _AttachmentRecord>{};
  final Map<String, int> _segmentSequenceByRun = <String, int>{};
  Future<void> _writeTail = Future<void>.value();
  File? _activeSegment;
  String? _activeSegmentRunId;
  var _activeSegmentBytes = 0;
  bool _closed = false;
  int? _lastEncoderWorkerIsolateId;

  bool get usesBackgroundExecutor => true;

  int? get lastEncoderWorkerIsolateIdForTest => _lastEncoderWorkerIsolateId;

  static Future<DiagnosticsPersistence> open({
    required Directory dataRoot,
    DateTime Function() clock = _utcNow,
    int detailMemoryBytes = DiagnosticTextDetailStore.defaultMaxMemoryBytes,
  }) async {
    final diagnosticsRoot = Directory('${dataRoot.path}${Platform.pathSeparator}diagnostics');
    final eventsRoot = Directory('${diagnosticsRoot.path}${Platform.pathSeparator}events');
    await Future.wait(<Future<void>>[diagnosticsRoot.create(recursive: true), eventsRoot.create(recursive: true)]);
    await _removeLegacyDatabaseArtifacts(diagnosticsRoot);
    final detailStore = await DiagnosticTextDetailStore.open(diagnosticsRoot, maxMemoryBytes: detailMemoryBytes);
    final store = DiagnosticsPersistence._(diagnosticsRoot, eventsRoot, detailStore, clock);
    try {
      final loaded = await Isolate.run(_DiagnosticTextLoadTask(eventsRoot.path).call, debugName: 'mg-read-diagnostics-text-rebuild');
      store._lastEncoderWorkerIsolateId = loaded.workerIsolateId;
      for (final entry in loaded.segmentBytes.entries) {
        store._updateSegmentSequence(entry.key);
      }
      for (final record in loaded.records) {
        store._applyRecord(record, fromDisk: true);
      }
      await store.recoverInterruptedState();
      await store.reconcileDetails();
      return store;
    } catch (_) {
      await detailStore.close();
      rethrow;
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
    final run = _RunRecord(sourceRunId: sourceRunId, source: source, startedAtUtcMicros: now);
    final session = _SessionRecord(
      sessionId: sourceRunId,
      sourceRunId: sourceRunId,
      source: source,
      startedAtUtcMicros: now,
      expiresAtUtcMicros: now + regularSessionAge.inMicroseconds,
      payloadKind: DiagnosticPayloadKind.metadataOnly,
      maxStoredBytes: regularSessionMaxBytes,
      components: const <String>{},
      origins: const <String>{},
      isDefault: true,
      detailStorage: DiagnosticDetailStorage.memoryOnly,
    );
    await _exclusive(() async {
      if (_runs.containsKey(sourceRunId)) {
        throw StateError('Diagnostic run already exists.');
      }
      await _appendRecords(sourceRunId, <Map<String, Object?>>[_runStartRecord(run), _sessionStartRecord(session)]);
      _runs[sourceRunId] = run;
      _sessions[sourceRunId] = session;
    });
  }

  Future<void> endRun(String sourceRunId) async {
    _ensureOpen();
    final now = _clock().toUtc().microsecondsSinceEpoch;
    await _exclusive(() async {
      final run = _runs[sourceRunId];
      if (run == null || run.endedAtUtcMicros != null) return;
      final records = <Map<String, Object?>>[];
      for (final session in _sessions.values.where(
        (item) => item.sourceRunId == sourceRunId && item.state == DiagnosticSessionState.active,
      )) {
        records.add(_sessionEndRecord(session.sessionId, now, 'ended'));
      }
      records.add(_runEndRecord(sourceRunId, now, 'ended'));
      await _appendRecords(sourceRunId, records);
      for (final session in _sessions.values.where((item) => item.sourceRunId == sourceRunId)) {
        if (session.state == DiagnosticSessionState.active) {
          session
            ..state = DiagnosticSessionState.ended
            ..endedAtUtcMicros = now;
        }
      }
      run
        ..state = 'ended'
        ..endedAtUtcMicros = now;
    });
  }

  Future<void> insertEvents(List<DiagnosticEvent> events) async {
    _ensureOpen();
    if (events.isEmpty) return;
    if (events.length > maxWriteBatchSize) {
      throw ArgumentError('At most $maxWriteBatchSize events may be written.');
    }
    final storedEvents = events
        .map((event) => event.captureSessionId == null ? event.copyWith(captureSessionId: event.sourceRunId) : event)
        .toList(growable: false);
    final encoded = await Isolate.run(_DiagnosticEventEncodeTask(storedEvents).call, debugName: 'mg-read-diagnostics-text-encode');
    _lastEncoderWorkerIsolateId = encoded.workerIsolateId;
    await _exclusive(() async {
      for (final event in storedEvents) {
        if (!_runs.containsKey(event.sourceRunId)) {
          throw StateError('Diagnostic event run does not exist.');
        }
        if (_events.containsKey(event.eventId)) {
          throw StateError('Diagnostic event already exists.');
        }
      }
      await _appendEncodedLines(storedEvents.first.sourceRunId, encoded.lines);
      for (var index = 0; index < storedEvents.length; index += 1) {
        final event = storedEvents[index];
        _events[event.eventId] = event;
        final lineBytes = utf8.encode('${encoded.lines[index]}\n').length;
        final run = _runs[event.sourceRunId]!;
        run
          ..eventCount += 1
          ..storedBytes += lineBytes;
        final session = _sessions[event.captureSessionId!];
        if (session != null) {
          session
            ..eventCount += 1
            ..storedBytes += lineBytes;
        }
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
    await _writeTail;
    final anchor = cursor == null ? null : _decodeCursor(cursor, 'sessions');
    final sessions =
        _sessions.values
            .where((session) => _matchesSession(session, filter))
            .map((session) => session.toPublic())
            .where(
              (session) =>
                  anchor == null ||
                  session.startedAtUtcMicros < anchor.$1 ||
                  (session.startedAtUtcMicros == anchor.$1 && session.sessionId.compareTo(anchor.$2) < 0),
            )
            .toList(growable: false)
          ..sort(_compareSessionsDescending);
    final hasMore = sessions.length > limit;
    final page = hasMore ? sessions.take(limit).toList() : sessions;
    final tail = page.isEmpty ? null : page.last;
    return DiagnosticPage<DiagnosticSession>(
      items: page,
      nextCursor: hasMore && tail != null ? _encodeCursor('sessions', tail.startedAtUtcMicros, tail.sessionId) : null,
    );
  }

  Future<DiagnosticPage<DiagnosticEvent>> listEvents({
    required DiagnosticEventFilter filter,
    DiagnosticCursor? cursor,
    int limit = 100,
  }) async {
    _ensureOpen();
    _validateLimit(limit);
    await _writeTail;
    final anchor = cursor == null ? null : _decodeCursor(cursor, 'events');
    final events =
        _events.values
            .where((event) => _matchesEvent(event, filter))
            .where(
              (event) =>
                  anchor == null ||
                  event.occurredAtUtcMicros < anchor.$1 ||
                  (event.occurredAtUtcMicros == anchor.$1 && event.eventId.compareTo(anchor.$2) < 0),
            )
            .toList(growable: false)
          ..sort(_compareEventsDescending);
    final hasMore = events.length > limit;
    final page = hasMore ? events.take(limit).toList() : events;
    final tail = page.isEmpty ? null : page.last;
    return DiagnosticPage<DiagnosticEvent>(
      items: page,
      nextCursor: hasMore && tail != null ? _encodeCursor('events', tail.occurredAtUtcMicros, tail.eventId) : null,
    );
  }

  Future<DiagnosticEvent?> getEvent(String eventId) async {
    _ensureOpen();
    validateDiagnosticOpaqueId(eventId, 'eventId');
    await _writeTail;
    return _events[eventId];
  }

  Future<DiagnosticStoredCaptureSession?> getCaptureSession(String sessionId) async {
    _ensureOpen();
    validateDiagnosticOpaqueId(sessionId, 'sessionId');
    await _writeTail;
    return _sessions[sessionId]?.toStored();
  }

  Future<DiagnosticSession> createCaptureSession({
    required String sessionId,
    required String sourceRunId,
    required DiagnosticCapturePolicy policy,
  }) async {
    _ensureOpen();
    validateDiagnosticOpaqueId(sessionId, 'sessionId');
    final now = _clock().toUtc().microsecondsSinceEpoch;
    final run = _runs[sourceRunId];
    if (run == null) throw StateError('Diagnostic run does not exist.');
    final session = _SessionRecord(
      sessionId: sessionId,
      sourceRunId: sourceRunId,
      source: run.source,
      startedAtUtcMicros: now,
      expiresAtUtcMicros: now + policy.duration.inMicroseconds,
      payloadKind: policy.payloadKind,
      maxStoredBytes: policy.maxStoredBytes,
      components: policy.components,
      origins: policy.origins,
      isDefault: false,
      detailStorage: policy.detailStorage,
    );
    await _exclusive(() async {
      if (_sessions.containsKey(sessionId)) {
        throw StateError('Diagnostic capture session already exists.');
      }
      await _appendRecords(sourceRunId, <Map<String, Object?>>[_sessionStartRecord(session)]);
      _sessions[sessionId] = session;
    });
    return session.toPublic();
  }

  Future<void> stopCaptureSession(String sessionId) async {
    _ensureOpen();
    final now = _clock().toUtc().microsecondsSinceEpoch;
    await _exclusive(() async {
      final session = _sessions[sessionId];
      if (session == null || session.state != DiagnosticSessionState.active) {
        return;
      }
      await _appendRecords(session.sourceRunId, <Map<String, Object?>>[_sessionEndRecord(sessionId, now, 'ended')]);
      session
        ..state = DiagnosticSessionState.ended
        ..endedAtUtcMicros = now;
      if (session.detailStorage == DiagnosticDetailStorage.memoryOnly) {
        final keys = _attachments.values
            .where((item) => _events[item.descriptor.eventId]?.captureSessionId == sessionId && !item.persisted)
            .map((item) => item.detailKey)
            .whereType<String>();
        await detailStore.clearMemoryDetails(keys);
      }
    });
  }

  Future<DiagnosticAttachmentDescriptor> commitAttachment({
    required DiagnosticAttachmentDescriptor descriptor,
    required String? objectKey,
    bool persisted = true,
  }) async {
    _ensureOpen();
    return _exclusive(() async {
      final event = _events[descriptor.eventId];
      if (event == null) throw StateError('Attachment event does not exist.');
      final session = _sessions[event.captureSessionId!];
      final record = _AttachmentRecord(descriptor: descriptor, detailKey: objectKey, persisted: objectKey != null && persisted);
      await _appendRecords(event.sourceRunId, <Map<String, Object?>>[_attachmentRecord(record)]);
      _attachments[descriptor.attachmentId] = record;
      _events[event.eventId] = _eventWithAttachment(event, descriptor);
      final run = _runs[event.sourceRunId];
      if (run != null) {
        run
          ..attachmentCount += 1
          ..storedBytes += descriptor.storedByteLength;
      }
      if (session != null) {
        session
          ..attachmentCount += 1
          ..storedBytes += descriptor.storedByteLength;
      }
      return descriptor;
    });
  }

  Future<List<DiagnosticAttachmentDescriptor>> listAttachments(String eventId) async {
    _ensureOpen();
    validateDiagnosticOpaqueId(eventId, 'eventId');
    await _writeTail;
    final result =
        _attachments.values.where((item) => item.descriptor.eventId == eventId).map((item) => item.descriptor).toList(growable: false)
          ..sort((left, right) => left.attachmentId.compareTo(right.attachmentId));
    return result;
  }

  Stream<List<int>> openAttachment(String attachmentId, {DiagnosticByteRange? range}) async* {
    _ensureOpen();
    validateDiagnosticOpaqueId(attachmentId, 'attachmentId');
    await _writeTail;
    final attachment = _attachments[attachmentId];
    if (attachment == null) {
      throw StateError('Diagnostic attachment does not exist.');
    }
    final detailKey = attachment.detailKey;
    if (detailKey == null) {
      throw StateError('Diagnostic attachment payload was not captured.');
    }
    yield* detailStore.openDetail(detailKey, range: range);
  }

  Future<void> recoverInterruptedState() async {
    _ensureOpen();
    final now = _clock().toUtc().microsecondsSinceEpoch;
    final activeSessions = _sessions.values.where((item) => item.state == DiagnosticSessionState.active).toList(growable: false);
    final activeRuns = _runs.values.where((item) => item.state == 'active').toList(growable: false);
    if (activeSessions.isEmpty && activeRuns.isEmpty) {
      await detailStore.cleanStaging();
      return;
    }
    await _exclusive(() async {
      final byRun = <String, List<Map<String, Object?>>>{};
      for (final session in activeSessions) {
        byRun.putIfAbsent(session.sourceRunId, () => <Map<String, Object?>>[]).add(_sessionEndRecord(session.sessionId, now, 'ended'));
      }
      for (final run in activeRuns) {
        byRun.putIfAbsent(run.sourceRunId, () => <Map<String, Object?>>[]).add(_runEndRecord(run.sourceRunId, now, 'incomplete'));
      }
      for (final entry in byRun.entries) {
        await _appendRecords(entry.key, entry.value);
      }
      for (final session in activeSessions) {
        session
          ..state = DiagnosticSessionState.ended
          ..endedAtUtcMicros = now;
      }
      for (final run in activeRuns) {
        run
          ..state = 'incomplete'
          ..endedAtUtcMicros = now;
      }
    });
    await detailStore.cleanStaging();
  }

  Future<void> reconcileDetails() async {
    _ensureOpen();
    final referenced = _attachments.values.where((item) => item.persisted && item.detailKey != null).map((item) => item.detailKey!).toSet();
    final stored = await detailStore.listDetailKeys();
    for (final key in stored.difference(referenced)) {
      await detailStore.delete(key);
    }
  }

  Future<DiagnosticMaintenanceResult> enforceRetention(DiagnosticRetentionPolicy policy) async {
    _ensureOpen();
    policy.validate();
    return _exclusive(() async {
      final now = _clock().toUtc().microsecondsSinceEpoch;
      final targets = <String>{};
      for (final session in _sessions.values) {
        if (session.state == DiagnosticSessionState.active) continue;
        final anchor = session.isDefault ? session.startedAtUtcMicros : session.endedAtUtcMicros ?? session.startedAtUtcMicros;
        final age = session.isDefault ? policy.regularEventAge : policy.captureAge;
        if (anchor <= now - age.inMicroseconds) targets.add(session.sessionId);
      }
      _addByteTrimTargets(targets, sessions: _sessions.values.where((item) => item.isDefault), byteLimit: policy.regularEventBytes);
      _addByteTrimTargets(targets, sessions: _sessions.values.where((item) => !item.isDefault), byteLimit: policy.captureBytes);
      _addByteTrimTargets(targets, sessions: _sessions.values, byteLimit: policy.globalHardBytes);
      var deletedSessions = 0;
      var deletedEvents = 0;
      var deletedDetails = 0;
      var reclaimedBytes = 0;
      for (final sessionId in targets.toList(growable: false)) {
        final result = await _deleteSessionInternal(sessionId);
        deletedSessions += result.deletedSessions;
        deletedEvents += result.deletedEvents;
        deletedDetails += result.deletedObjects;
        reclaimedBytes += result.reclaimedBytes;
      }
      if (targets.isNotEmpty) await _compactCatalog();
      await reconcileDetails();
      return DiagnosticMaintenanceResult(
        deletedSessions: deletedSessions,
        deletedEvents: deletedEvents,
        deletedObjects: deletedDetails,
        reclaimedBytes: reclaimedBytes,
      );
    });
  }

  Future<DiagnosticMaintenanceResult> deleteSession(String sessionId) async {
    _ensureOpen();
    validateDiagnosticOpaqueId(sessionId, 'sessionId');
    return _exclusive(() async {
      final result = await _deleteSessionInternal(sessionId);
      if (result.deletedSessions > 0) await _compactCatalog();
      return result;
    });
  }

  Future<DiagnosticStorageStatistics> getStatistics() async {
    _ensureOpen();
    await _writeTail;
    var eventBytes = 0;
    var segmentCount = 0;
    if (await eventsRoot.exists()) {
      await for (final entity in eventsRoot.list(followLinks: false)) {
        if (entity is! File || !entity.path.endsWith('.txt')) continue;
        segmentCount += 1;
        eventBytes += await entity.length();
      }
    }
    final details = await detailStore.getStatistics();
    return DiagnosticStorageStatistics(
      runCount: _runs.length,
      sessionCount: _sessions.length,
      eventCount: _events.length,
      attachmentCount: _attachments.length,
      segmentCount: segmentCount,
      detailCount: details.detailCount,
      eventTextBytes: eventBytes,
      detailTextBytes: details.detailTextBytes,
      memoryDetailBytes: details.memoryDetailBytes,
      logicalStoredBytes: eventBytes + details.detailTextBytes + details.memoryDetailBytes,
    );
  }

  Future<void> flushText() async {
    _ensureOpen();
    await _writeTail;
  }

  Future<void> close() async {
    if (_closed) return;
    await _writeTail;
    _closed = true;
    await detailStore.close();
  }

  Future<T> _exclusive<T>(Future<T> Function() action) {
    final previous = _writeTail;
    final completer = Completer<T>();
    _writeTail = () async {
      try {
        await previous;
      } catch (_) {
        // A previous diagnostics failure must not poison future maintenance.
      }
      try {
        completer.complete(await action());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    }();
    return completer.future;
  }

  Future<void> _appendRecords(String sourceRunId, List<Map<String, Object?>> records) =>
      _appendEncodedLines(sourceRunId, records.map(jsonEncode).toList(growable: false));

  Future<void> _appendEncodedLines(String sourceRunId, List<String> lines) async {
    File? bufferedFile;
    var bufferedBytes = 0;
    var buffer = StringBuffer();

    Future<void> flushBuffer() async {
      final file = bufferedFile;
      if (file == null || bufferedBytes == 0) return;
      await file.writeAsString(buffer.toString(), mode: FileMode.append, flush: false);
      buffer = StringBuffer();
      bufferedBytes = 0;
    }

    for (final line in lines) {
      final encodedBytes = utf8.encode('$line\n').length;
      if (_activeSegment == null || _activeSegmentRunId != sourceRunId || _activeSegmentBytes + encodedBytes > maxSegmentBytes) {
        await flushBuffer();
        await _activateNextSegment(sourceRunId);
      }
      final segment = _activeSegment;
      if (segment == null) {
        throw StateError('Diagnostics TXT segment activation failed.');
      }
      if (bufferedFile case final current? when current.path != segment.path) {
        await flushBuffer();
      }
      bufferedFile = segment;
      buffer.write('$line\n');
      bufferedBytes += encodedBytes;
      _activeSegmentBytes += encodedBytes;
    }
    await flushBuffer();
  }

  Future<void> _activateNextSegment(String sourceRunId) async {
    final next = (_segmentSequenceByRun[sourceRunId] ?? 0) + 1;
    _segmentSequenceByRun[sourceRunId] = next;
    final file = File(
      '${eventsRoot.path}${Platform.pathSeparator}'
      'run-$sourceRunId-${next.toString().padLeft(6, '0')}.txt',
    );
    await file.create(recursive: true);
    _activeSegment = file;
    _activeSegmentRunId = sourceRunId;
    _activeSegmentBytes = await file.length();
  }

  void _updateSegmentSequence(String fileName) {
    final match = RegExp(r'^run-(.+)-(\d{6})\.txt$').firstMatch(fileName);
    if (match == null) return;
    final runId = match.group(1)!;
    final sequence = int.parse(match.group(2)!);
    final current = _segmentSequenceByRun[runId] ?? 0;
    if (sequence > current) _segmentSequenceByRun[runId] = sequence;
  }

  void _applyRecord(Map<String, Object?> record, {required bool fromDisk}) {
    final version = record['textFormatVersion'];
    if (version is! int || version > textFormatVersion || version <= 0) return;
    switch (record['recordType']) {
      case 'run.start':
        final run = _runFromRecord(record);
        _runs[run.sourceRunId] = run;
      case 'run.end':
        final run = _runs[record['sourceRunId']];
        if (run != null) {
          run
            ..state = record['state'] as String? ?? 'ended'
            ..endedAtUtcMicros = record['endedAtUtcMicros'] as int?;
        }
      case 'session.start':
        final session = _sessionFromRecord(record);
        _sessions[session.sessionId] = session;
      case 'session.end':
        final session = _sessions[record['sessionId']];
        if (session != null) {
          session
            ..state = _enumByName(DiagnosticSessionState.values, record['state'] as String? ?? 'ended', 'session state')
            ..endedAtUtcMicros = record['endedAtUtcMicros'] as int?;
        }
      case 'event':
        final envelope = record['event'];
        if (envelope is! Map) return;
        final event = _eventCodec.decode(envelope.map((key, value) => MapEntry(key.toString(), value)));
        _events[event.eventId] = event;
        final lineBytes = utf8.encode('${jsonEncode(record)}\n').length;
        final run = _runs[event.sourceRunId];
        if (run != null) {
          run
            ..eventCount += 1
            ..storedBytes += lineBytes;
        }
        final session = _sessions[event.captureSessionId ?? event.sourceRunId];
        if (session != null) {
          session
            ..eventCount += 1
            ..storedBytes += lineBytes;
        }
      case 'attachment':
        final value = record['descriptor'];
        if (value is! Map) return;
        var descriptor = _descriptorFromMap(value.map((key, item) => MapEntry(key.toString(), item)));
        final persisted = record['persisted'] == true;
        if (fromDisk && !persisted && descriptor.storedByteLength > 0) {
          descriptor = _descriptorWithFailure(descriptor, 'memoryDetailExpired');
        }
        final attachment = _AttachmentRecord(descriptor: descriptor, detailKey: record['detailKey'] as String?, persisted: persisted);
        _attachments[descriptor.attachmentId] = attachment;
        final event = _events[descriptor.eventId];
        if (event != null) {
          _events[event.eventId] = _eventWithAttachment(event, descriptor);
          final run = _runs[event.sourceRunId];
          if (run != null) {
            run
              ..attachmentCount += 1
              ..storedBytes += descriptor.storedByteLength;
          }
          final session = _sessions[event.captureSessionId ?? event.sourceRunId];
          if (session != null) {
            session
              ..attachmentCount += 1
              ..storedBytes += descriptor.storedByteLength;
          }
        }
    }
  }

  Future<DiagnosticMaintenanceResult> _deleteSessionInternal(String sessionId) async {
    final session = _sessions[sessionId];
    if (session == null) {
      return const DiagnosticMaintenanceResult(deletedSessions: 0, deletedEvents: 0, deletedObjects: 0, reclaimedBytes: 0);
    }
    if (session.state == DiagnosticSessionState.active) {
      throw StateError('An active diagnostic session cannot be deleted.');
    }
    final sessionIds = session.isDefault
        ? _sessions.values.where((item) => item.sourceRunId == session.sourceRunId).map((item) => item.sessionId).toSet()
        : <String>{sessionId};
    final eventIds = _events.values
        .where((event) => session.isDefault ? event.sourceRunId == session.sourceRunId : event.captureSessionId == sessionId)
        .map((event) => event.eventId)
        .toSet();
    final attachmentIds = _attachments.values
        .where((item) => eventIds.contains(item.descriptor.eventId))
        .map((item) => item.descriptor.attachmentId)
        .toList(growable: false);
    var deletedDetails = 0;
    var reclaimedBytes = 0;
    for (final attachmentId in attachmentIds) {
      final attachment = _attachments.remove(attachmentId)!;
      final key = attachment.detailKey;
      if (key != null && await detailStore.delete(key)) {
        deletedDetails += 1;
        reclaimedBytes += attachment.descriptor.storedByteLength;
      }
    }
    for (final eventId in eventIds) {
      _events.remove(eventId);
    }
    for (final id in sessionIds) {
      _sessions.remove(id);
    }
    if (session.isDefault) _runs.remove(session.sourceRunId);
    return DiagnosticMaintenanceResult(
      deletedSessions: sessionIds.length,
      deletedEvents: eventIds.length,
      deletedObjects: deletedDetails,
      reclaimedBytes: reclaimedBytes,
    );
  }

  void _addByteTrimTargets(Set<String> targets, {required Iterable<_SessionRecord> sessions, required int byteLimit}) {
    final ended = sessions.where((item) => item.state != DiagnosticSessionState.active).toList(growable: false)
      ..sort((left, right) => left.startedAtUtcMicros.compareTo(right.startedAtUtcMicros));
    var total = sessions.fold<int>(0, (sum, item) => sum + item.storedBytes);
    for (final session in ended) {
      if (total <= byteLimit) break;
      if (targets.add(session.sessionId)) total -= session.storedBytes;
    }
  }

  Future<void> _compactCatalog() async {
    final records = <Map<String, Object?>>[];
    final runs = _runs.values.toList(growable: false)..sort((left, right) => left.startedAtUtcMicros.compareTo(right.startedAtUtcMicros));
    for (final run in runs) {
      records.add(_runStartRecord(run));
      final sessions = _sessions.values.where((item) => item.sourceRunId == run.sourceRunId).toList(growable: false)
        ..sort((left, right) => left.startedAtUtcMicros.compareTo(right.startedAtUtcMicros));
      for (final session in sessions) {
        records.add(_sessionStartRecord(session));
      }
      final events = _events.values.where((item) => item.sourceRunId == run.sourceRunId).toList(growable: false)
        ..sort((left, right) => left.sourceSequence.compareTo(right.sourceSequence));
      for (final event in events) {
        records.add(_eventRecord(_withoutAttachmentProjection(event)));
        final attachments = _attachments.values.where((item) => item.descriptor.eventId == event.eventId);
        records.addAll(attachments.map(_attachmentRecord));
      }
      for (final session in sessions) {
        if (session.endedAtUtcMicros != null) {
          records.add(_sessionEndRecord(session.sessionId, session.endedAtUtcMicros!, session.state.name));
        }
      }
      if (run.endedAtUtcMicros != null) {
        records.add(_runEndRecord(run.sourceRunId, run.endedAtUtcMicros!, run.state));
      }
    }
    final result = await Isolate.run(
      _DiagnosticTextRewriteTask(diagnosticsRoot.path, records, maxSegmentBytes).call,
      debugName: 'mg-read-diagnostics-text-compact',
    );
    _lastEncoderWorkerIsolateId = result.workerIsolateId;
    _activeSegment = null;
    _activeSegmentRunId = null;
    _activeSegmentBytes = 0;
    _segmentSequenceByRun.clear();
    for (final name in result.segmentNames) {
      _updateSegmentSequence(name);
    }
  }

  bool _matchesSession(_SessionRecord session, DiagnosticSessionFilter filter) {
    if (filter.sources.isNotEmpty && !filter.sources.contains(session.source)) {
      return false;
    }
    if (filter.states.isNotEmpty && !filter.states.contains(session.state)) {
      return false;
    }
    if (filter.startedAfterUtcMicros case final value? when session.startedAtUtcMicros < value) {
      return false;
    }
    if (filter.startedBeforeUtcMicros case final value? when session.startedAtUtcMicros > value) {
      return false;
    }
    return true;
  }

  bool _matchesEvent(DiagnosticEvent event, DiagnosticEventFilter filter) {
    if (filter.sessionId case final value? when event.captureSessionId != value) {
      return false;
    }
    if (filter.traceId case final value? when event.traceId != value) {
      return false;
    }
    if (filter.minimumSeverity case final value? when event.severity.index < value.index) {
      return false;
    }
    if (filter.components.isNotEmpty && !filter.components.contains(event.component)) {
      return false;
    }
    if (filter.eventNames.isNotEmpty && !filter.eventNames.contains(event.eventName)) {
      return false;
    }
    if (filter.occurredAfterUtcMicros case final value? when event.occurredAtUtcMicros < value) {
      return false;
    }
    if (filter.occurredBeforeUtcMicros case final value? when event.occurredAtUtcMicros > value) {
      return false;
    }
    return true;
  }

  void _validateLimit(int limit) {
    if (limit <= 0 || limit > maxQueryPageSize) {
      throw RangeError.range(limit, 1, maxQueryPageSize, 'limit');
    }
  }

  void _ensureOpen() {
    if (_closed) throw StateError('DiagnosticsPersistence is closed.');
  }
}
