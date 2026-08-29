part of 'diagnostics_persistence.dart';

/// Read-on-selection access to diagnostic files when the current launch has
/// no persistent diagnostics service.
///
/// Construction and metadata listing do not create directories or decode log
/// contents. A selected file is decoded in an isolate, and corruption remains
/// local to that operation.
final class ColdDiagnosticsLogArchive implements DiagnosticsLogArchive {
  const ColdDiagnosticsLogArchive(this._dataRootResolver);

  final Future<Directory> Function() _dataRootResolver;

  @override
  Future<List<DiagnosticLogFile>> listLogFiles() async {
    final eventsRoot = await _eventsRoot();
    if (!await eventsRoot.exists()) return const <DiagnosticLogFile>[];
    final files = <DiagnosticLogFile>[];
    await for (final entity in eventsRoot.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (!_diagnosticRunFilePattern.hasMatch(name)) continue;
      final stat = await entity.stat();
      files.add(
        DiagnosticLogFile(
          fileId: _encodeLogFileId(name),
          startedAtUtcMicros: _startedMicrosFromRunFileName(name) ?? stat.modified.toUtc().microsecondsSinceEpoch,
          modifiedAtUtcMicros: stat.modified.toUtc().microsecondsSinceEpoch,
          storedBytes: stat.size,
          isCurrent: false,
        ),
      );
    }
    files.sort((left, right) => right.startedAtUtcMicros.compareTo(left.startedAtUtcMicros));
    return List<DiagnosticLogFile>.unmodifiable(files);
  }

  @override
  Future<DiagnosticPage<DiagnosticEvent>> listLogEvents(String fileId, {DiagnosticCursor? cursor, int limit = 100}) async {
    _validateArchiveLimit(limit);
    final loaded = await _load(fileId);
    final anchor = cursor == null ? null : _decodeCursor(cursor, 'logEvents');
    final after = loaded.events
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

  @override
  Future<DiagnosticEvent?> getLogEvent(String fileId, String eventId) async {
    validateDiagnosticOpaqueId(eventId, 'eventId');
    for (final event in (await _load(fileId)).events) {
      if (event.eventId == eventId) return event;
    }
    return null;
  }

  @override
  Future<List<DiagnosticAttachmentDescriptor>> listLogAttachments(String fileId, String eventId) async {
    validateDiagnosticOpaqueId(eventId, 'eventId');
    return List<DiagnosticAttachmentDescriptor>.unmodifiable(
      (await _load(fileId)).attachments[eventId] ?? const <DiagnosticAttachmentDescriptor>[],
    );
  }

  @override
  Stream<List<int>> openLogAttachment(String fileId, String attachmentId, {DiagnosticByteRange? range}) async* {
    validateDiagnosticOpaqueId(attachmentId, 'attachmentId');
    final detailKey = (await _load(fileId)).detailKeys[attachmentId];
    if (detailKey == null) throw StateError('Diagnostic attachment payload was not captured.');
    validateDiagnosticOpaqueId(detailKey, 'detailKey');
    final root = await _dataRootResolver();
    final file = File(
      '${root.path}${Platform.pathSeparator}diagnostics${Platform.pathSeparator}details${Platform.pathSeparator}$detailKey.txt',
    );
    if (!await file.exists()) throw StateError('Diagnostic attachment payload does not exist.');
    final handle = await file.open();
    try {
      final offset = range?.offset ?? 0;
      var remaining = range?.length ?? await file.length();
      await handle.setPosition(offset);
      while (remaining > 0) {
        final chunk = await handle.read(remaining > 64 * 1024 ? 64 * 1024 : remaining);
        if (chunk.isEmpty) break;
        remaining -= chunk.length;
        yield chunk;
      }
    } finally {
      await handle.close();
    }
  }

  @override
  Future<void> deleteLogFile(String fileId) async {
    final file = await _resolve(fileId);
    _DiagnosticColdFileLoadResult? loaded;
    try {
      loaded = await _loadFile(file);
    } on FormatException {
      // Corruption must not prevent deleting the selected file.
    }
    if (await file.exists()) await file.delete();
    if (loaded == null) return;
    final root = await _dataRootResolver();
    for (final key in loaded.detailKeys.values.toSet()) {
      validateDiagnosticOpaqueId(key, 'detailKey');
      final detail = File(
        '${root.path}${Platform.pathSeparator}diagnostics${Platform.pathSeparator}details${Platform.pathSeparator}$key.txt',
      );
      if (await detail.exists()) await detail.delete();
    }
  }

  @override
  Future<DiagnosticExportResult> exportLogFile(String fileId) async {
    final file = await _resolve(fileId);
    _DiagnosticColdFileLoadResult? loaded;
    try {
      loaded = await _loadFile(file);
    } on FormatException {
      // Preserve corrupt bytes in the export; decoded counts remain unknown.
    }
    final root = await _dataRootResolver();
    final exportId = 'export_${DateTime.now().toUtc().microsecondsSinceEpoch}';
    final exports = Directory('${root.path}${Platform.pathSeparator}diagnostics${Platform.pathSeparator}exports');
    await exports.create(recursive: true);
    final name = '$exportId.txt';
    final target = await file.copy('${exports.path}${Platform.pathSeparator}$name');
    return DiagnosticExportResult(
      exportId: exportId,
      relativeObjectKey: 'exports/$name',
      byteLength: await target.length(),
      sessionCount: 1,
      eventCount: loaded?.events.length ?? 0,
      attachmentCount: loaded?.attachments.values.fold<int>(0, (sum, items) => sum + items.length) ?? 0,
    );
  }

  Future<_DiagnosticColdFileLoadResult> _load(String fileId) async => _loadFile(await _resolve(fileId));

  Future<_DiagnosticColdFileLoadResult> _loadFile(File file) async {
    final loaded = await Isolate.run(_DiagnosticColdFileLoadTask(file.path).call, debugName: 'mg-read-diagnostics-cold-archive-read');
    if (loaded.isCorrupted) throw const FormatException('diagnostic_log_corrupted');
    return loaded;
  }

  Future<File> _resolve(String fileId) async {
    final name = _decodeLogFileId(fileId);
    if (!_diagnosticRunFilePattern.hasMatch(name)) {
      throw const FormatException('Invalid diagnostic log file ID.');
    }
    final file = File('${(await _eventsRoot()).path}${Platform.pathSeparator}$name');
    if (!await file.exists()) throw StateError('Diagnostic log does not exist.');
    return file;
  }

  Future<Directory> _eventsRoot() async {
    final root = await _dataRootResolver();
    return Directory('${root.path}${Platform.pathSeparator}diagnostics${Platform.pathSeparator}events');
  }

  void _validateArchiveLimit(int limit) {
    if (limit <= 0 || limit > DiagnosticsPersistence.maxQueryPageSize) {
      throw ArgumentError.value(limit, 'limit');
    }
  }
}
