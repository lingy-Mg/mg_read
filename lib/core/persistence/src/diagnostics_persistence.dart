/// 应用诊断 TXT 持久化库。
///
/// 职责：
/// - 写入和查询当前启动的单文件诊断记录。
/// - 管理详情附件、保留策略和旧日志清理。
///
/// 注意：
/// - 诊断失败不得影响业务结果，也不得形成 SQLite/WAL 索引。
/// - 已接收事件按原值编码；本层不执行内容识别或改写。
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
part 'diagnostics_persistence_background.dart';
part 'diagnostics_cold_archive.dart';

/// App-owned, process-scoped TXT diagnostics store.
///
/// The active process owns one newline-delimited JSON file and one in-memory
/// catalog. Historical files stay cold: [open] never reads, decodes, repairs,
/// or indexes their contents. They are parsed only through an explicit archive
/// selection.
final class DiagnosticsPersistence {
  DiagnosticsPersistence._(this.diagnosticsRoot, this.eventsRoot, this.detailStore, this._clock);

  static const int textFormatVersion = 1;
  static const int maxWriteBatchSize = 128;
  static const int maxQueryPageSize = 200;

  final Directory diagnosticsRoot;
  final Directory eventsRoot;
  final DiagnosticTextDetailStore detailStore;
  final DateTime Function() _clock;
  final Map<String, _RunRecord> _runs = <String, _RunRecord>{};
  final Map<String, _SessionRecord> _sessions = <String, _SessionRecord>{};
  final Map<String, DiagnosticEvent> _events = <String, DiagnosticEvent>{};
  final Map<String, _AttachmentRecord> _attachments = <String, _AttachmentRecord>{};
  final Set<String> _pendingDetailDeletes = <String>{};
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
    return store;
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
      final file = File('${eventsRoot.path}${Platform.pathSeparator}${_runFileName(run)}');
      await file.create(recursive: true);
      _activeSegment = file;
      _activeSegmentRunId = sourceRunId;
      _activeSegmentBytes = 0;
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

  /// Lists run files from directory metadata only. No file is opened here.
  Future<List<DiagnosticLogFile>> listLogFiles() async {
    _ensureOpen();
    await _writeTail;
    final currentPath = _activeSegment?.absolute.path;
    final files = <DiagnosticLogFile>[];
    await for (final entity in eventsRoot.list(followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.txt')) continue;
      final name = entity.uri.pathSegments.last;
      if (!_diagnosticRunFilePattern.hasMatch(name)) continue;
      final stat = await entity.stat();
      final parsedStart = _startedMicrosFromRunFileName(name);
      files.add(
        DiagnosticLogFile(
          fileId: _encodeLogFileId(name),
          startedAtUtcMicros: parsedStart ?? stat.modified.toUtc().microsecondsSinceEpoch,
          modifiedAtUtcMicros: stat.modified.toUtc().microsecondsSinceEpoch,
          storedBytes: stat.size,
          isCurrent: entity.absolute.path == currentPath,
        ),
      );
    }
    files.sort((left, right) => right.startedAtUtcMicros.compareTo(left.startedAtUtcMicros));
    return List<DiagnosticLogFile>.unmodifiable(files);
  }

  Future<DiagnosticPage<DiagnosticEvent>> listLogEvents(String fileId, {DiagnosticCursor? cursor, int limit = 100}) async {
    _ensureOpen();
    _validateLimit(limit);
    await _writeTail;
    final file = _resolveLogFile(fileId);
    final List<DiagnosticEvent> events;
    if (_activeSegment?.absolute.path == file.absolute.path) {
      events = _events.values.toList(growable: false)..sort(_compareEventsDescending);
    } else {
      events = (await _loadColdFile(file)).events;
    }
    final anchor = cursor == null ? null : _decodeCursor(cursor, 'logEvents');
    final after = events
        .where(
          (event) =>
              anchor == null ||
              event.occurredAtUtcMicros < anchor.$1 ||
              (event.occurredAtUtcMicros == anchor.$1 && event.eventId.compareTo(anchor.$2) < 0),
        )
        .toList(growable: false);
    final hasMore = after.length > limit;
    final page = hasMore ? after.take(limit).toList(growable: false) : after;
    final tail = page.isEmpty ? null : page.last;
    return DiagnosticPage<DiagnosticEvent>(
      items: page,
      nextCursor: hasMore && tail != null ? _encodeCursor('logEvents', tail.occurredAtUtcMicros, tail.eventId) : null,
    );
  }

  Future<DiagnosticEvent?> getLogEvent(String fileId, String eventId) async {
    validateDiagnosticOpaqueId(eventId, 'eventId');
    await _writeTail;
    final file = _resolveLogFile(fileId);
    if (_activeSegment?.absolute.path == file.absolute.path) return _events[eventId];
    final loaded = await _loadColdFile(file);
    for (final event in loaded.events) {
      if (event.eventId == eventId) return event;
    }
    return null;
  }

  Future<List<DiagnosticAttachmentDescriptor>> listLogAttachments(String fileId, String eventId) async {
    validateDiagnosticOpaqueId(eventId, 'eventId');
    await _writeTail;
    final file = _resolveLogFile(fileId);
    if (_activeSegment?.absolute.path == file.absolute.path) {
      return List<DiagnosticAttachmentDescriptor>.unmodifiable(
        _attachments.values.where((item) => item.descriptor.eventId == eventId).map((item) => item.descriptor),
      );
    }
    final loaded = await _loadColdFile(file);
    return List<DiagnosticAttachmentDescriptor>.unmodifiable(loaded.attachments[eventId] ?? const <DiagnosticAttachmentDescriptor>[]);
  }

  Stream<List<int>> openLogAttachment(String fileId, String attachmentId, {DiagnosticByteRange? range}) async* {
    validateDiagnosticOpaqueId(attachmentId, 'attachmentId');
    await _writeTail;
    final file = _resolveLogFile(fileId);
    String? detailKey;
    if (_activeSegment?.absolute.path == file.absolute.path) {
      detailKey = _attachments[attachmentId]?.detailKey;
    } else {
      detailKey = (await _loadColdFile(file)).detailKeys[attachmentId];
    }
    if (detailKey == null) throw StateError('Diagnostic attachment payload was not captured.');
    yield* detailStore.openDetail(detailKey, range: range);
  }

  Future<void> deleteLogFile(String fileId) async {
    await _writeTail;
    final file = _resolveLogFile(fileId);
    if (_activeSegment?.absolute.path == file.absolute.path) {
      throw StateError('The current diagnostic log cannot be deleted.');
    }
    _DiagnosticColdFileLoadResult? loaded;
    try {
      loaded = await _loadColdFile(file);
    } on FormatException {
      // A corrupt log remains independently deletable; its unresolvable detail
      // files are reclaimed later by metadata-only retention.
    }
    if (await file.exists()) await file.delete();
    if (loaded != null) {
      for (final key in loaded.detailKeys.values.toSet()) {
        await detailStore.delete(key);
      }
    }
  }

  Future<DiagnosticExportResult> exportLogFile(String fileId) async {
    await _writeTail;
    final file = _resolveLogFile(fileId);
    _DiagnosticColdFileLoadResult? loaded = _activeSegment?.absolute.path == file.absolute.path
        ? _DiagnosticColdFileLoadResult(
            events: _events.values.toList(growable: false),
            attachments: <String, List<DiagnosticAttachmentDescriptor>>{
              for (final event in _events.values)
                event.eventId: _attachments.values
                    .where((item) => item.descriptor.eventId == event.eventId)
                    .map((item) => item.descriptor)
                    .toList(growable: false),
            },
            detailKeys: const <String, String>{},
            workerIsolateId: Isolate.current.hashCode,
            isCorrupted: false,
          )
        : null;
    if (loaded == null) {
      try {
        loaded = await _loadColdFile(file);
      } on FormatException {
        // Export remains available for a corrupt log. Counts are unknown, but
        // the original bytes are copied unchanged for inspection.
      }
    }
    final exportId = 'export_${_clock().toUtc().microsecondsSinceEpoch}';
    final exports = Directory('${diagnosticsRoot.path}${Platform.pathSeparator}exports');
    await exports.create(recursive: true);
    final name = '$exportId.txt';
    final target = File('${exports.path}${Platform.pathSeparator}$name');
    await file.copy(target.path);
    final bytes = await target.length();
    return DiagnosticExportResult(
      exportId: exportId,
      relativeObjectKey: 'exports/$name',
      byteLength: bytes,
      sessionCount: 1,
      eventCount: loaded?.events.length ?? 0,
      attachmentCount: loaded?.attachments.values.fold<int>(0, (sum, items) => sum + items.length) ?? 0,
    );
  }

  Future<_DiagnosticColdFileLoadResult> _loadColdFile(File file) async {
    final loaded = await Isolate.run(_DiagnosticColdFileLoadTask(file.path).call, debugName: 'mg-read-diagnostics-cold-file-read');
    _lastEncoderWorkerIsolateId = loaded.workerIsolateId;
    if (loaded.isCorrupted) throw const FormatException('diagnostic_log_corrupted');
    return loaded;
  }

  File _resolveLogFile(String fileId) {
    final name = _decodeLogFileId(fileId);
    if (!_diagnosticRunFilePattern.hasMatch(name)) {
      throw const FormatException('Invalid diagnostic log file ID.');
    }
    return File('${eventsRoot.path}${Platform.pathSeparator}$name');
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
    final activeResult = await _exclusive(() async {
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
      return DiagnosticMaintenanceResult(
        deletedSessions: deletedSessions,
        deletedEvents: deletedEvents,
        deletedObjects: deletedDetails,
        reclaimedBytes: reclaimedBytes,
      );
    });
    final coldResult = await _enforceColdRetention(policy);
    return DiagnosticMaintenanceResult(
      deletedSessions: activeResult.deletedSessions + coldResult.deletedSessions,
      deletedEvents: activeResult.deletedEvents,
      deletedObjects: activeResult.deletedObjects + coldResult.deletedObjects,
      reclaimedBytes: activeResult.reclaimedBytes + coldResult.reclaimedBytes,
    );
  }

  Future<DiagnosticMaintenanceResult> _enforceColdRetention(DiagnosticRetentionPolicy policy) async {
    await detailStore.cleanStaging();
    final nowMicros = _clock().toUtc().microsecondsSinceEpoch;
    final currentPath = _activeSegment?.absolute.path;
    final files = <(File, FileStat)>[];
    await for (final entity in eventsRoot.list(followLinks: false)) {
      if (entity is! File || !_diagnosticRunFilePattern.hasMatch(entity.uri.pathSegments.last)) continue;
      if (entity.absolute.path == currentPath) continue;
      files.add((entity, await entity.stat()));
    }
    files.sort((left, right) => left.$2.modified.compareTo(right.$2.modified));
    final targets = <File>{};
    var eventBytes = files.fold<int>(0, (sum, item) => sum + item.$2.size) + _activeSegmentBytes;
    for (final item in files) {
      if (item.$2.modified.toUtc().microsecondsSinceEpoch <= nowMicros - policy.regularEventAge.inMicroseconds) {
        targets.add(item.$1);
        eventBytes -= item.$2.size;
      }
    }
    for (final item in files) {
      if (eventBytes <= policy.regularEventBytes) break;
      if (targets.add(item.$1)) eventBytes -= item.$2.size;
    }
    var reclaimed = 0;
    for (final file in targets) {
      final length = await file.length();
      await file.delete();
      reclaimed += length;
    }

    var pendingDeleted = 0;
    for (final key in _pendingDetailDeletes.toList(growable: false)) {
      if (await detailStore.delete(key)) {
        _pendingDetailDeletes.remove(key);
        pendingDeleted += 1;
      }
    }
    final activeDetailKeys = _attachments.values.map((item) => item.detailKey).whereType<String>().toSet();
    final detailFiles = <(File, FileStat)>[];
    await for (final entity in detailStore.detailsRoot.list(followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.txt')) continue;
      final key = entity.uri.pathSegments.last.replaceFirst(RegExp(r'\.txt$'), '');
      if (activeDetailKeys.contains(key)) continue;
      detailFiles.add((entity, await entity.stat()));
    }
    detailFiles.sort((left, right) => left.$2.modified.compareTo(right.$2.modified));
    final detailTargets = <File>{};
    var detailBytes = detailFiles.fold<int>(0, (sum, item) => sum + item.$2.size);
    for (final item in detailFiles) {
      if (item.$2.modified.toUtc().microsecondsSinceEpoch <= nowMicros - policy.captureAge.inMicroseconds) {
        detailTargets.add(item.$1);
        detailBytes -= item.$2.size;
      }
    }
    final allowedDetailBytes = policy.globalHardBytes - eventBytes;
    for (final item in detailFiles) {
      if (detailBytes <= allowedDetailBytes) break;
      if (detailTargets.add(item.$1)) detailBytes -= item.$2.size;
    }
    for (final file in detailTargets) {
      final length = await file.length();
      await file.delete();
      reclaimed += length;
    }
    return DiagnosticMaintenanceResult(
      deletedSessions: targets.length,
      deletedEvents: 0,
      deletedObjects: detailTargets.length + pendingDeleted,
      reclaimedBytes: reclaimed,
    );
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
      } else if (key != null) {
        _pendingDetailDeletes.add(key);
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
