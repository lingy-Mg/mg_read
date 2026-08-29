import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/diagnostics/diagnostics.dart';

import 'diagnostics_testkit.dart';

void main() {
  group('DiagnosticsManager', () {
    late DiagnosticsTestkit kit;

    setUp(() => kit = DiagnosticsTestkit());
    tearDown(() => kit.dispose());

    test('emits one start and exactly one terminal event for an owner span', () {
      final span = kit.manager.startSpan(
        AppDiagnosticEvents.bootstrap,
        attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{'stage': DiagnosticValue.string('settings')}),
      );
      final result = span.complete(
        attributes: DiagnosticObjectValue(<String, DiagnosticValue>{'stage': DiagnosticValue.string('mounted')}),
      );

      expect(result.accepted, isTrue);
      expect(kit.sink.events, hasLength(2));
      expect(kit.sink.events.first.eventName, 'app.bootstrap.start');
      expect(kit.sink.events.last.eventName, 'app.bootstrap.complete');
      expect(kit.sink.events.last.outcome, DiagnosticOutcome.success);
      expect(kit.sink.events.last.durationMicros, isNonNegative);
      expect(kit.sink.events.last.traceId, kit.sink.events.first.traceId);
      expect(kit.sink.events.last.spanId, kit.sink.events.first.spanId);
      expect(() => span.complete(), throwsA(isA<StateError>()));
    });

    test('closes unfinished spans as incomplete before closing the sink', () async {
      kit.manager.startSpan(AppDiagnosticEvents.bootstrap);

      await kit.manager.close();

      expect(kit.sink.events.last.outcome, DiagnosticOutcome.incomplete);
      expect(kit.sink.events.last.flags, contains(DiagnosticEventFlag.incomplete));
      expect(kit.sink.closed, isTrue);
    });

    test('propagates trace context through nested asynchronous spans', () async {
      await kit.manager.runSpan<void>(
        AppDiagnosticEvents.bootstrap,
        (_) => kit.manager.runSpan<void>(AppDiagnosticEvents.settingsInitialize, (_) async {}),
      );

      final parent = kit.sink.events.firstWhere((event) => event.eventName == 'app.bootstrap.start');
      final child = kit.sink.events.firstWhere((event) => event.eventName == 'settings.initialize.start');
      expect(child.traceId, parent.traceId);
      expect(child.parentSpanId, parent.spanId);
      expect(child.spanId, isNot(parent.spanId));
    });

    test('does not evaluate attributes when filtered', () {
      final filteredKit = DiagnosticsTestkit(minimumSeverity: DiagnosticSeverity.error);
      addTearDown(filteredKit.dispose);
      var evaluated = false;

      final result = filteredKit.manager.emit(
        AppDiagnosticEvents.routeChanged,
        attributes: () {
          evaluated = true;
          return DiagnosticObjectValue(<String, DiagnosticValue>{'toRoute': DiagnosticValue.string('library')});
        },
      );

      expect(result.accepted, isFalse);
      expect(evaluated, isFalse);
      expect(filteredKit.sink.events, isEmpty);
    });

    test('rejects unregistered and undeclared event fields', () {
      final unknownDefinition = DiagnosticEventDefinition.instant(
        name: 'feature.unknown',
        component: 'feature.unknown',
        summary: 'Unknown event.',
      );

      expect(() => kit.manager.emit(unknownDefinition), throwsA(isA<DiagnosticSchemaError>()));
      expect(
        () => kit.manager.emit(
          AppDiagnosticEvents.routeChanged,
          attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
            'toRoute': DiagnosticValue.string('library'),
            'rawInput': DiagnosticValue.string('must not pass'),
          }),
        ),
        throwsA(isA<DiagnosticSchemaError>()),
      );
    });

    test('retains unknown future envelope fields as read-only data', () {
      kit.manager.emit(
        AppDiagnosticEvents.routeChanged,
        attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{'toRoute': DiagnosticValue.string('library')}),
      );
      const codec = DiagnosticEventCodec();
      final wire = codec.encode(kit.sink.events.single);
      wire['envelopeVersion'] = currentDiagnosticEnvelopeVersion + 1;
      wire['futureProjection'] = 'retained';

      final decoded = codec.decode(wire);

      expect(decoded.isFutureEnvelope, isTrue);
      expect(decoded.extensionFields['futureProjection'], 'retained');
      expect(codec.encode(decoded)['futureProjection'], 'retained');
    });

    test('isolates sink admission, flush, and close failures', () async {
      final manager = DiagnosticsManager(
        sink: const _ThrowingDiagnosticEventSink(),
        registry: AppDiagnosticEvents.registry,
        source: DiagnosticSource.app,
        idGenerator: SequentialDiagnosticIdGenerator(),
        clock: FixedDiagnosticClock(),
        sourceRunId: 'run_000000000000000000000999',
      );

      final result = manager.emit(
        AppDiagnosticEvents.routeChanged,
        attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{'toRoute': DiagnosticValue.string('library')}),
      );

      expect(result.accepted, isFalse);
      await expectLater(manager.flush(), completes);
      final firstClose = manager.close();
      final secondClose = manager.close();
      expect(identical(firstClose, secondClose), isTrue);
      await expectLater(firstClose, completes);
    });
  });

  group('Diagnostic contracts', () {
    test('capture policy requires an explicit payload allowlist', () {
      expect(
        () => DiagnosticCapturePolicy(
          payloadKind: DiagnosticPayloadKind.contentPayload,
          duration: const Duration(minutes: 10),
          maxStoredBytes: 1024,
        ),
        throwsArgumentError,
      );
    });

    test('registry rejects duplicate emitted names', () {
      final first = DiagnosticEventDefinition.instant(name: 'test.event', component: 'test.component', summary: 'First.');
      final second = DiagnosticEventDefinition.instant(name: 'test.event', component: 'test.component', summary: 'Second.');

      expect(() => DiagnosticEventRegistry(<DiagnosticEventDefinition>[first, second]), throwsA(isA<DiagnosticSchemaError>()));
    });

    test('reader chapter performance schema is a bounded owner span', () {
      final DiagnosticsTestkit kit = DiagnosticsTestkit();
      addTearDown(kit.dispose);
      final span = kit.manager.startSpan(
        AppDiagnosticEvents.readerChapterPerformance,
        attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
          'phase': DiagnosticValue.string('adjacentPreparation'),
          'preparationKind': DiagnosticValue.string('adjacentIdle'),
          'cacheHit': DiagnosticValue.boolean(false),
          'operationId': DiagnosticValue.int64(3),
        }),
      );
      span.complete(
        attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
          'phase': DiagnosticValue.string('adjacentPreparation'),
          'preparationKind': DiagnosticValue.string('adjacentIdle'),
          'cacheHit': DiagnosticValue.boolean(false),
          'operationId': DiagnosticValue.int64(3),
          'pageCount': DiagnosticValue.int64(2),
          'paragraphCount': DiagnosticValue.int64(8),
          'durationMicros': DiagnosticValue.int64(1200),
        }),
      );
      expect(kit.sink.events.map((event) => event.eventName), <String>[
        'reader.chapter.performance.start',
        'reader.chapter.performance.complete',
      ]);
      expect(kit.sink.events.last.attributes.values.keys, containsAll(<String>['phase', 'durationMicros']));
    });
  });
}

final class _ThrowingDiagnosticEventSink implements DiagnosticEventSink {
  const _ThrowingDiagnosticEventSink();

  @override
  bool isEnabled({required String component, required DiagnosticSeverity severity, required DiagnosticPayloadKind payloadKind}) => true;

  @override
  bool add(DiagnosticEvent event) => throw StateError('writer unavailable');

  @override
  Future<void> flush({required Duration timeout}) => Future<void>.error(StateError('writer unavailable'));

  @override
  Future<void> close({required Duration timeout}) => Future<void>.error(StateError('writer unavailable'));
}
