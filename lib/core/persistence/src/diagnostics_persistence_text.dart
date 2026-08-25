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

final class _DiagnosticTextLoadResult {
  const _DiagnosticTextLoadResult({required this.records, required this.segmentBytes, required this.workerIsolateId});

  final List<Map<String, Object?>> records;
  final Map<String, int> segmentBytes;
  final int workerIsolateId;
}

final class _DiagnosticTextLoadTask {
  const _DiagnosticTextLoadTask(this.eventsPath);

  final String eventsPath;

  _DiagnosticTextLoadResult call() {
    final root = Directory(eventsPath);
    final files = root.listSync(followLinks: false).whereType<File>().where((file) => file.path.endsWith('.txt')).toList(growable: false)
      ..sort((left, right) => left.path.compareTo(right.path));
    final records = <Map<String, Object?>>[];
    final segmentBytes = <String, int>{};
    for (final file in files) {
      var bytes = file.readAsBytesSync();
      final lastNewline = bytes.lastIndexOf(0x0a);
      final completeLength = lastNewline < 0 ? 0 : lastNewline + 1;
      if (completeLength != bytes.length) {
        final handle = file.openSync(mode: FileMode.writeOnlyAppend);
        handle.truncateSync(completeLength);
        handle.closeSync();
        bytes = bytes.sublist(0, completeLength);
      }
      final name = file.uri.pathSegments.last;
      segmentBytes[name] = completeLength;
      if (bytes.isEmpty) continue;
      final text = utf8.decode(bytes, allowMalformed: false);
      for (final line in const LineSplitter().convert(text)) {
        if (line.isEmpty) continue;
        try {
          final value = jsonDecode(line);
          if (value is Map) {
            records.add(value.map((key, item) => MapEntry(key.toString(), item)));
          }
        } on FormatException {
          // A malformed complete line is isolated; later records stay usable.
        }
      }
    }
    return _DiagnosticTextLoadResult(records: records, segmentBytes: segmentBytes, workerIsolateId: Isolate.current.hashCode);
  }
}

final class _DiagnosticTextRewriteResult {
  const _DiagnosticTextRewriteResult(this.segmentNames, this.workerIsolateId);

  final List<String> segmentNames;
  final int workerIsolateId;
}

final class _DiagnosticTextRewriteTask {
  const _DiagnosticTextRewriteTask(this.diagnosticsPath, this.records, this.maxSegmentBytes);

  final String diagnosticsPath;
  final List<Map<String, Object?>> records;
  final int maxSegmentBytes;

  _DiagnosticTextRewriteResult call() {
    final separator = Platform.pathSeparator;
    final events = Directory('$diagnosticsPath${separator}events');
    final staging = Directory('$diagnosticsPath${separator}staging');
    staging.createSync(recursive: true);
    final staged = <File>[];
    var segment = 1;
    var currentBytes = 0;
    var current = File('${staging.path}${separator}rewrite-${segment.toString().padLeft(6, '0')}.partial.txt');
    for (final record in records) {
      final line = '${jsonEncode(record)}\n';
      final bytes = utf8.encode(line).length;
      if (currentBytes > 0 && currentBytes + bytes > maxSegmentBytes) {
        staged.add(current);
        segment += 1;
        currentBytes = 0;
        current = File('${staging.path}${separator}rewrite-${segment.toString().padLeft(6, '0')}.partial.txt');
      }
      current.writeAsStringSync(line, mode: FileMode.append, flush: false);
      currentBytes += bytes;
    }
    if (current.existsSync()) staged.add(current);
    for (final entity in events.listSync(followLinks: false)) {
      if (entity is File && entity.path.endsWith('.txt')) entity.deleteSync();
    }
    final names = <String>[];
    for (var index = 0; index < staged.length; index += 1) {
      final name = 'run-compacted-${(index + 1).toString().padLeft(6, '0')}.txt';
      staged[index].renameSync('${events.path}$separator$name');
      names.add(name);
    }
    return _DiagnosticTextRewriteResult(names, Isolate.current.hashCode);
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

_RunRecord _runFromRecord(Map<String, Object?> record) => _RunRecord(
  sourceRunId: record['sourceRunId'] as String,
  source: _enumByName(DiagnosticSource.values, record['source'] as String, 'source'),
  startedAtUtcMicros: record['startedAtUtcMicros'] as int,
);

_SessionRecord _sessionFromRecord(Map<String, Object?> record) => _SessionRecord(
  sessionId: record['sessionId'] as String,
  sourceRunId: record['sourceRunId'] as String,
  source: _enumByName(DiagnosticSource.values, record['source'] as String, 'source'),
  startedAtUtcMicros: record['startedAtUtcMicros'] as int,
  expiresAtUtcMicros: record['expiresAtUtcMicros'] as int?,
  payloadKind: _enumByName(DiagnosticPayloadKind.values, record['payloadKind'] as String, 'payload kind'),
  maxStoredBytes: record['maxStoredBytes'] as int,
  components: _stringSet(record['components']),
  origins: _stringSet(record['origins']),
  isDefault: record['isDefault'] == true,
  detailStorage: _enumByName(DiagnosticDetailStorage.values, record['detailStorage'] as String? ?? 'persistToText', 'detail storage'),
);

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
  'privacyClass': descriptor.privacyClass.name,
  'captureState': descriptor.captureState.name,
  'rawByteLength': descriptor.rawByteLength,
  'storedByteLength': descriptor.storedByteLength,
  'sha256': descriptor.sha256,
  'storageCodec': descriptor.storageCodec.name,
  'redactionVersion': descriptor.redactionVersion,
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
  privacyClass: _enumByName(DiagnosticPrivacyClass.values, value['privacyClass'] as String, 'privacy class'),
  captureState: _enumByName(DiagnosticCaptureState.values, value['captureState'] as String, 'capture state'),
  rawByteLength: value['rawByteLength'] as int,
  storedByteLength: value['storedByteLength'] as int,
  sha256: value['sha256'] as String?,
  storageCodec: _enumByName(DiagnosticStorageCodec.values, value['storageCodec'] as String, 'storage codec'),
  redactionVersion: value['redactionVersion'] as int,
  truncationReason: value['truncationReason'] as String?,
);

DiagnosticAttachmentDescriptor _descriptorWithFailure(DiagnosticAttachmentDescriptor descriptor, String reason) =>
    DiagnosticAttachmentDescriptor(
      attachmentId: descriptor.attachmentId,
      eventId: descriptor.eventId,
      kind: descriptor.kind,
      mediaType: descriptor.mediaType,
      charset: descriptor.charset,
      formatId: descriptor.formatId,
      formatVersion: descriptor.formatVersion,
      schemaId: descriptor.schemaId,
      schemaVersion: descriptor.schemaVersion,
      privacyClass: descriptor.privacyClass,
      captureState: DiagnosticCaptureState.failed,
      rawByteLength: descriptor.rawByteLength,
      storedByteLength: 0,
      storageCodec: descriptor.storageCodec,
      redactionVersion: descriptor.redactionVersion,
      truncationReason: reason,
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

Set<String> _stringSet(Object? value) {
  if (value is! List) return const <String>{};
  return value.whereType<String>().toSet();
}

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
  for (final name in <String>['objects', 'exports']) {
    final directory = Directory('${root.path}${Platform.pathSeparator}$name');
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

DateTime _utcNow() => DateTime.now().toUtc();
