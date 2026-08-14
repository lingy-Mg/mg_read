import 'dart:async';
import 'dart:math';

import 'diagnostic_event.dart';
import 'diagnostic_privacy.dart';
import 'diagnostic_registry.dart';
import 'diagnostic_value.dart';

typedef DiagnosticAttributesBuilder = DiagnosticObjectValue Function();

const Symbol _diagnosticTraceContextZoneKey = #mgReadDiagnosticTraceContext;

abstract interface class DiagnosticEventSink {
  bool isEnabled({
    required String component,
    required DiagnosticSeverity severity,
    required DiagnosticPayloadKind payloadKind,
  });

  /// Synchronously accepts or rejects an already bounded event.
  bool add(DiagnosticEvent event);

  Future<void> flush({required Duration timeout});

  Future<void> close({required Duration timeout});
}

abstract interface class DiagnosticIdGenerator {
  String nextId(String namespace);
}

final class SecureDiagnosticIdGenerator implements DiagnosticIdGenerator {
  SecureDiagnosticIdGenerator({Random? random})
    : _random = random ?? Random.secure();

  final Random _random;

  @override
  String nextId(String namespace) {
    validateDiagnosticName(namespace, 'namespace');
    final buffer = StringBuffer('${namespace}_');
    for (var index = 0; index < 16; index += 1) {
      buffer.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }
}

abstract interface class DiagnosticClock {
  DateTime nowUtc();
}

final class SystemDiagnosticClock implements DiagnosticClock {
  const SystemDiagnosticClock();

  @override
  DateTime nowUtc() => DateTime.now().toUtc();
}

final class DiagnosticEmitResult {
  const DiagnosticEmitResult({required this.accepted, this.event});

  const DiagnosticEmitResult.filtered() : accepted = false, event = null;

  final bool accepted;
  final DiagnosticEvent? event;
}

/// Process-scoped diagnostics management layer.
///
/// The manager performs only enablement, bounded schema/privacy validation and
/// synchronous queue admission. The sink owns all encoding and I/O work.
final class DiagnosticsManager {
  factory DiagnosticsManager({
    required DiagnosticEventSink sink,
    required DiagnosticEventRegistry registry,
    required DiagnosticSource source,
    DiagnosticPrivacyPolicy? privacyPolicy,
    DiagnosticIdGenerator? idGenerator,
    DiagnosticClock? clock,
    String? sourceRunId,
    String buildMode = 'unknown',
    String platform = 'unknown',
  }) {
    final effectiveIdGenerator = idGenerator ?? SecureDiagnosticIdGenerator();
    return DiagnosticsManager._(
      sink: sink,
      registry: registry,
      source: source,
      privacyPolicy: privacyPolicy ?? DiagnosticPrivacyPolicy(),
      idGenerator: effectiveIdGenerator,
      clock: clock ?? const SystemDiagnosticClock(),
      sourceRunId: sourceRunId ?? effectiveIdGenerator.nextId('run'),
      buildMode: buildMode,
      platform: platform,
    );
  }

  DiagnosticsManager._({
    required this.sink,
    required this.registry,
    required this.source,
    required this.privacyPolicy,
    required this.idGenerator,
    required this.clock,
    required this.sourceRunId,
    required this.buildMode,
    required this.platform,
  }) {
    validateDiagnosticOpaqueId(sourceRunId, 'sourceRunId');
    _monotonic.start();
  }

  final DiagnosticEventSink sink;
  final DiagnosticEventRegistry registry;
  final DiagnosticSource source;
  final DiagnosticPrivacyPolicy privacyPolicy;
  final DiagnosticIdGenerator idGenerator;
  final DiagnosticClock clock;
  final String sourceRunId;
  final String buildMode;
  final String platform;
  final Stopwatch _monotonic = Stopwatch();
  final Set<DiagnosticSpanHandle> _openSpans = <DiagnosticSpanHandle>{};
  Future<void>? _closeFuture;
  var _sourceSequence = 0;
  var _closed = false;

  bool get isClosed => _closed;

  DiagnosticTraceContext? get currentTraceContext =>
      Zone.current[_diagnosticTraceContextZoneKey] as DiagnosticTraceContext?;

  bool isEnabled(
    DiagnosticEventDefinition definition, {
    DiagnosticSeverity? severity,
    DiagnosticPayloadKind payloadKind = DiagnosticPayloadKind.metadataOnly,
  }) {
    if (_closed) return false;
    final registered = registry.requireDefinition(definition);
    return _isSinkEnabled(
      component: registered.component,
      severity: severity ?? registered.defaultSeverity,
      payloadKind: payloadKind,
    );
  }

  DiagnosticEmitResult emit(
    DiagnosticEventDefinition definition, {
    DiagnosticAttributesBuilder? attributes,
    DiagnosticSeverity? severity,
    DiagnosticTraceContext? traceContext,
    DiagnosticPrivacyContext privacyContext = const DiagnosticPrivacyContext(),
    String? captureSessionId,
    Set<DiagnosticEventFlag> flags = const <DiagnosticEventFlag>{},
  }) {
    _ensureOpen();
    final registered = registry.requireDefinition(definition);
    if (registered.kind != DiagnosticDefinitionKind.instant) {
      throw StateError('${registered.name} must be emitted as a span.');
    }
    final effectiveSeverity = severity ?? registered.defaultSeverity;
    if (!_isSinkEnabled(
      component: registered.component,
      severity: effectiveSeverity,
      payloadKind: privacyContext.payloadKind,
    )) {
      return const DiagnosticEmitResult.filtered();
    }
    return _emitEvent(
      definition: registered,
      phase: DiagnosticPhase.instant,
      severity: effectiveSeverity,
      attributes: attributes,
      traceContext: traceContext,
      privacyContext: privacyContext,
      captureSessionId: captureSessionId,
      flags: flags,
    );
  }

  DiagnosticSpanHandle startSpan(
    DiagnosticEventDefinition definition, {
    DiagnosticAttributesBuilder? attributes,
    DiagnosticTraceContext? parentContext,
    DiagnosticPrivacyContext privacyContext = const DiagnosticPrivacyContext(),
    String? captureSessionId,
  }) {
    _ensureOpen();
    final registered = registry.requireDefinition(definition);
    if (registered.kind != DiagnosticDefinitionKind.span) {
      throw StateError('${registered.name} is not a span definition.');
    }
    final spanId = idGenerator.nextId('span');
    final effectiveParent = parentContext ?? currentTraceContext;
    final context = effectiveParent == null
        ? DiagnosticTraceContext(
            traceId: idGenerator.nextId('trace'),
            spanId: spanId,
          )
        : effectiveParent.child(spanId);
    final handle = DiagnosticSpanHandle._(
      manager: this,
      definition: registered,
      traceContext: context,
      privacyContext: privacyContext,
      captureSessionId: captureSessionId,
      startedAtMicros: _monotonic.elapsedMicroseconds,
    );
    _openSpans.add(handle);
    final severity = registered.defaultSeverity;
    if (_isSinkEnabled(
      component: registered.component,
      severity: severity,
      payloadKind: privacyContext.payloadKind,
    )) {
      _emitEvent(
        definition: registered,
        phase: DiagnosticPhase.start,
        severity: severity,
        attributes: attributes,
        traceContext: context,
        privacyContext: privacyContext,
        captureSessionId: captureSessionId,
      );
    }
    return handle;
  }

  Future<T> runSpan<T>(
    DiagnosticEventDefinition definition,
    Future<T> Function(DiagnosticSpanHandle span) operation, {
    DiagnosticAttributesBuilder? startAttributes,
    DiagnosticObjectValue Function(T result)? successAttributes,
    DiagnosticObjectValue Function(Object error)? errorAttributes,
    DiagnosticTraceContext? parentContext,
  }) async {
    final span = startSpan(
      definition,
      attributes: startAttributes,
      parentContext: parentContext,
    );
    try {
      final result = await runZoned(
        () => operation(span),
        zoneValues: <Object?, Object?>{
          _diagnosticTraceContextZoneKey: span.traceContext,
        },
      );
      span.end(
        DiagnosticOutcome.success,
        attributes: successAttributes?.call(result),
      );
      return result;
    } catch (error, stackTrace) {
      span.end(
        DiagnosticOutcome.error,
        attributes:
            errorAttributes?.call(error) ??
            DiagnosticObjectValue(<String, DiagnosticValue>{
              if (definition.fields.containsKey('errorCode'))
                'errorCode': DiagnosticValue.string('unclassified'),
              if (definition.fields.containsKey('stackFingerprint'))
                'stackFingerprint': DiagnosticValue.string(
                  privacyPolicy.stackFingerprint(stackTrace),
                ),
            }),
      );
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  T runSpanSync<T>(
    DiagnosticEventDefinition definition,
    T Function(DiagnosticSpanHandle span) operation, {
    DiagnosticAttributesBuilder? startAttributes,
    DiagnosticObjectValue Function(T result)? successAttributes,
    DiagnosticObjectValue Function(Object error)? errorAttributes,
    DiagnosticTraceContext? parentContext,
  }) {
    final span = startSpan(
      definition,
      attributes: startAttributes,
      parentContext: parentContext,
    );
    try {
      final result = runZoned(
        () => operation(span),
        zoneValues: <Object?, Object?>{
          _diagnosticTraceContextZoneKey: span.traceContext,
        },
      );
      span.complete(attributes: successAttributes?.call(result));
      return result;
    } catch (error, stackTrace) {
      span.fail(
        attributes:
            errorAttributes?.call(error) ??
            DiagnosticObjectValue(<String, DiagnosticValue>{
              if (definition.fields.containsKey('errorCode'))
                'errorCode': DiagnosticValue.string('unclassified'),
              if (definition.fields.containsKey('stackFingerprint'))
                'stackFingerprint': DiagnosticValue.string(
                  privacyPolicy.stackFingerprint(stackTrace),
                ),
            }),
      );
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> flush({Duration timeout = const Duration(seconds: 2)}) async {
    if (_closed) return;
    try {
      await sink.flush(timeout: timeout);
    } catch (_) {
      // Sink failures are isolated from the business operation requesting a
      // best-effort flush. The persistent sink accounts writer failures.
    }
  }

  Future<void> close({Duration timeout = const Duration(seconds: 2)}) =>
      _closeFuture ??= _close(timeout);

  Future<void> _close(Duration timeout) async {
    if (_closed) return;
    for (final span in _openSpans.toList(growable: false)) {
      span.end(DiagnosticOutcome.incomplete);
    }
    _closed = true;
    try {
      await sink.close(timeout: timeout);
    } catch (_) {
      // Diagnostics shutdown is best effort and never changes app shutdown.
    }
    _monotonic.stop();
  }

  DiagnosticEmitResult _finishSpan(
    DiagnosticSpanHandle span,
    DiagnosticOutcome outcome,
    DiagnosticObjectValue? attributes,
  ) {
    if (!_openSpans.remove(span)) {
      throw StateError('Diagnostic span already ended.');
    }
    final definition = span.definition;
    if (!definition.allowedOutcomes.contains(outcome)) {
      throw StateError('${definition.name} does not allow ${outcome.name}.');
    }
    final severity = definition.severityFor(outcome: outcome);
    if (!_isSinkEnabled(
      component: definition.component,
      severity: severity,
      payloadKind: span.privacyContext.payloadKind,
    )) {
      return const DiagnosticEmitResult.filtered();
    }
    return _emitEvent(
      definition: definition,
      phase: DiagnosticPhase.terminal,
      outcome: outcome,
      durationMicros: _monotonic.elapsedMicroseconds - span.startedAtMicros,
      severity: severity,
      attributes: attributes == null ? null : () => attributes,
      traceContext: span.traceContext,
      privacyContext: span.privacyContext,
      captureSessionId: span.captureSessionId,
      flags: outcome == DiagnosticOutcome.incomplete
          ? const <DiagnosticEventFlag>{DiagnosticEventFlag.incomplete}
          : const <DiagnosticEventFlag>{},
    );
  }

  DiagnosticEmitResult _emitEvent({
    required DiagnosticEventDefinition definition,
    required DiagnosticPhase phase,
    required DiagnosticSeverity severity,
    DiagnosticOutcome? outcome,
    int? durationMicros,
    DiagnosticAttributesBuilder? attributes,
    DiagnosticTraceContext? traceContext,
    required DiagnosticPrivacyContext privacyContext,
    String? captureSessionId,
    Set<DiagnosticEventFlag> flags = const <DiagnosticEventFlag>{},
  }) {
    final effectiveTraceContext = traceContext ?? currentTraceContext;
    final rawAttributes = attributes?.call() ?? DiagnosticObjectValue.empty;
    definition.validateAttributes(rawAttributes, phase);
    final sanitized = privacyPolicy.sanitizeAttributes(
      definition: definition,
      attributes: rawAttributes,
      context: privacyContext,
    );
    definition.validateAttributes(sanitized, phase);
    final effectiveFlags = <DiagnosticEventFlag>{...flags};
    if (sanitized != rawAttributes) {
      effectiveFlags.add(DiagnosticEventFlag.redacted);
    }
    _sourceSequence += 1;
    final event = DiagnosticEvent(
      eventId: idGenerator.nextId('event'),
      source: source,
      component: definition.component,
      sourceRunId: sourceRunId,
      sourceSequence: _sourceSequence,
      occurredAtUtcMicros: clock.nowUtc().microsecondsSinceEpoch,
      monotonicOffsetMicros: _monotonic.elapsedMicroseconds,
      severity: severity,
      eventName: definition.eventName(phase, outcome: outcome),
      eventSchemaVersion: definition.schemaVersion,
      traceId: effectiveTraceContext?.traceId,
      spanId: effectiveTraceContext?.spanId,
      parentSpanId: effectiveTraceContext?.parentSpanId,
      phase: phase,
      outcome: outcome,
      durationMicros: durationMicros,
      summary: definition.summary,
      attributes: sanitized,
      captureSessionId: captureSessionId,
      flags: effectiveFlags,
    );
    return DiagnosticEmitResult(accepted: _addToSink(event), event: event);
  }

  bool _isSinkEnabled({
    required String component,
    required DiagnosticSeverity severity,
    required DiagnosticPayloadKind payloadKind,
  }) {
    try {
      return sink.isEnabled(
        component: component,
        severity: severity,
        payloadKind: payloadKind,
      );
    } catch (_) {
      return false;
    }
  }

  bool _addToSink(DiagnosticEvent event) {
    try {
      return sink.add(event);
    } catch (_) {
      return false;
    }
  }

  void _ensureOpen() {
    if (_closed) throw StateError('DiagnosticsManager is closed.');
  }
}

final class DiagnosticSpanHandle {
  DiagnosticSpanHandle._({
    required this.manager,
    required this.definition,
    required this.traceContext,
    required this.privacyContext,
    required this.captureSessionId,
    required this.startedAtMicros,
  });

  final DiagnosticsManager manager;
  final DiagnosticEventDefinition definition;
  final DiagnosticTraceContext traceContext;
  final DiagnosticPrivacyContext privacyContext;
  final String? captureSessionId;
  final int startedAtMicros;
  bool _ended = false;

  bool get isEnded => _ended;

  DiagnosticEmitResult end(
    DiagnosticOutcome outcome, {
    DiagnosticObjectValue? attributes,
  }) {
    if (_ended) throw StateError('Diagnostic span already ended.');
    _ended = true;
    return manager._finishSpan(this, outcome, attributes);
  }

  DiagnosticEmitResult complete({DiagnosticObjectValue? attributes}) =>
      end(DiagnosticOutcome.success, attributes: attributes);

  DiagnosticEmitResult fail({DiagnosticObjectValue? attributes}) =>
      end(DiagnosticOutcome.error, attributes: attributes);

  DiagnosticEmitResult cancel({DiagnosticObjectValue? attributes}) =>
      end(DiagnosticOutcome.cancelled, attributes: attributes);

  DiagnosticEmitResult timeout({DiagnosticObjectValue? attributes}) =>
      end(DiagnosticOutcome.timeout, attributes: attributes);

  DiagnosticEmitResult overload({DiagnosticObjectValue? attributes}) =>
      end(DiagnosticOutcome.overloaded, attributes: attributes);
}

final class NoopDiagnosticEventSink implements DiagnosticEventSink {
  const NoopDiagnosticEventSink();

  @override
  bool isEnabled({
    required String component,
    required DiagnosticSeverity severity,
    required DiagnosticPayloadKind payloadKind,
  }) => false;

  @override
  bool add(DiagnosticEvent event) => false;

  @override
  Future<void> flush({required Duration timeout}) async {}

  @override
  Future<void> close({required Duration timeout}) async {}
}
