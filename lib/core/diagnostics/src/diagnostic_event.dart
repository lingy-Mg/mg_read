import 'dart:collection';

import 'diagnostic_value.dart';

const int currentDiagnosticEnvelopeVersion = 1;

enum DiagnosticSource { app, runtime }

enum DiagnosticSeverity { trace, debug, info, warn, error, fatal }

enum DiagnosticPhase { instant, start, terminal }

enum DiagnosticOutcome {
  success,
  error,
  cancelled,
  timeout,
  overloaded,
  incomplete,
}

enum DiagnosticPayloadKind {
  metadataOnly,
  safeStructured,
  contentPayload,
  restrictedRaw,
}

enum DiagnosticPrivacyClass { public, internal, content, restricted, secret }

enum DiagnosticCaptureState {
  captured,
  truncated,
  policyBlocked,
  pressureDropped,
  failed,
}

enum DiagnosticStorageCodec { identity, gzip }

enum DiagnosticEventFlag {
  sampled,
  truncated,
  redacted,
  droppedPayload,
  incomplete,
}

/// Trace identifiers crossing app and Runtime use this public shape only.
final class DiagnosticTraceContext {
  DiagnosticTraceContext({
    required this.traceId,
    required this.spanId,
    this.parentSpanId,
  }) {
    _validateOpaqueId(traceId, 'traceId');
    _validateOpaqueId(spanId, 'spanId');
    if (parentSpanId case final value?) {
      _validateOpaqueId(value, 'parentSpanId');
    }
  }

  final String traceId;
  final String spanId;
  final String? parentSpanId;

  DiagnosticTraceContext child(String childSpanId) => DiagnosticTraceContext(
    traceId: traceId,
    spanId: childSpanId,
    parentSpanId: spanId,
  );
}

/// Immutable, query-friendly diagnostic event envelope.
final class DiagnosticEvent {
  DiagnosticEvent({
    this.envelopeVersion = currentDiagnosticEnvelopeVersion,
    required this.eventId,
    required this.source,
    required this.component,
    required this.sourceRunId,
    required this.sourceSequence,
    required this.occurredAtUtcMicros,
    required this.monotonicOffsetMicros,
    required this.severity,
    required this.eventName,
    required this.eventSchemaVersion,
    required this.phase,
    required this.summary,
    required this.attributes,
    this.traceId,
    this.spanId,
    this.parentSpanId,
    this.outcome,
    this.durationMicros,
    this.captureSessionId,
    this.attachmentCount = 0,
    this.capturedBytes = 0,
    Set<DiagnosticEventFlag> flags = const <DiagnosticEventFlag>{},
    Map<String, Object?> extensionFields = const <String, Object?>{},
  }) : flags = Set<DiagnosticEventFlag>.unmodifiable(flags),
       extensionFields = Map<String, Object?>.unmodifiable(extensionFields) {
    if (envelopeVersion <= 0 || eventSchemaVersion <= 0) {
      throw ArgumentError('Diagnostic versions must be positive.');
    }
    _validateOpaqueId(eventId, 'eventId');
    _validateOpaqueId(sourceRunId, 'sourceRunId');
    _validateStableName(component, 'component');
    _validateStableName(eventName, 'eventName');
    if (sourceSequence <= 0 || occurredAtUtcMicros <= 0) {
      throw ArgumentError('Sequence and UTC timestamp must be positive.');
    }
    if (monotonicOffsetMicros < 0 ||
        attachmentCount < 0 ||
        capturedBytes < 0 ||
        (durationMicros != null && durationMicros! < 0)) {
      throw ArgumentError('Diagnostic counters cannot be negative.');
    }
    if (summary.isEmpty || summary.length > 512 || summary.contains('\n')) {
      throw ArgumentError.value(summary, 'summary');
    }
    if (phase == DiagnosticPhase.terminal && outcome == null) {
      throw ArgumentError('A terminal diagnostic event needs an outcome.');
    }
    if (phase != DiagnosticPhase.terminal && outcome != null) {
      throw ArgumentError('Only terminal diagnostic events have outcomes.');
    }
    if ((traceId == null) != (spanId == null)) {
      throw ArgumentError('traceId and spanId must either both exist or not.');
    }
    for (final id in <(String?, String)>[
      (traceId, 'traceId'),
      (spanId, 'spanId'),
      (parentSpanId, 'parentSpanId'),
      (captureSessionId, 'captureSessionId'),
    ]) {
      if (id.$1 case final value?) _validateOpaqueId(value, id.$2);
    }
  }

  final int envelopeVersion;
  final String eventId;
  final DiagnosticSource source;
  final String component;
  final String sourceRunId;
  final int sourceSequence;
  final int occurredAtUtcMicros;
  final int monotonicOffsetMicros;
  final DiagnosticSeverity severity;
  final String eventName;
  final int eventSchemaVersion;
  final String? traceId;
  final String? spanId;
  final String? parentSpanId;
  final DiagnosticPhase phase;
  final DiagnosticOutcome? outcome;
  final int? durationMicros;
  final String summary;
  final DiagnosticObjectValue attributes;
  final String? captureSessionId;
  final int attachmentCount;
  final int capturedBytes;
  final Set<DiagnosticEventFlag> flags;

  /// Unknown envelope fields are retained for read-only future-version data.
  final Map<String, Object?> extensionFields;

  bool get isFutureEnvelope =>
      envelopeVersion > currentDiagnosticEnvelopeVersion;

  DiagnosticTraceContext? get traceContext {
    if (traceId == null || spanId == null) return null;
    return DiagnosticTraceContext(
      traceId: traceId!,
      spanId: spanId!,
      parentSpanId: parentSpanId,
    );
  }

  DiagnosticEvent copyWith({
    String? captureSessionId,
    int? attachmentCount,
    int? capturedBytes,
    Set<DiagnosticEventFlag>? flags,
  }) => DiagnosticEvent(
    envelopeVersion: envelopeVersion,
    eventId: eventId,
    source: source,
    component: component,
    sourceRunId: sourceRunId,
    sourceSequence: sourceSequence,
    occurredAtUtcMicros: occurredAtUtcMicros,
    monotonicOffsetMicros: monotonicOffsetMicros,
    severity: severity,
    eventName: eventName,
    eventSchemaVersion: eventSchemaVersion,
    traceId: traceId,
    spanId: spanId,
    parentSpanId: parentSpanId,
    phase: phase,
    outcome: outcome,
    durationMicros: durationMicros,
    summary: summary,
    attributes: attributes,
    captureSessionId: captureSessionId ?? this.captureSessionId,
    attachmentCount: attachmentCount ?? this.attachmentCount,
    capturedBytes: capturedBytes ?? this.capturedBytes,
    flags: flags ?? this.flags,
    extensionFields: extensionFields,
  );
}

/// Stable codec used by TXT records, export manifests and Runtime fixtures.
final class DiagnosticEventCodec {
  const DiagnosticEventCodec({this.valueCodec = const DiagnosticValueCodec()});

  final DiagnosticValueCodec valueCodec;

  Map<String, Object?> encode(DiagnosticEvent event) => <String, Object?>{
    ...event.extensionFields,
    'envelopeVersion': event.envelopeVersion,
    'eventId': event.eventId,
    'source': event.source.name,
    'component': event.component,
    'sourceRunId': event.sourceRunId,
    'sourceSequence': event.sourceSequence,
    'occurredAtUtcMicros': event.occurredAtUtcMicros,
    'monotonicOffsetMicros': event.monotonicOffsetMicros,
    'severity': event.severity.name,
    'eventName': event.eventName,
    'eventSchemaVersion': event.eventSchemaVersion,
    'traceId': ?event.traceId,
    'spanId': ?event.spanId,
    'parentSpanId': ?event.parentSpanId,
    'phase': event.phase.name,
    'outcome': ?event.outcome?.name,
    'durationMicros': ?event.durationMicros,
    'summary': event.summary,
    'attributes': event.attributes.toWireValue(),
    'captureSessionId': ?event.captureSessionId,
    'attachmentCount': event.attachmentCount,
    'capturedBytes': event.capturedBytes,
    'flags': event.flags.map((flag) => flag.name).toList(growable: false),
  };

  DiagnosticEvent decode(Map<String, Object?> wireValue) {
    final known = <String>{
      'envelopeVersion',
      'eventId',
      'source',
      'component',
      'sourceRunId',
      'sourceSequence',
      'occurredAtUtcMicros',
      'monotonicOffsetMicros',
      'severity',
      'eventName',
      'eventSchemaVersion',
      'traceId',
      'spanId',
      'parentSpanId',
      'phase',
      'outcome',
      'durationMicros',
      'summary',
      'attributes',
      'captureSessionId',
      'attachmentCount',
      'capturedBytes',
      'flags',
    };
    final attributes = valueCodec.decode(wireValue['attributes']);
    if (attributes is! DiagnosticObjectValue) {
      throw const FormatException('Event attributes must be an object.');
    }
    return DiagnosticEvent(
      envelopeVersion: _integer(wireValue, 'envelopeVersion'),
      eventId: _string(wireValue, 'eventId'),
      source: _enumByName(
        DiagnosticSource.values,
        _string(wireValue, 'source'),
        'source',
      ),
      component: _string(wireValue, 'component'),
      sourceRunId: _string(wireValue, 'sourceRunId'),
      sourceSequence: _integer(wireValue, 'sourceSequence'),
      occurredAtUtcMicros: _integer(wireValue, 'occurredAtUtcMicros'),
      monotonicOffsetMicros: _integer(wireValue, 'monotonicOffsetMicros'),
      severity: _enumByName(
        DiagnosticSeverity.values,
        _string(wireValue, 'severity'),
        'severity',
      ),
      eventName: _string(wireValue, 'eventName'),
      eventSchemaVersion: _integer(wireValue, 'eventSchemaVersion'),
      traceId: wireValue['traceId'] as String?,
      spanId: wireValue['spanId'] as String?,
      parentSpanId: wireValue['parentSpanId'] as String?,
      phase: _enumByName(
        DiagnosticPhase.values,
        _string(wireValue, 'phase'),
        'phase',
      ),
      outcome: wireValue['outcome'] == null
          ? null
          : _enumByName(
              DiagnosticOutcome.values,
              _string(wireValue, 'outcome'),
              'outcome',
            ),
      durationMicros: wireValue['durationMicros'] as int?,
      summary: _string(wireValue, 'summary'),
      attributes: attributes,
      captureSessionId: wireValue['captureSessionId'] as String?,
      attachmentCount: _integer(wireValue, 'attachmentCount'),
      capturedBytes: _integer(wireValue, 'capturedBytes'),
      flags: _stringList(wireValue, 'flags')
          .map((name) => _enumByName(DiagnosticEventFlag.values, name, 'flags'))
          .toSet(),
      extensionFields: <String, Object?>{
        for (final entry in wireValue.entries)
          if (!known.contains(entry.key)) entry.key: entry.value,
      },
    );
  }

  String _string(Map<String, Object?> value, String key) {
    final field = value[key];
    if (field is! String) throw FormatException('$key must be a string.');
    return field;
  }

  int _integer(Map<String, Object?> value, String key) {
    final field = value[key];
    if (field is! int) throw FormatException('$key must be an integer.');
    return field;
  }

  List<String> _stringList(Map<String, Object?> value, String key) {
    final field = value[key];
    if (field is! List<Object?> || field.any((item) => item is! String)) {
      throw FormatException('$key must be a string list.');
    }
    return field.cast<String>();
  }

  T _enumByName<T extends Enum>(List<T> values, String name, String key) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    throw FormatException('Unknown $key value: $name.');
  }
}

void validateDiagnosticName(String value, String parameterName) =>
    _validateStableName(value, parameterName);

void validateDiagnosticFieldName(String value, String parameterName) {
  if (!_fieldName.hasMatch(value)) {
    throw ArgumentError.value(value, parameterName, 'Not a stable field name.');
  }
}

void validateDiagnosticOpaqueId(String value, String parameterName) =>
    _validateOpaqueId(value, parameterName);

void _validateStableName(String value, String parameterName) {
  if (!_stableName.hasMatch(value)) {
    throw ArgumentError.value(value, parameterName, 'Not a stable name.');
  }
}

void _validateOpaqueId(String value, String parameterName) {
  if (!_opaqueId.hasMatch(value)) {
    throw ArgumentError.value(value, parameterName, 'Not an opaque ID.');
  }
}

final RegExp _stableName = RegExp(r'^[a-z][a-z0-9]*(?:[._-][a-z][a-z0-9]*)*$');
final RegExp _fieldName = RegExp(r'^[A-Za-z][A-Za-z0-9_.-]{0,127}$');
final RegExp _opaqueId = RegExp(r'^[A-Za-z0-9_-]{16,128}$');

Map<String, Object?> immutableExtensionFields(Map<String, Object?> values) =>
    UnmodifiableMapView<String, Object?>(values);
