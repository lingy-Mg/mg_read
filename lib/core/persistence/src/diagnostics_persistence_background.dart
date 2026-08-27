/// 诊断 TXT 的串行写入、分段切换与后台压缩执行。
///
/// 保持单写队列、isolate 编码和原有分段/保留语义。
part of 'diagnostics_persistence.dart';

extension _DiagnosticsPersistenceBackgroundExecution on DiagnosticsPersistence {
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
      if (_activeSegment == null ||
          _activeSegmentRunId != sourceRunId ||
          _activeSegmentBytes + encodedBytes > DiagnosticsPersistence.maxSegmentBytes) {
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
      _DiagnosticTextRewriteTask(diagnosticsRoot.path, records, DiagnosticsPersistence.maxSegmentBytes).call,
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
}
