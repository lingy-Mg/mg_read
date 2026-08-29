part of 'diagnostics_persistence.dart';

final class _RunRecord {
  _RunRecord({required this.sourceRunId, required this.source, required this.startedAtUtcMicros});

  final String sourceRunId;
  final DiagnosticSource source;
  final int startedAtUtcMicros;
  int? endedAtUtcMicros;
  String state = 'active';
  int eventCount = 0;
  int attachmentCount = 0;
  int storedBytes = 0;
}

final class _SessionRecord {
  _SessionRecord({
    required this.sessionId,
    required this.sourceRunId,
    required this.source,
    required this.startedAtUtcMicros,
    required this.expiresAtUtcMicros,
    required this.payloadKind,
    required this.maxStoredBytes,
    required Set<String> components,
    required Set<String> origins,
    required this.isDefault,
    required this.detailStorage,
  }) : components = Set<String>.unmodifiable(components),
       origins = Set<String>.unmodifiable(origins);

  final String sessionId;
  final String sourceRunId;
  final DiagnosticSource source;
  final int startedAtUtcMicros;
  final int? expiresAtUtcMicros;
  final DiagnosticPayloadKind payloadKind;
  final int maxStoredBytes;
  final Set<String> components;
  final Set<String> origins;
  final bool isDefault;
  final DiagnosticDetailStorage detailStorage;
  int? endedAtUtcMicros;
  DiagnosticSessionState state = DiagnosticSessionState.active;
  int eventCount = 0;
  int attachmentCount = 0;
  int storedBytes = 0;

  DiagnosticSession toPublic() => DiagnosticSession(
    sessionId: sessionId,
    source: source,
    sourceRunId: sourceRunId,
    startedAtUtcMicros: startedAtUtcMicros,
    endedAtUtcMicros: endedAtUtcMicros,
    expiresAtUtcMicros: expiresAtUtcMicros,
    state: state,
    payloadKind: payloadKind,
    eventCount: eventCount,
    attachmentCount: attachmentCount,
    storedBytes: storedBytes,
  );

  DiagnosticStoredCaptureSession toStored() => DiagnosticStoredCaptureSession(
    session: toPublic(),
    maxStoredBytes: maxStoredBytes,
    components: components,
    origins: origins,
    isDefault: isDefault,
    detailStorage: detailStorage,
  );
}

final class _AttachmentRecord {
  const _AttachmentRecord({required this.descriptor, required this.detailKey, required this.persisted});

  final DiagnosticAttachmentDescriptor descriptor;
  final String? detailKey;
  final bool persisted;
}

final class _DiagnosticEncodedEvents {
  const _DiagnosticEncodedEvents(this.lines, this.workerIsolateId);

  final List<String> lines;
  final int workerIsolateId;
}

final class _DiagnosticEventEncodeTask {
  const _DiagnosticEventEncodeTask(this.events);

  final List<DiagnosticEvent> events;

  _DiagnosticEncodedEvents call() {
    const codec = DiagnosticEventCodec();
    return _DiagnosticEncodedEvents(
      events
          .map(
            (event) => jsonEncode(<String, Object?>{
              'textFormatVersion': DiagnosticsPersistence.textFormatVersion,
              'recordType': 'event',
              'event': codec.encode(event),
            }),
          )
          .toList(growable: false),
      Isolate.current.hashCode,
    );
  }
}

final class _DiagnosticColdFileLoadResult {
  const _DiagnosticColdFileLoadResult({
    required this.events,
    required this.attachments,
    required this.detailKeys,
    required this.workerIsolateId,
    required this.isCorrupted,
  });

  final List<DiagnosticEvent> events;
  final Map<String, List<DiagnosticAttachmentDescriptor>> attachments;
  final Map<String, String> detailKeys;
  final int workerIsolateId;
  final bool isCorrupted;
}

final class _DiagnosticColdFileLoadTask {
  const _DiagnosticColdFileLoadTask(this.path);

  final String path;

  _DiagnosticColdFileLoadResult call() {
    final events = <DiagnosticEvent>[];
    final attachments = <String, List<DiagnosticAttachmentDescriptor>>{};
    final detailKeys = <String, String>{};
    var corrupted = false;
    try {
      final bytes = File(path).readAsBytesSync();
      final lastNewline = bytes.lastIndexOf(0x0a);
      final complete = lastNewline < 0 ? const <int>[] : bytes.sublist(0, lastNewline + 1);
      if (complete.length != bytes.length) corrupted = true;
      final text = utf8.decode(complete, allowMalformed: false);
      for (final line in const LineSplitter().convert(text)) {
        if (line.isEmpty) continue;
        try {
          final decoded = jsonDecode(line);
          if (decoded is! Map) {
            corrupted = true;
            continue;
          }
          final record = decoded.map((key, value) => MapEntry(key.toString(), value));
          switch (record['recordType']) {
            case 'event':
              final envelope = record['event'];
              if (envelope is! Map) {
                corrupted = true;
                continue;
              }
              events.add(const DiagnosticEventCodec().decode(envelope.map((key, value) => MapEntry(key.toString(), value))));
            case 'attachment':
              final value = record['descriptor'];
              if (value is! Map) {
                corrupted = true;
                continue;
              }
              final descriptor = _descriptorFromMap(value.map((key, item) => MapEntry(key.toString(), item)));
              attachments.putIfAbsent(descriptor.eventId, () => <DiagnosticAttachmentDescriptor>[]).add(descriptor);
              if (record['detailKey'] case final String key when key.isNotEmpty) {
                detailKeys[descriptor.attachmentId] = key;
              }
          }
        } on Object {
          corrupted = true;
        }
      }
    } on Object {
      corrupted = true;
    }
    events.sort(_compareEventsDescending);
    return _DiagnosticColdFileLoadResult(
      events: events,
      attachments: attachments,
      detailKeys: detailKeys,
      workerIsolateId: Isolate.current.hashCode,
      isCorrupted: corrupted,
    );
  }
}

final class _DiagnosticTextRewriteResult {
  const _DiagnosticTextRewriteResult(this.segmentNames, this.workerIsolateId);

  final List<String> segmentNames;
  final int workerIsolateId;
}

final class _DiagnosticTextRewriteTask {
  const _DiagnosticTextRewriteTask(this.diagnosticsPath, this.activeFilePath, this.records);

  final String diagnosticsPath;
  final String? activeFilePath;
  final List<Map<String, Object?>> records;

  _DiagnosticTextRewriteResult call() {
    final separator = Platform.pathSeparator;
    final staging = Directory('$diagnosticsPath${separator}staging');
    staging.createSync(recursive: true);
    for (final entity in staging.listSync(followLinks: false)) {
      if (entity is File && entity.uri.pathSegments.last.startsWith('rewrite-') && entity.path.endsWith('.partial.txt')) {
        entity.deleteSync();
      }
    }
    final activePath = activeFilePath;
    if (activePath == null) return _DiagnosticTextRewriteResult(const <String>[], Isolate.current.hashCode);
    final active = File(activePath);
    final staged = File('${staging.path}${separator}rewrite-current.partial.txt');
    final writer = staged.openSync(mode: FileMode.write);
    for (final record in records) {
      writer.writeStringSync('${jsonEncode(record)}\n');
    }
    writer
      ..flushSync()
      ..closeSync();
    if (active.existsSync()) active.deleteSync();
    staged.renameSync(active.path);
    return _DiagnosticTextRewriteResult(<String>[active.uri.pathSegments.last], Isolate.current.hashCode);
  }
}

Map<String, Object?> _baseRecord(String recordType) => <String, Object?>{
  'textFormatVersion': DiagnosticsPersistence.textFormatVersion,
  'recordType': recordType,
};

Map<String, Object?> _runStartRecord(_RunRecord run) => <String, Object?>{
  ..._baseRecord('run.start'),
  'sourceRunId': run.sourceRunId,
  'source': run.source.name,
  'startedAtUtcMicros': run.startedAtUtcMicros,
};

Map<String, Object?> _runEndRecord(String sourceRunId, int endedAtUtcMicros, String state) => <String, Object?>{
  ..._baseRecord('run.end'),
  'sourceRunId': sourceRunId,
  'endedAtUtcMicros': endedAtUtcMicros,
  'state': state,
};

Map<String, Object?> _sessionStartRecord(_SessionRecord session) => <String, Object?>{
  ..._baseRecord('session.start'),
  'sessionId': session.sessionId,
  'sourceRunId': session.sourceRunId,
  'source': session.source.name,
  'startedAtUtcMicros': session.startedAtUtcMicros,
  'expiresAtUtcMicros': session.expiresAtUtcMicros,
  'payloadKind': session.payloadKind.name,
  'maxStoredBytes': session.maxStoredBytes,
  'components': session.components.toList(growable: false)..sort(),
  'origins': session.origins.toList(growable: false)..sort(),
  'isDefault': session.isDefault,
  'detailStorage': session.detailStorage.name,
};

Map<String, Object?> _sessionEndRecord(String sessionId, int endedAtUtcMicros, String state) => <String, Object?>{
  ..._baseRecord('session.end'),
  'sessionId': sessionId,
  'endedAtUtcMicros': endedAtUtcMicros,
  'state': state,
};

Map<String, Object?> _eventRecord(DiagnosticEvent event) => <String, Object?>{
  ..._baseRecord('event'),
  'event': const DiagnosticEventCodec().encode(event),
};

Map<String, Object?> _attachmentRecord(_AttachmentRecord attachment) => <String, Object?>{
  ..._baseRecord('attachment'),
  'descriptor': _descriptorToMap(attachment.descriptor),
  'detailKey': attachment.detailKey,
  'persisted': attachment.persisted,
};

Map<String, Object?> _descriptorToMap(DiagnosticAttachmentDescriptor descriptor) => <String, Object?>{
  'attachmentId': descriptor.attachmentId,
  'eventId': descriptor.eventId,
  'kind': descriptor.kind,
  'mediaType': descriptor.mediaType,
  'charset': descriptor.charset,
  'formatId': descriptor.formatId,
  'formatVersion': descriptor.formatVersion,
  'schemaId': descriptor.schemaId,
  'schemaVersion': descriptor.schemaVersion,
  'captureState': descriptor.captureState.name,
  'rawByteLength': descriptor.rawByteLength,
  'storedByteLength': descriptor.storedByteLength,
  'sha256': descriptor.sha256,
  'storageCodec': descriptor.storageCodec.name,
  'truncationReason': descriptor.truncationReason,
};

DiagnosticAttachmentDescriptor _descriptorFromMap(Map<String, Object?> value) => DiagnosticAttachmentDescriptor(
  attachmentId: value['attachmentId'] as String,
  eventId: value['eventId'] as String,
  kind: value['kind'] as String,
  mediaType: value['mediaType'] as String,
  charset: value['charset'] as String?,
  formatId: value['formatId'] as String,
  formatVersion: value['formatVersion'] as int,
  schemaId: value['schemaId'] as String?,
  schemaVersion: value['schemaVersion'] as int?,
  captureState: _enumByName(DiagnosticCaptureState.values, value['captureState'] as String, 'capture state'),
  rawByteLength: value['rawByteLength'] as int,
  storedByteLength: value['storedByteLength'] as int,
  sha256: value['sha256'] as String?,
  storageCodec: _enumByName(DiagnosticStorageCodec.values, value['storageCodec'] as String, 'storage codec'),
  truncationReason: value['truncationReason'] as String?,
);

DiagnosticEvent _eventWithAttachment(DiagnosticEvent event, DiagnosticAttachmentDescriptor descriptor) => event.copyWith(
  attachmentCount: event.attachmentCount + 1,
  capturedBytes: event.capturedBytes + descriptor.storedByteLength,
  flags: <DiagnosticEventFlag>{
    ...event.flags,
    if (descriptor.captureState == DiagnosticCaptureState.truncated) DiagnosticEventFlag.truncated,
    if (descriptor.captureState == DiagnosticCaptureState.policyBlocked ||
        descriptor.captureState == DiagnosticCaptureState.pressureDropped)
      DiagnosticEventFlag.droppedPayload,
  },
);

DiagnosticEvent _withoutAttachmentProjection(DiagnosticEvent event) => event.copyWith(attachmentCount: 0, capturedBytes: 0);

int _compareSessionsDescending(DiagnosticSession left, DiagnosticSession right) {
  final time = right.startedAtUtcMicros.compareTo(left.startedAtUtcMicros);
  return time != 0 ? time : right.sessionId.compareTo(left.sessionId);
}

int _compareEventsDescending(DiagnosticEvent left, DiagnosticEvent right) {
  final time = right.occurredAtUtcMicros.compareTo(left.occurredAtUtcMicros);
  return time != 0 ? time : right.eventId.compareTo(left.eventId);
}

DiagnosticCursor _encodeCursor(String kind, int micros, String id) {
  final bytes = utf8.encode(jsonEncode(<Object?>[kind, micros, id]));
  return DiagnosticCursor(base64UrlEncode(bytes).replaceAll('=', ''));
}

(int, String) _decodeCursor(DiagnosticCursor cursor, String kind) {
  final padding = '=' * ((4 - cursor.value.length % 4) % 4);
  final value = jsonDecode(utf8.decode(base64Url.decode('${cursor.value}$padding')));
  if (value is! List || value.length != 3 || value[0] != kind || value[1] is! int || value[2] is! String) {
    throw const FormatException('Diagnostic cursor is invalid.');
  }
  return (value[1] as int, value[2] as String);
}

T _enumByName<T extends Enum>(List<T> values, String name, String field) {
  for (final value in values) {
    if (value.name == name) return value;
  }
  throw FormatException('Unknown diagnostic $field: $name.');
}

Future<void> _removeLegacyDatabaseArtifacts(Directory root) async {
  for (final name in <String>['index.sqlite', 'index.sqlite-wal', 'index.sqlite-shm', 'index.db', 'index.db-wal', 'index.db-shm']) {
    final file = File('${root.path}${Platform.pathSeparator}$name');
    if (await file.exists()) await file.delete();
  }
  for (final name in <String>['objects']) {
    final directory = Directory('${root.path}${Platform.pathSeparator}$name');
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

DateTime _utcNow() => DateTime.now().toUtc();

String _runFileName(_RunRecord run) => 'run-${run.startedAtUtcMicros.toString().padLeft(20, '0')}-${run.sourceRunId}.txt';

final RegExp _diagnosticRunFilePattern = RegExp(r'^run-[A-Za-z0-9_-]+\.txt$');

int? _startedMicrosFromRunFileName(String name) {
  final match = RegExp(r'^run-(\d{20})-[A-Za-z0-9_-]+\.txt$').firstMatch(name);
  return match == null ? null : int.tryParse(match.group(1)!);
}

String _encodeLogFileId(String name) => base64UrlEncode(utf8.encode(name)).replaceAll('=', '');

String _decodeLogFileId(String fileId) {
  if (!RegExp(r'^[A-Za-z0-9_-]{8,512}$').hasMatch(fileId)) {
    throw const FormatException('Invalid diagnostic log file ID.');
  }
  final padding = '=' * ((4 - fileId.length % 4) % 4);
  return utf8.decode(base64Url.decode('$fileId$padding'));
}
