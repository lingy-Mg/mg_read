import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/diagnostics/diagnostics.dart';

void main() {
  const formatter = DiagnosticConsoleFormatter();

  test('suppresses low-level debug spans from the developer console', () {
    final event = _event(
      severity: DiagnosticSeverity.debug,
      eventName: 'persistence.operation.start',
      component: 'app.persistence',
      phase: DiagnosticPhase.start,
    );

    expect(formatter.shouldMirror(event), isFalse);
  });

  test('formats slow operations as compact readable summaries', () {
    final event = _event(
      severity: DiagnosticSeverity.warn,
      eventName: 'performance.slow',
      component: 'app.performance',
      attributes: <String, DiagnosticValue>{
        'durationMicros': DiagnosticValue.int64(10012786),
        'thresholdMicros': DiagnosticValue.int64(50000),
        'operation': DiagnosticValue.string('list'),
        'subjectComponent': DiagnosticValue.string('app.persistence'),
        'outcome': DiagnosticValue.string('success'),
      },
    );

    expect(formatter.shouldMirror(event), isTrue);
    expect(
      formatter.format(event),
      allOf(
        contains('[WARN] performance.slow'),
        contains('duration=10.013s'),
        contains('threshold=50.0ms'),
        contains('operation=list'),
        contains('component=app.persistence'),
        isNot(contains('event_000000000000000000000001')),
      ),
    );
  });

  test('adds status colors only to developer-console output', () {
    final cases = <({DiagnosticEvent event, String color})>[
      (event: _event(eventName: 'app.bootstrap.start', component: 'app.bootstrap', phase: DiagnosticPhase.start), color: '\x1B[96m'),
      (
        event: _event(
          eventName: 'app.bootstrap.complete',
          component: 'app.bootstrap',
          phase: DiagnosticPhase.terminal,
          outcome: DiagnosticOutcome.success,
        ),
        color: '\x1B[92m',
      ),
      (event: _event(severity: DiagnosticSeverity.warn, eventName: 'performance.slow', component: 'app.performance'), color: '\x1B[93m'),
      (event: _event(severity: DiagnosticSeverity.error, eventName: 'runtime.failed', component: 'app.runtime'), color: '\x1B[91m'),
      (
        event: _event(
          eventName: 'runtime.cancelled',
          component: 'app.runtime',
          phase: DiagnosticPhase.terminal,
          outcome: DiagnosticOutcome.cancelled,
        ),
        color: '\x1B[95m',
      ),
    ];

    for (final entry in cases) {
      final plain = formatter.format(entry.event);
      expect(plain, isNot(contains('\x1B[')));
      expect(formatter.formatForConsole(entry.event), '${entry.color}$plain\x1B[0m');
    }
  });

  test('keeps reader stage completion visible without opaque envelope data', () {
    final event = _event(
      eventName: 'reader.launch.stage.complete',
      component: 'feature.reader',
      phase: DiagnosticPhase.terminal,
      outcome: DiagnosticOutcome.success,
      durationMicros: 13769240,
      attributes: <String, DiagnosticValue>{
        'stage': DiagnosticValue.string('requestBuild'),
        'resultState': DiagnosticValue.string('success'),
      },
    );

    expect(formatter.shouldMirror(event), isTrue);
    expect(
      formatter.format(event),
      allOf(
        contains('[OK] reader.launch.stage.complete'),
        contains('duration=13.769s'),
        contains('stage=requestBuild'),
        contains('resultState=success'),
        isNot(contains('trace_')),
      ),
    );
  });

  test('preserves complete error text and stack traces for the developer console', () {
    const errorText = 'StateError: the complete refresh failure context must remain visible in the console';
    const stackTrace = '#0 refresh (library_book_refresh_operation.dart:42)\n#1 callback (library_page.dart:166)';
    final event = _event(
      severity: DiagnosticSeverity.error,
      eventName: 'library.operation.error',
      component: 'core.content-library',
      phase: DiagnosticPhase.terminal,
      outcome: DiagnosticOutcome.error,
      attributes: <String, DiagnosticValue>{
        'operation': DiagnosticValue.string('bookshelfRefresh'),
        'errorCode': DiagnosticValue.string('refresh_failed'),
        'errorText': DiagnosticValue.string(errorText),
        'stackTrace': DiagnosticValue.string(stackTrace),
      },
    );

    expect(formatter.format(event), contains(errorText));
    expect(formatter.format(event), contains(stackTrace));
  });
}

DiagnosticEvent _event({
  DiagnosticSeverity severity = DiagnosticSeverity.info,
  required String eventName,
  required String component,
  DiagnosticPhase phase = DiagnosticPhase.instant,
  DiagnosticOutcome? outcome,
  int? durationMicros,
  Map<String, DiagnosticValue> attributes = const <String, DiagnosticValue>{},
}) => DiagnosticEvent(
  eventId: 'event_000000000000000000000001',
  source: DiagnosticSource.app,
  component: component,
  sourceRunId: 'run_000000000000000000000001',
  sourceSequence: 1,
  occurredAtUtcMicros: DateTime.utc(2026, 8, 23, 12).microsecondsSinceEpoch,
  monotonicOffsetMicros: 1,
  severity: severity,
  eventName: eventName,
  eventSchemaVersion: 1,
  phase: phase,
  outcome: outcome,
  durationMicros: durationMicros,
  summary: 'Test diagnostic event.',
  attributes: DiagnosticObjectValue(attributes),
);
