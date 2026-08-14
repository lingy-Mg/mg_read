import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/core/persistence/src/diagnostics_persistence.dart';

import 'diagnostics_testkit.dart';
import 'persistent_diagnostics_testkit.dart';

void main() {
  group('AppDiagnosticsService', () {
    late PersistentDiagnosticsTestkit kit;

    tearDown(() async => kit.dispose());

    test(
      'persists bounded events and queries them with stable cursors',
      () async {
        kit = await PersistentDiagnosticsTestkit.open();
        for (var index = 0; index < 5; index += 1) {
          kit.service.manager.emit(
            AppDiagnosticEvents.routeChanged,
            attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
              'toRoute': DiagnosticValue.string('route$index'),
            }),
          );
        }

        final firstPage = await kit.service.listEvents(
          filter: DiagnosticEventFilter(
            sessionId: kit.service.sourceRunId,
            eventNames: <String>{'app.route.changed'},
          ),
          limit: 2,
        );
        final secondPage = await kit.service.listEvents(
          filter: DiagnosticEventFilter(
            sessionId: kit.service.sourceRunId,
            eventNames: <String>{'app.route.changed'},
          ),
          cursor: firstPage.nextCursor,
          limit: 2,
        );

        expect(
          kit.service.writerStatistics.writerErrors,
          0,
          reason: kit.service.writerStatistics.lastWriterFailureType,
        );

        expect(firstPage.items, hasLength(2));
        expect(secondPage.items, hasLength(2));
        expect(
          firstPage.items
              .map((event) => event.eventId)
              .toSet()
              .intersection(
                secondPage.items.map((event) => event.eventId).toSet(),
              ),
          isEmpty,
        );
        expect(firstPage.nextCursor, isNotNull);
        expect(kit.service.writerStatistics.eventEncodingOffloaded, isTrue);
        expect(
          firstPage.items.every(
            (event) => event.captureSessionId == kit.service.sourceRunId,
          ),
          isTrue,
        );
      },
    );

    test(
      'keeps the caller bounded and reports queue drops after recovery',
      () async {
        kit = await PersistentDiagnosticsTestkit.open(
          configuration: const PersistentDiagnosticsConfiguration(
            minimumSeverity: DiagnosticSeverity.trace,
            maxQueueEvents: 8,
            maxQueueBytes: 16 * 1024,
            priorityReservedEvents: 2,
            priorityReservedBytes: 1024,
            batchSize: 128,
            maxBatchDelay: Duration(seconds: 10),
          ),
        );

        for (var index = 0; index < 50; index += 1) {
          kit.service.manager.emit(
            AppDiagnosticEvents.routeChanged,
            attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
              'toRoute': DiagnosticValue.string('route$index'),
            }),
          );
        }
        final beforeFlush = kit.service.writerStatistics;
        await kit.service.manager.flush(timeout: const Duration(seconds: 2));
        final afterFlush = kit.service.writerStatistics;

        expect(beforeFlush.queueDepth, lessThanOrEqualTo(8));
        expect(beforeFlush.queueBytes, lessThanOrEqualTo(16 * 1024));
        expect(afterFlush.droppedEvents, greaterThan(0));
        expect(afterFlush.committedEvents, greaterThan(0));
        final dropped = await kit.service.listEvents(
          filter: DiagnosticEventFilter(
            eventNames: <String>{'diagnostics.events.dropped'},
          ),
        );
        expect(dropped.items, hasLength(1));
      },
    );

    test('streams large content into a separate truncated object', () async {
      kit = await PersistentDiagnosticsTestkit.open(
        configuration: const PersistentDiagnosticsConfiguration(
          minimumSeverity: DiagnosticSeverity.trace,
          retentionPolicy: DiagnosticRetentionPolicy(
            singleAttachmentBytes: 128 * 1024,
          ),
        ),
      );
      await kit.service.startCapture(
        DiagnosticCapturePolicy(
          payloadKind: DiagnosticPayloadKind.contentPayload,
          duration: const Duration(minutes: 5),
          maxStoredBytes: 512 * 1024,
          components: <String>{'app.router'},
        ),
      );
      final emitted = kit.service.manager.emit(
        AppDiagnosticEvents.routeChanged,
        attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
          'toRoute': DiagnosticValue.string('library'),
        }),
      );
      final payload = List<int>.generate(
        500 * 1024,
        (index) => index % 251,
        growable: false,
      );

      final descriptor = await kit.service.captureAttachment(
        eventId: emitted.event!.eventId,
        kind: 'http.response.body',
        mediaType: 'application/octet-stream',
        formatId: 'raw-bytes',
        formatVersion: 1,
        privacyClass: DiagnosticPrivacyClass.content,
        bytes: Stream<List<int>>.fromIterable(<List<int>>[
          payload.sublist(0, 200 * 1024),
          payload.sublist(200 * 1024),
        ]),
      );
      final rangeBytes = await kit.service
          .openAttachment(
            descriptor.attachmentId,
            range: DiagnosticByteRange(offset: 1024, length: 4096),
          )
          .expand((chunk) => chunk)
          .toList();

      expect(descriptor.captureState, DiagnosticCaptureState.truncated);
      expect(descriptor.rawByteLength, 500 * 1024);
      expect(descriptor.storedByteLength, 128 * 1024);
      expect(descriptor.sha256, matches(RegExp(r'^[a-f0-9]{64}$')));
      expect(rangeBytes, payload.sublist(1024, 1024 + 4096));
      final databaseText = utf8.decode(
        await File(
          '${kit.root.path}${Platform.pathSeparator}diagnostics'
          '${Platform.pathSeparator}index.sqlite',
        ).readAsBytes(),
        allowMalformed: true,
      );
      expect(
        databaseText,
        isNot(contains(base64Encode(payload.sublist(0, 64)))),
      );
    });

    test(
      'records policy-blocked payload without consuming its stream',
      () async {
        kit = await PersistentDiagnosticsTestkit.open();
        final emitted = kit.service.manager.emit(
          AppDiagnosticEvents.routeChanged,
          attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
            'toRoute': DiagnosticValue.string('library'),
          }),
        );
        var listened = false;
        final bytes = Stream<List<int>>.multi((controller) {
          listened = true;
          controller.add(<int>[1, 2, 3]);
          controller.close();
        });

        final descriptor = await kit.service.captureAttachment(
          eventId: emitted.event!.eventId,
          kind: 'http.response.body',
          mediaType: 'text/plain',
          formatId: 'raw-bytes',
          formatVersion: 1,
          privacyClass: DiagnosticPrivacyClass.content,
          bytes: bytes,
        );

        expect(descriptor.captureState, DiagnosticCaptureState.policyBlocked);
        expect(descriptor.truncationReason, 'explicitCaptureRequired');
        expect(listened, isFalse);
        await expectLater(
          kit.service.openAttachment(descriptor.attachmentId).drain<void>(),
          throwsA(isA<StateError>()),
        );
      },
    );

    test('secret canary never reaches SQLite, WAL, or object files', () async {
      final canaryDefinition = DiagnosticEventDefinition.instant(
        name: 'test.secret.canary',
        component: 'test.security',
        summary: 'Secret canary event.',
        fields: <String, DiagnosticFieldDefinition>{
          'credential': const DiagnosticFieldDefinition(
            type: DiagnosticFieldType.string,
            privacyClass: DiagnosticPrivacyClass.secret,
            requiredFor: <DiagnosticPhase>{DiagnosticPhase.instant},
          ),
        },
      );
      final registry = DiagnosticEventRegistry(<DiagnosticEventDefinition>[
        ...AppDiagnosticEvents.registry.definitions,
        canaryDefinition,
      ]);
      kit = await PersistentDiagnosticsTestkit.open(registry: registry);
      kit.service.manager.emit(
        canaryDefinition,
        attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
          'credential': DiagnosticValue.string(_secretCanary),
        }),
      );
      await kit.service.manager.flush(timeout: const Duration(seconds: 2));

      final events = await kit.service.listEvents(
        filter: DiagnosticEventFilter(
          eventNames: <String>{canaryDefinition.name},
        ),
      );
      expect(
        events.items.single.attributes.values['credential'],
        isA<DiagnosticRedactedValue>(),
      );
      await for (final entity in kit.root.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        final text = utf8.decode(
          await entity.readAsBytes(),
          allowMalformed: true,
        );
        expect(text, isNot(contains(_secretCanary)), reason: entity.path);
      }
    });

    test(
      'deletes a stopped capture and reclaims its unleased object',
      () async {
        kit = await PersistentDiagnosticsTestkit.open();
        final capture = await kit.service.startCapture(
          DiagnosticCapturePolicy(
            payloadKind: DiagnosticPayloadKind.contentPayload,
            duration: const Duration(minutes: 5),
            maxStoredBytes: 64 * 1024,
            components: <String>{'app.router'},
          ),
        );
        final emitted = kit.service.manager.emit(
          AppDiagnosticEvents.routeChanged,
          attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
            'toRoute': DiagnosticValue.string('library'),
          }),
        );
        final descriptor = await kit.service.captureAttachment(
          eventId: emitted.event!.eventId,
          kind: 'http.response.body',
          mediaType: 'text/plain',
          formatId: 'raw-bytes',
          formatVersion: 1,
          privacyClass: DiagnosticPrivacyClass.content,
          bytes: Stream<List<int>>.value(utf8.encode('captured payload')),
        );
        await kit.service.stopCapture(capture.sessionId);

        await kit.service.deleteSession(capture.sessionId);

        expect(await kit.service.getEvent(emitted.event!.eventId), isNull);
        expect((await kit.service.getStatistics()).objectCount, 0);
        await expectLater(
          kit.service.openAttachment(descriptor.attachmentId).drain<void>(),
          throwsA(isA<StateError>()),
        );
      },
    );

    test(
      'enforces origin allowlists when assigning capture sessions',
      () async {
        final originDefinition = DiagnosticEventDefinition.instant(
          name: 'test.http.origin',
          component: 'test.http',
          summary: 'Projected HTTP origin.',
          fields: <String, DiagnosticFieldDefinition>{
            'origin': const DiagnosticFieldDefinition(
              type: DiagnosticFieldType.string,
              privacyClass: DiagnosticPrivacyClass.public,
              requiredFor: <DiagnosticPhase>{DiagnosticPhase.instant},
            ),
          },
        );
        kit = await PersistentDiagnosticsTestkit.open(
          registry: DiagnosticEventRegistry(<DiagnosticEventDefinition>[
            ...AppDiagnosticEvents.registry.definitions,
            originDefinition,
          ]),
        );
        final capture = await kit.service.startCapture(
          DiagnosticCapturePolicy(
            payloadKind: DiagnosticPayloadKind.contentPayload,
            duration: const Duration(minutes: 5),
            maxStoredBytes: 64 * 1024,
            origins: <String>{'https://allowed.example'},
          ),
        );

        DiagnosticEmitResult emit(String origin) => kit.service.manager.emit(
          originDefinition,
          privacyContext: const DiagnosticPrivacyContext(
            payloadKind: DiagnosticPayloadKind.contentPayload,
          ),
          attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
            'origin': DiagnosticValue.string(origin),
          }),
        );

        final allowed = emit('https://allowed.example');
        final blocked = emit('https://blocked.example');
        await kit.service.manager.flush(timeout: const Duration(seconds: 2));

        final storedAllowed = await kit.service.getEvent(
          allowed.event!.eventId,
        );
        final storedBlocked = await kit.service.getEvent(
          blocked.event!.eventId,
        );
        expect(storedAllowed!.captureSessionId, capture.sessionId);
        expect(storedBlocked!.captureSessionId, kit.service.sourceRunId);
      },
    );

    test(
      'keeps stopped captures for capture retention instead of duration',
      () async {
        final clock = MutableDiagnosticClock(DateTime.utc(2026, 8, 14));
        kit = await PersistentDiagnosticsTestkit.open(clock: clock);
        final capture = await kit.service.startCapture(
          DiagnosticCapturePolicy(
            payloadKind: DiagnosticPayloadKind.contentPayload,
            duration: const Duration(minutes: 5),
            maxStoredBytes: 64 * 1024,
            components: <String>{'app.router'},
          ),
        );
        await kit.service.stopCapture(capture.sessionId);

        clock.advance(const Duration(hours: 1));
        await kit.service.enforceRetention(
          const DiagnosticRetentionPolicy(captureAge: Duration(hours: 24)),
        );
        var sessions = await kit.service.listSessions();
        expect(
          sessions.items.any((item) => item.sessionId == capture.sessionId),
          isTrue,
        );

        clock.advance(const Duration(hours: 24));
        await kit.service.enforceRetention(
          const DiagnosticRetentionPolicy(captureAge: Duration(hours: 24)),
        );
        sessions = await kit.service.listSessions();
        expect(
          sessions.items.any((item) => item.sessionId == capture.sessionId),
          isFalse,
        );
      },
    );

    test(
      'caps explicit capture bytes and rejects oversized policies',
      () async {
        kit = await PersistentDiagnosticsTestkit.open(
          configuration: const PersistentDiagnosticsConfiguration(
            minimumSeverity: DiagnosticSeverity.trace,
            retentionPolicy: DiagnosticRetentionPolicy(
              captureBytes: 32 * 1024,
              globalHardBytes: 64 * 1024,
              singleAttachmentBytes: 16 * 1024,
            ),
          ),
        );
        await expectLater(
          kit.service.startCapture(
            DiagnosticCapturePolicy(
              payloadKind: DiagnosticPayloadKind.contentPayload,
              duration: const Duration(minutes: 5),
              maxStoredBytes: 33 * 1024,
              components: <String>{'app.router'},
            ),
          ),
          throwsRangeError,
        );
        final capture = await kit.service.startCapture(
          DiagnosticCapturePolicy(
            payloadKind: DiagnosticPayloadKind.contentPayload,
            duration: const Duration(minutes: 5),
            maxStoredBytes: 20 * 1024,
            components: <String>{'app.router'},
          ),
        );
        final emitted = kit.service.manager.emit(
          AppDiagnosticEvents.routeChanged,
          attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
            'toRoute': DiagnosticValue.string('library'),
          }),
        );
        final descriptor = await kit.service.captureAttachment(
          eventId: emitted.event!.eventId,
          kind: 'http.response.body',
          mediaType: 'application/octet-stream',
          formatId: 'raw-bytes',
          formatVersion: 1,
          privacyClass: DiagnosticPrivacyClass.content,
          bytes: Stream<List<int>>.value(List<int>.filled(64 * 1024, 7)),
        );
        final sessions = await kit.service.listSessions();
        final stored = sessions.items.singleWhere(
          (item) => item.sessionId == capture.sessionId,
        );

        expect(descriptor.captureState, DiagnosticCaptureState.truncated);
        expect(descriptor.storedByteLength, lessThanOrEqualTo(16 * 1024));
        expect(stored.storedBytes, lessThanOrEqualTo(20 * 1024));
      },
    );

    test(
      'serializes concurrent attachments so session quota cannot race',
      () async {
        kit = await PersistentDiagnosticsTestkit.open(
          configuration: const PersistentDiagnosticsConfiguration(
            minimumSeverity: DiagnosticSeverity.trace,
            retentionPolicy: DiagnosticRetentionPolicy(
              captureBytes: 32 * 1024,
              globalHardBytes: 64 * 1024,
              singleAttachmentBytes: 16 * 1024,
            ),
          ),
        );
        final capture = await kit.service.startCapture(
          DiagnosticCapturePolicy(
            payloadKind: DiagnosticPayloadKind.contentPayload,
            duration: const Duration(minutes: 5),
            maxStoredBytes: 24 * 1024,
            components: <String>{'app.router'},
          ),
        );
        final emitted = kit.service.manager.emit(
          AppDiagnosticEvents.routeChanged,
          attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
            'toRoute': DiagnosticValue.string('library'),
          }),
        );

        final descriptors = await Future.wait(
          List<Future<DiagnosticAttachmentDescriptor>>.generate(
            2,
            (index) => kit.service.captureAttachment(
              eventId: emitted.event!.eventId,
              kind: 'http.response.part$index',
              mediaType: 'application/octet-stream',
              formatId: 'raw-bytes',
              formatVersion: 1,
              privacyClass: DiagnosticPrivacyClass.content,
              bytes: Stream<List<int>>.value(
                List<int>.filled(16 * 1024, index),
              ),
            ),
          ),
        );
        final sessions = await kit.service.listSessions();
        final stored = sessions.items.singleWhere(
          (item) => item.sessionId == capture.sessionId,
        );

        expect(
          descriptors.fold<int>(0, (sum, item) => sum + item.storedByteLength),
          lessThan(24 * 1024),
        );
        expect(stored.storedBytes, lessThanOrEqualTo(24 * 1024));
      },
    );

    test('bounds a stalled attachment stream with a write deadline', () async {
      kit = await PersistentDiagnosticsTestkit.open(
        configuration: const PersistentDiagnosticsConfiguration(
          minimumSeverity: DiagnosticSeverity.trace,
          attachmentWriteTimeout: Duration(milliseconds: 30),
        ),
      );
      await kit.service.startCapture(
        DiagnosticCapturePolicy(
          payloadKind: DiagnosticPayloadKind.contentPayload,
          duration: const Duration(minutes: 5),
          maxStoredBytes: 64 * 1024,
          components: <String>{'app.router'},
        ),
      );
      final emitted = kit.service.manager.emit(
        AppDiagnosticEvents.routeChanged,
        attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
          'toRoute': DiagnosticValue.string('library'),
        }),
      );
      var cancelled = false;
      final controller = StreamController<List<int>>(
        onCancel: () => cancelled = true,
      );
      addTearDown(controller.close);

      final descriptor = await kit.service.captureAttachment(
        eventId: emitted.event!.eventId,
        kind: 'http.response.body',
        mediaType: 'application/octet-stream',
        formatId: 'raw-bytes',
        formatVersion: 1,
        privacyClass: DiagnosticPrivacyClass.content,
        bytes: controller.stream,
      );

      expect(descriptor.captureState, DiagnosticCaptureState.truncated);
      expect(descriptor.truncationReason, 'attachmentWriteDeadline');
      expect(cancelled, isTrue);
    });

    test('defers object deletion while a range reader holds a lease', () async {
      kit = await PersistentDiagnosticsTestkit.open();
      final capture = await kit.service.startCapture(
        DiagnosticCapturePolicy(
          payloadKind: DiagnosticPayloadKind.contentPayload,
          duration: const Duration(minutes: 5),
          maxStoredBytes: 256 * 1024,
          components: <String>{'app.router'},
        ),
      );
      final emitted = kit.service.manager.emit(
        AppDiagnosticEvents.routeChanged,
        attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
          'toRoute': DiagnosticValue.string('library'),
        }),
      );
      final descriptor = await kit.service.captureAttachment(
        eventId: emitted.event!.eventId,
        kind: 'http.response.body',
        mediaType: 'application/octet-stream',
        formatId: 'raw-bytes',
        formatVersion: 1,
        privacyClass: DiagnosticPrivacyClass.content,
        bytes: Stream<List<int>>.value(List<int>.filled(128 * 1024, 11)),
      );
      await kit.service.stopCapture(capture.sessionId);
      final firstChunk = Completer<void>();
      late StreamSubscription<List<int>> subscription;
      subscription = kit.service.openAttachment(descriptor.attachmentId).listen(
        (_) {
          if (!firstChunk.isCompleted) {
            subscription.pause();
            firstChunk.complete();
          }
        },
      );
      await firstChunk.future;

      await kit.service.deleteSession(capture.sessionId);
      expect((await kit.service.getStatistics()).objectCount, 1);

      subscription.resume();
      await subscription.asFuture<void>();
      await kit.service.enforceRetention(const DiagnosticRetentionPolicy());
      expect((await kit.service.getStatistics()).objectCount, 0);
    });
  });

  test(
    'startup retention trims ended regular sessions by byte budget',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'mg-read-diagnostics-retention-',
      );
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      const configuration = PersistentDiagnosticsConfiguration(
        minimumSeverity: DiagnosticSeverity.trace,
        retentionPolicy: DiagnosticRetentionPolicy(regularEventBytes: 8 * 1024),
      );
      final first = await AppDiagnosticsService.open(
        dataRoot: root,
        configuration: configuration,
        idGenerator: SequentialDiagnosticIdGenerator(),
        clock: FixedDiagnosticClock(),
        buildMode: 'test',
        platform: 'windows-test',
      );
      for (var index = 0; index < 100; index += 1) {
        first.manager.emit(
          AppDiagnosticEvents.routeChanged,
          attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
            'toRoute': DiagnosticValue.string('route$index'),
          }),
        );
      }
      await first.manager.flush(timeout: const Duration(seconds: 5));
      expect(
        (await first.getStatistics()).logicalStoredBytes,
        greaterThan(8 * 1024),
      );
      await first.close();

      final second = await AppDiagnosticsService.open(
        dataRoot: root,
        configuration: configuration,
        idGenerator: SequentialDiagnosticIdGenerator(initialValue: 100000),
        clock: FixedDiagnosticClock(initialMicros: 1800000000000000),
        buildMode: 'test',
        platform: 'windows-test',
      );
      addTearDown(second.close);
      final sessions = await second.listSessions();

      expect(sessions.items, hasLength(1));
      expect(sessions.items.single.sourceRunId, second.sourceRunId);
    },
  );

  test(
    'startup recovery ends interrupted runs and removes staging files',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'mg-read-diagnostics-recovery-',
      );
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final first = await DiagnosticsPersistence.open(dataRoot: root);
      const runId = 'run_000000000000000000000099';
      await first.beginRun(
        sourceRunId: runId,
        source: DiagnosticSource.app,
        regularSessionMaxBytes: 1024,
        regularSessionAge: const Duration(days: 3),
      );
      final staging = File(
        '${root.path}${Platform.pathSeparator}diagnostics'
        '${Platform.pathSeparator}staging${Platform.pathSeparator}orphan.part',
      );
      await staging.writeAsString('partial');
      await first.close();

      final reopened = await DiagnosticsPersistence.open(dataRoot: root);
      addTearDown(reopened.close);
      final sessions = await reopened.listSessions();

      expect(sessions.items.single.sessionId, runId);
      expect(sessions.items.single.state, DiagnosticSessionState.ended);
      expect(await staging.exists(), isFalse);
    },
  );
}

const String _secretCanary = 'MGREAD_SECRET_CANARY_7f62c7ad';
