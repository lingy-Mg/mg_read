import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/core/persistence/src/diagnostics_persistence.dart';

import 'diagnostics_testkit.dart';

void main() {
  test('deferred sink bounds events and preserves accepted order on attach', () async {
    final deferred = DeferredDiagnosticEventSink(minimumSeverity: DiagnosticSeverity.info, maxEvents: 2, maxBytes: 16 * 1024);
    final manager = DiagnosticsManager(
      sink: deferred,
      registry: AppDiagnosticEvents.registry,
      source: DiagnosticSource.app,
      idGenerator: SequentialDiagnosticIdGenerator(),
      clock: FixedDiagnosticClock(),
      sourceRunId: 'run_000000000000000000000000',
    );
    addTearDown(manager.close);

    for (var index = 0; index < 3; index += 1) {
      manager.emit(
        AppDiagnosticEvents.startupStage,
        attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
          'stage': DiagnosticValue.string('stage$index'),
          'durationMicros': DiagnosticValue.int64(index),
          'resultState': DiagnosticValue.string('ok'),
          'attempt': DiagnosticValue.int64(1),
        }),
      );
    }
    expect(deferred.bufferedEventCount, 2);
    expect(deferred.droppedEvents, 1);

    final recording = RecordingDiagnosticEventSink();
    await deferred.attach(recording);
    expect(recording.events.map((event) => (event.attributes.values['stage'] as DiagnosticStringValue).value), <String>[
      'stage0',
      'stage1',
    ]);
  });

  test('flush and close work before and after attach', () async {
    final deferred = DeferredDiagnosticEventSink();
    await deferred.flush(timeout: const Duration(seconds: 1));
    await deferred.close(timeout: const Duration(seconds: 1));
    expect(deferred.isClosed, isTrue);
    await deferred.attach(RecordingDiagnosticEventSink());
    expect(deferred.isAttached, isFalse);

    final attached = DeferredDiagnosticEventSink();
    final recording = RecordingDiagnosticEventSink();
    await attached.attach(recording);
    await attached.flush(timeout: const Duration(seconds: 1));
    await attached.close(timeout: const Duration(seconds: 1));
    expect(recording.closed, isTrue);
  });

  test('persistent open attaches an existing manager and keeps one run', () async {
    final root = await Directory.systemTemp.createTemp('mg-read-deferred-');
    addTearDown(() => root.delete(recursive: true));
    final deferred = DeferredDiagnosticEventSink(minimumSeverity: DiagnosticSeverity.trace, maxEvents: 32, maxBytes: 64 * 1024);
    final manager = DiagnosticsManager(
      sink: deferred,
      registry: AppDiagnosticEvents.registry,
      source: DiagnosticSource.app,
      idGenerator: SequentialDiagnosticIdGenerator(),
      clock: FixedDiagnosticClock(),
      sourceRunId: 'run_000000000000000000000001',
      buildMode: 'profile',
      platform: 'windows-test',
    );
    manager.emit(
      AppDiagnosticEvents.startupStage,
      attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
        'stage': DiagnosticValue.string('beforePersistence'),
        'durationMicros': DiagnosticValue.int64(10),
        'resultState': DiagnosticValue.string('ok'),
        'attempt': DiagnosticValue.int64(1),
      }),
    );

    final service = await AppDiagnosticsService.open(
      dataRoot: root,
      configuration: const PersistentDiagnosticsConfiguration(minimumSeverity: DiagnosticSeverity.trace),
      existingManager: manager,
      buildMode: 'debug-ignored',
      platform: 'ignored',
    );
    await service.close();
    final reopened = await DiagnosticsPersistence.open(dataRoot: root);
    addTearDown(reopened.close);
    final files = await reopened.listLogFiles();
    final events = await reopened.listLogEvents(files.single.fileId, limit: 20);
    expect(events.items.map((event) => event.sourceRunId).toSet(), {'run_000000000000000000000001'});
    expect(events.items.any((event) => event.eventName == 'app.startup.stage'), isTrue);
  });

  test('startup stage schema contains metadata only fields', () {
    final definition = AppDiagnosticEvents.startupStage;
    expect(definition.kind, DiagnosticDefinitionKind.instant);
    expect(definition.eventName(DiagnosticPhase.instant), 'app.startup.stage');
    expect(definition.fields.keys, containsAll(<String>['stage', 'durationMicros', 'resultState', 'errorCode', 'attempt']));
    expect(definition.fields.keys, isNot(contains('path')));
    expect(definition.fields.keys, isNot(contains('content')));
    final manager = DiagnosticsTestkit().manager;
    addTearDown(manager.close);
    expect(
      () => manager.emit(
        definition,
        attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
          'stage': DiagnosticValue.string('safe'),
          'durationMicros': DiagnosticValue.int64(1),
          'resultState': DiagnosticValue.string('ok'),
          'attempt': DiagnosticValue.int64(1),
          'path': DiagnosticValue.string('must-not-pass'),
        }),
      ),
      throwsA(isA<DiagnosticSchemaError>()),
    );
  });
}
