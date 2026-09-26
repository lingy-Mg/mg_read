import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/core/diagnostics/diagnostics.dart';

void main() {
  test('normal mode never evaluates ordinary event fields and retains errors', () async {
    final buffer = LiveDiagnosticsBuffer();
    final manager = DiagnosticsManager(sink: buffer, registry: AppDiagnosticEvents.registry, source: DiagnosticSource.app);
    addTearDown(manager.close);
    var evaluated = false;
    manager.emit(
      AppDiagnosticEvents.routeChanged,
      attributes: () {
        evaluated = true;
        throw StateError('filtered attributes must not be evaluated');
      },
    );
    expect(evaluated, isFalse);
    manager.emit(
      AppDiagnosticEvents.unhandledError,
      attributes: () =>
          DiagnosticObjectValue({'boundary': DiagnosticValue.string('test'), 'errorCode': DiagnosticValue.string('sample_error')}),
    );
    final span = manager.startSpan(AppDiagnosticEvents.bootstrap);
    span.fail(attributes: DiagnosticObjectValue({'stage': DiagnosticValue.string('failed')}));
    expect(buffer.snapshot().map((event) => event.severity), everyElement(DiagnosticSeverity.error));
    expect(buffer.eventCount, 2);
    buffer.setDetailedRecording(true);
    manager.startSpan(AppDiagnosticEvents.bootstrap).complete();
    expect(buffer.eventCount, greaterThan(2));
    buffer.setDetailedRecording(false);
    expect(buffer.eventCount, 2);
    expect(buffer.storedBytes, greaterThan(0));
  });

  test('retains recent metadata events and exposes original fields', () async {
    final buffer = LiveDiagnosticsBuffer(maxEvents: 2, maxBytes: 64 * 1024)..setDetailedRecording(true);
    final manager = DiagnosticsManager(sink: buffer, registry: AppDiagnosticEvents.registry, source: DiagnosticSource.app);
    addTearDown(manager.close);

    for (final route in <String>['library', 'discover', 'profile']) {
      manager.emit(
        AppDiagnosticEvents.routeChanged,
        attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
          'fromRoute': DiagnosticValue.nullValue,
          'toRoute': DiagnosticValue.string(route),
          'navigationType': DiagnosticValue.string('test'),
        }),
      );
    }

    final events = buffer.snapshot();
    expect(events, hasLength(2));
    expect(events.first.attributes.values['toRoute']?.toWireValue(), <String, Object?>{'type': 'string', 'value': 'profile'});
    expect(events.last.attributes.values['toRoute']?.toWireValue(), <String, Object?>{'type': 'string', 'value': 'discover'});
    expect(buffer.droppedEvents, 1);
    expect(buffer.storedBytes, greaterThan(0));
  });

  test('notifies viewers when a new event is accepted', () async {
    final buffer = LiveDiagnosticsBuffer()..setDetailedRecording(true);
    final manager = DiagnosticsManager(sink: buffer, registry: AppDiagnosticEvents.registry, source: DiagnosticSource.app);
    addTearDown(manager.close);
    final changed = expectLater(buffer.changes, emits(isNull));

    manager.emit(
      AppDiagnosticEvents.routeChanged,
      attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
        'fromRoute': DiagnosticValue.nullValue,
        'toRoute': DiagnosticValue.string('profile.diagnostics'),
        'navigationType': DiagnosticValue.string('test'),
      }),
    );

    await changed;
  });
}
