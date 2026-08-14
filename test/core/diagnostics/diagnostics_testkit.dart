import 'package:mg_read/core/diagnostics/diagnostics.dart';

final class RecordingDiagnosticEventSink implements DiagnosticEventSink {
  RecordingDiagnosticEventSink({
    this.minimumSeverity = DiagnosticSeverity.trace,
    this.maximumEvents,
    Set<String>? enabledComponents,
  }) : enabledComponents = enabledComponents == null
           ? null
           : Set<String>.unmodifiable(enabledComponents);

  final DiagnosticSeverity minimumSeverity;
  final int? maximumEvents;
  final Set<String>? enabledComponents;
  final List<DiagnosticEvent> events = <DiagnosticEvent>[];
  bool flushed = false;
  bool closed = false;

  @override
  bool isEnabled({
    required String component,
    required DiagnosticSeverity severity,
    required DiagnosticPayloadKind payloadKind,
  }) =>
      !closed &&
      severity.index >= minimumSeverity.index &&
      (enabledComponents == null || enabledComponents!.contains(component));

  @override
  bool add(DiagnosticEvent event) {
    if (closed || (maximumEvents != null && events.length >= maximumEvents!)) {
      return false;
    }
    events.add(event);
    return true;
  }

  @override
  Future<void> flush({required Duration timeout}) async {
    flushed = true;
  }

  @override
  Future<void> close({required Duration timeout}) async {
    flushed = true;
    closed = true;
  }
}

final class SequentialDiagnosticIdGenerator implements DiagnosticIdGenerator {
  var _next = 0;

  @override
  String nextId(String namespace) {
    _next += 1;
    return '${namespace}_${_next.toString().padLeft(24, '0')}';
  }
}

final class FixedDiagnosticClock implements DiagnosticClock {
  FixedDiagnosticClock({int initialMicros = 1700000000000000})
    : _micros = initialMicros;

  int _micros;

  @override
  DateTime nowUtc() {
    final value = DateTime.fromMicrosecondsSinceEpoch(_micros, isUtc: true);
    _micros += 1000;
    return value;
  }
}

final class DiagnosticsTestkit {
  DiagnosticsTestkit({
    DiagnosticSeverity minimumSeverity = DiagnosticSeverity.trace,
    int? maximumEvents,
  }) : sink = RecordingDiagnosticEventSink(
         minimumSeverity: minimumSeverity,
         maximumEvents: maximumEvents,
       ) {
    manager = DiagnosticsManager(
      sink: sink,
      registry: AppDiagnosticEvents.registry,
      source: DiagnosticSource.app,
      idGenerator: SequentialDiagnosticIdGenerator(),
      clock: FixedDiagnosticClock(),
      sourceRunId: 'run_000000000000000000000000',
    );
  }

  final RecordingDiagnosticEventSink sink;
  late final DiagnosticsManager manager;

  Future<void> dispose() => manager.close();
}
