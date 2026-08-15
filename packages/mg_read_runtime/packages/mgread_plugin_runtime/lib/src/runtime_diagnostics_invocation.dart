part of mgread_plugin_runtime;

/// Storage target for detail payloads in an explicit Runtime capture session.
enum RuntimeDiagnosticDetailStorage { memoryOnly, persistToText }

enum RuntimeDiagnosticSeverity { trace, debug, info, warn, error, fatal }

enum RuntimeDiagnosticPhase { instant, start, terminal }

enum RuntimeDiagnosticOutcome {
  success,
  error,
  cancelled,
  timeout,
  overloaded,
  incomplete,
}

enum RuntimeDiagnosticPayloadKind {
  metadataOnly,
  safeStructured,
  contentPayload,
  restrictedRaw,
}

enum RuntimeDiagnosticSessionState { active, ended, expired, deleting, deleted }

enum RuntimeDiagnosticCaptureState {
  captured,
  truncated,
  policyBlocked,
  pressureDropped,
  failed,
}

enum RuntimeDiagnosticPrivacyClass {
  public,
  internal,
  content,
  restricted,
  secret,
}

/// One immutable page returned by a bounded Runtime diagnostics query.
@immutable
final class RuntimeDiagnosticPage<T> {
  const RuntimeDiagnosticPage({required this.items, this.nextCursor});

  final List<T> items;
  final String? nextCursor;
}

/// A Runtime-owned diagnostics session projection without paths or transport data.
@immutable
final class RuntimeDiagnosticsSession {
  const RuntimeDiagnosticsSession({
    required this.attachmentCount,
    required this.eventCount,
    required this.payloadKind,
    required this.sessionId,
    required this.sourceRunId,
    required this.startedAtUtcMicros,
    required this.state,
    required this.storedBytes,
    this.endedAtUtcMicros,
    this.expiresAtUtcMicros,
  });

  final int attachmentCount;
  final int? endedAtUtcMicros;
  final int eventCount;
  final int? expiresAtUtcMicros;
  final RuntimeDiagnosticPayloadKind payloadKind;
  final String sessionId;
  final String sourceRunId;
  final int startedAtUtcMicros;
  final RuntimeDiagnosticSessionState state;
  final int storedBytes;
}

/// A compact Runtime event. [attributes] exists only for an explicit get call.
@immutable
final class RuntimeDiagnosticsEvent {
  const RuntimeDiagnosticsEvent({
    required this.attachmentCount,
    required this.capturedBytes,
    required this.captureSessionId,
    required this.component,
    required this.envelopeVersion,
    required this.eventId,
    required this.eventName,
    required this.eventSchemaVersion,
    required this.flags,
    required this.monotonicOffsetMicros,
    required this.occurredAtUtcMicros,
    required this.phase,
    required this.severity,
    required this.sourceRunId,
    required this.sourceSequence,
    required this.summary,
    this.attributes,
    this.durationMicros,
    this.outcome,
    this.parentSpanId,
    this.spanId,
    this.traceId,
  });

  final int attachmentCount;
  final RuntimeDiagnosticObjectValue? attributes;
  final int capturedBytes;
  final String captureSessionId;
  final String component;
  final int? durationMicros;
  final int envelopeVersion;
  final String eventId;
  final String eventName;
  final int eventSchemaVersion;
  final List<String> flags;
  final int monotonicOffsetMicros;
  final int occurredAtUtcMicros;
  final RuntimeDiagnosticOutcome? outcome;
  final String? parentSpanId;
  final RuntimeDiagnosticPhase phase;
  final RuntimeDiagnosticSeverity severity;
  final String sourceRunId;
  final int sourceSequence;
  final String? spanId;
  final String summary;
  final String? traceId;
}

/// Tagged Runtime diagnostic value; arbitrary JSON never crosses the Facade.
sealed class RuntimeDiagnosticValue {
  const RuntimeDiagnosticValue();
}

final class RuntimeDiagnosticNullValue extends RuntimeDiagnosticValue {
  const RuntimeDiagnosticNullValue();
}

final class RuntimeDiagnosticBoolValue extends RuntimeDiagnosticValue {
  const RuntimeDiagnosticBoolValue(this.value);
  final bool value;
}

final class RuntimeDiagnosticStringValue extends RuntimeDiagnosticValue {
  const RuntimeDiagnosticStringValue(this.value);
  final String value;
}

final class RuntimeDiagnosticInt64Value extends RuntimeDiagnosticValue {
  const RuntimeDiagnosticInt64Value(this.value);
  final String value;
}

final class RuntimeDiagnosticDoubleValue extends RuntimeDiagnosticValue {
  const RuntimeDiagnosticDoubleValue(this.value);
  final double value;
}

final class RuntimeDiagnosticListValue extends RuntimeDiagnosticValue {
  const RuntimeDiagnosticListValue(this.items);
  final List<RuntimeDiagnosticValue> items;
}

final class RuntimeDiagnosticObjectValue extends RuntimeDiagnosticValue {
  const RuntimeDiagnosticObjectValue(this.fields);
  final Map<String, RuntimeDiagnosticValue> fields;
}

final class RuntimeDiagnosticRedactedValue extends RuntimeDiagnosticValue {
  const RuntimeDiagnosticRedactedValue(this.reason);
  final String reason;
}

final class RuntimeDiagnosticTruncatedValue extends RuntimeDiagnosticValue {
  const RuntimeDiagnosticTruncatedValue(this.reason, {this.originalCount});
  final int? originalCount;
  final String reason;
}

final class RuntimeDiagnosticAttachmentReferenceValue
    extends RuntimeDiagnosticValue {
  const RuntimeDiagnosticAttachmentReferenceValue(this.attachmentId);
  final String attachmentId;
}

@immutable
final class RuntimeDiagnosticAttachment {
  const RuntimeDiagnosticAttachment({
    required this.attachmentId,
    required this.captureState,
    required this.eventId,
    required this.formatId,
    required this.formatVersion,
    required this.kind,
    required this.mediaType,
    required this.privacyClass,
    required this.rawByteLength,
    required this.redactionVersion,
    required this.storedByteLength,
    this.charset,
    this.schemaId,
    this.schemaVersion,
    this.sha256,
    this.truncationReason,
  });

  final String attachmentId;
  final RuntimeDiagnosticCaptureState captureState;
  final String? charset;
  final String eventId;
  final String formatId;
  final int formatVersion;
  final String kind;
  final String mediaType;
  final RuntimeDiagnosticPrivacyClass privacyClass;
  final int rawByteLength;
  final int redactionVersion;
  final String? schemaId;
  final int? schemaVersion;
  final String? sha256;
  final int storedByteLength;
  final String? truncationReason;
}

@immutable
final class RuntimeDiagnosticAttachmentChunk {
  const RuntimeDiagnosticAttachmentChunk({
    required this.bytes,
    required this.eof,
    required this.nextOffset,
    required this.totalStoredBytes,
  });

  final List<int> bytes;
  final bool eof;
  final int nextOffset;
  final int totalStoredBytes;
}

@immutable
final class RuntimeDiagnosticsStorageStatistics {
  const RuntimeDiagnosticsStorageStatistics({
    required this.attachmentCount,
    required this.detailCount,
    required this.detailTextBytes,
    required this.eventCount,
    required this.eventTextBytes,
    required this.logicalStoredBytes,
    required this.memoryDetailBytes,
    required this.runCount,
    required this.segmentCount,
    required this.sessionCount,
  });

  final int attachmentCount;
  final int detailCount;
  final int detailTextBytes;
  final int eventCount;
  final int eventTextBytes;
  final int logicalStoredBytes;
  final int memoryDetailBytes;
  final int runCount;
  final int segmentCount;
  final int sessionCount;
}

@immutable
final class RuntimeDiagnosticsSessionsInvocation
    extends PluginInvocation<RuntimeDiagnosticPage<RuntimeDiagnosticsSession>> {
  const RuntimeDiagnosticsSessionsInvocation({
    this.cursor,
    this.limit = 100,
    this.states = const <RuntimeDiagnosticSessionState>{},
  }) : assert(limit > 0 && limit <= 100);

  final String? cursor;
  final int limit;
  final Set<RuntimeDiagnosticSessionState> states;

  @override
  String get _wireMethod => 'diagnostics.sessions.list.v1';

  @override
  Map<String, Object?> get _wireParams => <String, Object?>{
    if (cursor != null) 'cursor': cursor,
    'limit': limit,
    if (states.isNotEmpty)
      'states': states.map((state) => state.name).toList(growable: false),
  };

  @override
  RuntimeDiagnosticPage<RuntimeDiagnosticsSession> _decodeResult(
    Object? value,
  ) {
    return _decodeRuntimePage(
      value,
      _decodeRuntimeSession,
      'diagnostics sessions',
    );
  }
}

@immutable
final class RuntimeDiagnosticsEventsInvocation
    extends PluginInvocation<RuntimeDiagnosticPage<RuntimeDiagnosticsEvent>> {
  const RuntimeDiagnosticsEventsInvocation({
    this.components = const <String>{},
    this.cursor,
    this.eventNames = const <String>{},
    this.limit = 20,
    this.minimumSeverity,
    this.occurredAfterUtcMicros,
    this.occurredBeforeUtcMicros,
    this.sessionId,
    this.traceId,
  }) : assert(limit > 0 && limit <= 20);

  final Set<String> components;
  final String? cursor;
  final Set<String> eventNames;
  final int limit;
  final RuntimeDiagnosticSeverity? minimumSeverity;
  final int? occurredAfterUtcMicros;
  final int? occurredBeforeUtcMicros;
  final String? sessionId;
  final String? traceId;

  @override
  String get _wireMethod => 'diagnostics.events.list.v1';

  @override
  Map<String, Object?> get _wireParams => <String, Object?>{
    if (components.isNotEmpty) 'components': components.toList(growable: false),
    if (cursor != null) 'cursor': cursor,
    if (eventNames.isNotEmpty) 'eventNames': eventNames.toList(growable: false),
    'limit': limit,
    if (minimumSeverity != null) 'minimumSeverity': minimumSeverity!.name,
    if (occurredAfterUtcMicros != null)
      'occurredAfterUtcMicros': occurredAfterUtcMicros,
    if (occurredBeforeUtcMicros != null)
      'occurredBeforeUtcMicros': occurredBeforeUtcMicros,
    if (sessionId != null) 'sessionId': sessionId,
    if (traceId != null) 'traceId': traceId,
  };

  @override
  RuntimeDiagnosticPage<RuntimeDiagnosticsEvent> _decodeResult(Object? value) {
    return _decodeRuntimePage(value, _decodeRuntimeEvent, 'diagnostics events');
  }
}

@immutable
final class RuntimeDiagnosticsEventInvocation
    extends PluginInvocation<RuntimeDiagnosticsEvent?> {
  const RuntimeDiagnosticsEventInvocation(this.eventId);
  final String eventId;

  @override
  String get _wireMethod => 'diagnostics.event.get.v1';

  @override
  Map<String, Object?> get _wireParams => <String, Object?>{'eventId': eventId};

  @override
  RuntimeDiagnosticsEvent? _decodeResult(Object? value) {
    if (value == null) return null;
    return _decodeRuntimeEvent(value);
  }
}

@immutable
final class RuntimeDiagnosticsAttachmentsInvocation
    extends PluginInvocation<List<RuntimeDiagnosticAttachment>> {
  const RuntimeDiagnosticsAttachmentsInvocation(this.eventId);
  final String eventId;

  @override
  String get _wireMethod => 'diagnostics.attachments.list.v1';

  @override
  Map<String, Object?> get _wireParams => <String, Object?>{'eventId': eventId};

  @override
  List<RuntimeDiagnosticAttachment> _decodeResult(Object? value) {
    if (value is! List<Object?>)
      throw _invalidDiagnosticsResponse('attachments');
    return List<RuntimeDiagnosticAttachment>.unmodifiable(
      value.map(_decodeRuntimeAttachment),
    );
  }
}

@immutable
final class RuntimeDiagnosticsAttachmentReadInvocation
    extends PluginInvocation<RuntimeDiagnosticAttachmentChunk> {
  const RuntimeDiagnosticsAttachmentReadInvocation({
    required this.attachmentId,
    required this.offset,
    required this.length,
  }) : assert(offset >= 0),
       assert(length > 0 && length <= 32 * 1024);

  final String attachmentId;
  final int length;
  final int offset;

  @override
  String get _wireMethod => 'diagnostics.attachment.read.v1';

  @override
  Map<String, Object?> get _wireParams => <String, Object?>{
    'attachmentId': attachmentId,
    'length': length,
    'offset': offset,
  };

  @override
  RuntimeDiagnosticAttachmentChunk _decodeResult(Object? value) {
    final item = _jsonObject(value, 'Runtime diagnostic attachment chunk');
    final bytesBase64 = _requiredString(item, 'bytesBase64');
    try {
      return RuntimeDiagnosticAttachmentChunk(
        bytes: List<int>.unmodifiable(base64Decode(bytesBase64)),
        eof: _requiredBool(item, 'eof'),
        nextOffset: _requiredInt(item, 'nextOffset'),
        totalStoredBytes: _requiredInt(item, 'totalStoredBytes'),
      );
    } on FormatException {
      throw _invalidDiagnosticsResponse('attachment bytes');
    }
  }
}

@immutable
final class RuntimeDiagnosticsCaptureStartInvocation
    extends PluginInvocation<RuntimeDiagnosticsSession> {
  RuntimeDiagnosticsCaptureStartInvocation({
    required this.payloadKind,
    required this.detailStorage,
    required this.duration,
    required this.maxStoredBytes,
    this.components = const <String>{},
    this.origins = const <String>{},
  }) : assert(duration > Duration.zero),
       assert(maxStoredBytes > 0);

  final Set<String> components;
  final RuntimeDiagnosticDetailStorage detailStorage;
  final Duration duration;
  final int maxStoredBytes;
  final Set<String> origins;
  final RuntimeDiagnosticPayloadKind payloadKind;

  @override
  String get _wireMethod => 'diagnostics.capture.start.v1';

  @override
  Map<String, Object?> get _wireParams => <String, Object?>{
    'components': components.toList(growable: false),
    'detailStorage': detailStorage.name,
    'durationMillis': duration.inMilliseconds,
    'maxStoredBytes': maxStoredBytes,
    'origins': origins.toList(growable: false),
    'payloadKind': payloadKind.name,
  };

  @override
  RuntimeDiagnosticsSession _decodeResult(Object? value) =>
      _decodeRuntimeSession(value);
}

@immutable
final class RuntimeDiagnosticsCaptureStopInvocation
    extends PluginInvocation<void> {
  const RuntimeDiagnosticsCaptureStopInvocation(this.sessionId);
  final String sessionId;

  @override
  String get _wireMethod => 'diagnostics.capture.stop.v1';

  @override
  Map<String, Object?> get _wireParams => <String, Object?>{
    'sessionId': sessionId,
  };

  @override
  void _decodeResult(Object? value) {
    final result = _jsonObject(value, 'Runtime diagnostics stop result');
    if (result['stopped'] != true) throw _invalidDiagnosticsResponse('stop');
  }
}

@immutable
final class RuntimeDiagnosticsStatisticsInvocation
    extends PluginInvocation<RuntimeDiagnosticsStorageStatistics> {
  const RuntimeDiagnosticsStatisticsInvocation();

  @override
  String get _wireMethod => 'diagnostics.statistics.get.v1';

  @override
  Map<String, Object?> get _wireParams => const <String, Object?>{};

  @override
  RuntimeDiagnosticsStorageStatistics _decodeResult(Object? value) {
    final item = _jsonObject(value, 'Runtime diagnostics statistics');
    return RuntimeDiagnosticsStorageStatistics(
      attachmentCount: _requiredInt(item, 'attachmentCount'),
      detailCount: _requiredInt(item, 'detailCount'),
      detailTextBytes: _requiredInt(item, 'detailTextBytes'),
      eventCount: _requiredInt(item, 'eventCount'),
      eventTextBytes: _requiredInt(item, 'eventTextBytes'),
      logicalStoredBytes: _requiredInt(item, 'logicalStoredBytes'),
      memoryDetailBytes: _requiredInt(item, 'memoryDetailBytes'),
      runCount: _requiredInt(item, 'runCount'),
      segmentCount: _requiredInt(item, 'segmentCount'),
      sessionCount: _requiredInt(item, 'sessionCount'),
    );
  }
}

RuntimeDiagnosticPage<T> _decodeRuntimePage<T>(
  Object? value,
  T Function(Object?) decodeItem,
  String label,
) {
  final page = _jsonObject(value, 'Runtime $label page');
  final items = page['items'];
  final nextCursor = page['nextCursor'];
  if (items is! List<Object?> ||
      (nextCursor != null && nextCursor is! String)) {
    throw _invalidDiagnosticsResponse(label);
  }
  return RuntimeDiagnosticPage<T>(
    items: List<T>.unmodifiable(items.map(decodeItem)),
    nextCursor: nextCursor as String?,
  );
}

RuntimeDiagnosticsSession _decodeRuntimeSession(Object? value) {
  final item = _jsonObject(value, 'Runtime diagnostics session');
  return RuntimeDiagnosticsSession(
    attachmentCount: _requiredInt(item, 'attachmentCount'),
    endedAtUtcMicros: _optionalInt(item, 'endedAtUtcMicros'),
    eventCount: _requiredInt(item, 'eventCount'),
    expiresAtUtcMicros: _optionalInt(item, 'expiresAtUtcMicros'),
    payloadKind: _requiredEnum(
      item,
      'payloadKind',
      RuntimeDiagnosticPayloadKind.values,
    ),
    sessionId: _requiredString(item, 'sessionId'),
    sourceRunId: _requiredString(item, 'sourceRunId'),
    startedAtUtcMicros: _requiredInt(item, 'startedAtUtcMicros'),
    state: _requiredEnum(item, 'state', RuntimeDiagnosticSessionState.values),
    storedBytes: _requiredInt(item, 'storedBytes'),
  );
}

RuntimeDiagnosticsEvent _decodeRuntimeEvent(Object? value) {
  final item = _jsonObject(value, 'Runtime diagnostics event');
  final attributes = item['attributes'];
  final decodedAttributes = attributes == null
      ? null
      : _decodeRuntimeDiagnosticValue(attributes);
  if (decodedAttributes != null &&
      decodedAttributes is! RuntimeDiagnosticObjectValue) {
    throw _invalidDiagnosticsResponse('event attributes');
  }
  final rawFlags = item['flags'];
  if (rawFlags is! List<Object?> || rawFlags.any((flag) => flag is! String)) {
    throw _invalidDiagnosticsResponse('event flags');
  }
  return RuntimeDiagnosticsEvent(
    attachmentCount: _requiredInt(item, 'attachmentCount'),
    attributes: decodedAttributes as RuntimeDiagnosticObjectValue?,
    capturedBytes: _requiredInt(item, 'capturedBytes'),
    captureSessionId: _requiredString(item, 'captureSessionId'),
    component: _requiredString(item, 'component'),
    durationMicros: _optionalInt(item, 'durationMicros'),
    envelopeVersion: _requiredInt(item, 'envelopeVersion'),
    eventId: _requiredString(item, 'eventId'),
    eventName: _requiredString(item, 'eventName'),
    eventSchemaVersion: _requiredInt(item, 'eventSchemaVersion'),
    flags: List<String>.unmodifiable(rawFlags.cast<String>()),
    monotonicOffsetMicros: _requiredInt(item, 'monotonicOffsetMicros'),
    occurredAtUtcMicros: _requiredInt(item, 'occurredAtUtcMicros'),
    outcome: _optionalEnum(item, 'outcome', RuntimeDiagnosticOutcome.values),
    parentSpanId: _optionalString(item, 'parentSpanId'),
    phase: _requiredEnum(item, 'phase', RuntimeDiagnosticPhase.values),
    severity: _requiredEnum(item, 'severity', RuntimeDiagnosticSeverity.values),
    sourceRunId: _requiredString(item, 'sourceRunId'),
    sourceSequence: _requiredInt(item, 'sourceSequence'),
    spanId: _optionalString(item, 'spanId'),
    summary: _requiredString(item, 'summary'),
    traceId: _optionalString(item, 'traceId'),
  );
}

RuntimeDiagnosticAttachment _decodeRuntimeAttachment(Object? value) {
  final item = _jsonObject(value, 'Runtime diagnostic attachment');
  return RuntimeDiagnosticAttachment(
    attachmentId: _requiredString(item, 'attachmentId'),
    captureState: _requiredEnum(
      item,
      'captureState',
      RuntimeDiagnosticCaptureState.values,
    ),
    charset: _optionalString(item, 'charset'),
    eventId: _requiredString(item, 'eventId'),
    formatId: _requiredString(item, 'formatId'),
    formatVersion: _requiredInt(item, 'formatVersion'),
    kind: _requiredString(item, 'kind'),
    mediaType: _requiredString(item, 'mediaType'),
    privacyClass: _requiredEnum(
      item,
      'privacyClass',
      RuntimeDiagnosticPrivacyClass.values,
    ),
    rawByteLength: _requiredInt(item, 'rawByteLength'),
    redactionVersion: _requiredInt(item, 'redactionVersion'),
    schemaId: _optionalString(item, 'schemaId'),
    schemaVersion: _optionalInt(item, 'schemaVersion'),
    sha256: _optionalString(item, 'sha256'),
    storedByteLength: _requiredInt(item, 'storedByteLength'),
    truncationReason: _optionalString(item, 'truncationReason'),
  );
}

RuntimeDiagnosticValue _decodeRuntimeDiagnosticValue(Object? value) {
  final item = _jsonObject(value, 'Runtime diagnostic value');
  final type = _requiredString(item, 'type');
  return switch (type) {
    'null' => const RuntimeDiagnosticNullValue(),
    'bool' => RuntimeDiagnosticBoolValue(_requiredBool(item, 'value')),
    'string' => RuntimeDiagnosticStringValue(_requiredString(item, 'value')),
    'int64' => RuntimeDiagnosticInt64Value(_requiredString(item, 'value')),
    'double' => RuntimeDiagnosticDoubleValue(
      _requiredNumber(item, 'value').toDouble(),
    ),
    'list' => RuntimeDiagnosticListValue(
      List<RuntimeDiagnosticValue>.unmodifiable(
        _requiredList(item, 'items').map(_decodeRuntimeDiagnosticValue),
      ),
    ),
    'object' => RuntimeDiagnosticObjectValue(
      Map<String, RuntimeDiagnosticValue>.unmodifiable(
        _requiredObject(item, 'fields').map(
          (key, child) => MapEntry(key, _decodeRuntimeDiagnosticValue(child)),
        ),
      ),
    ),
    'redacted' => RuntimeDiagnosticRedactedValue(
      _requiredString(item, 'reason'),
    ),
    'truncated' => RuntimeDiagnosticTruncatedValue(
      _requiredString(item, 'reason'),
      originalCount: _optionalInt(item, 'originalCount'),
    ),
    'attachmentRef' => RuntimeDiagnosticAttachmentReferenceValue(
      _requiredString(item, 'attachmentId'),
    ),
    _ => throw _invalidDiagnosticsResponse('diagnostic value'),
  };
}

PluginRuntimeException _invalidDiagnosticsResponse(String label) =>
    PluginRuntimeException(
      'invalid_response',
      'The Runtime returned invalid $label.',
    );

String _requiredString(Map<String, Object?> item, String key) {
  final value = item[key];
  if (value is! String) throw _invalidDiagnosticsResponse(key);
  return value;
}

String? _optionalString(Map<String, Object?> item, String key) {
  final value = item[key];
  if (value == null) return null;
  if (value is! String) throw _invalidDiagnosticsResponse(key);
  return value;
}

int _requiredInt(Map<String, Object?> item, String key) {
  final value = item[key];
  if (value is! int) throw _invalidDiagnosticsResponse(key);
  return value;
}

int? _optionalInt(Map<String, Object?> item, String key) {
  final value = item[key];
  if (value == null) return null;
  if (value is! int) throw _invalidDiagnosticsResponse(key);
  return value;
}

bool _requiredBool(Map<String, Object?> item, String key) {
  final value = item[key];
  if (value is! bool) throw _invalidDiagnosticsResponse(key);
  return value;
}

num _requiredNumber(Map<String, Object?> item, String key) {
  final value = item[key];
  if (value is! num || !value.isFinite) throw _invalidDiagnosticsResponse(key);
  return value;
}

List<Object?> _requiredList(Map<String, Object?> item, String key) {
  final value = item[key];
  if (value is! List<Object?>) throw _invalidDiagnosticsResponse(key);
  return value;
}

Map<String, Object?> _requiredObject(Map<String, Object?> item, String key) =>
    _jsonObject(item[key], key);

T _requiredEnum<T extends Enum>(
  Map<String, Object?> item,
  String key,
  List<T> values,
) {
  final name = _requiredString(item, key);
  return values.cast<T?>().firstWhere(
        (value) => value?.name == name,
        orElse: () => null,
      ) ??
      (throw _invalidDiagnosticsResponse(key));
}

T? _optionalEnum<T extends Enum>(
  Map<String, Object?> item,
  String key,
  List<T> values,
) {
  if (item[key] == null) return null;
  return _requiredEnum(item, key, values);
}
