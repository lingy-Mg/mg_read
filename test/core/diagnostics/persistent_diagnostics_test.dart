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

    test('persists bounded events and queries them with stable cursors', () async {
      kit = await PersistentDiagnosticsTestkit.open();
      for (var index = 0; index < 5; index += 1) {
        kit.service.manager.emit(
          AppDiagnosticEvents.routeChanged,
          attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{'toRoute': DiagnosticValue.string('route$index')}),
        );
      }

      final firstPage = await kit.service.listEvents(
        filter: DiagnosticEventFilter(sessionId: kit.service.sourceRunId, eventNames: <String>{'app.route.changed'}),
        limit: 2,
      );
      final secondPage = await kit.service.listEvents(
        filter: DiagnosticEventFilter(sessionId: kit.service.sourceRunId, eventNames: <String>{'app.route.changed'}),
        cursor: firstPage.nextCursor,
        limit: 2,
      );

      expect(kit.service.writerStatistics.writerErrors, 0, reason: kit.service.writerStatistics.lastWriterFailureType);

      expect(firstPage.items, hasLength(2));
      expect(secondPage.items, hasLength(2));
      expect(
        firstPage.items.map((event) => event.eventId).toSet().intersection(secondPage.items.map((event) => event.eventId).toSet()),
        isEmpty,
      );
      expect(firstPage.nextCursor, isNotNull);
      expect(kit.service.writerStatistics.eventEncodingOffloaded, isTrue);
      expect(firstPage.items.every((event) => event.captureSessionId == kit.service.sourceRunId), isTrue);
    });

    test('mirrors raw events without changing event admission', () async {
      final mirrored = <DiagnosticEvent>[];
      kit = await PersistentDiagnosticsTestkit.open(
        configuration: PersistentDiagnosticsConfiguration(minimumSeverity: DiagnosticSeverity.trace, eventMirror: mirrored.add),
      );
      mirrored.clear();

      final emitted = kit.service.manager.emit(
        AppDiagnosticEvents.routeChanged,
        attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{'toRoute': DiagnosticValue.string('library')}),
      );

      expect(emitted.accepted, isTrue);
      expect(mirrored, hasLength(1));
      expect(mirrored.single.eventName, 'app.route.changed');
      expect(mirrored.single.attributes.values['toRoute'], DiagnosticValue.string('library'));
    });

    test('isolates live mirror failures from event admission', () async {
      kit = await PersistentDiagnosticsTestkit.open(
        configuration: PersistentDiagnosticsConfiguration(
          minimumSeverity: DiagnosticSeverity.trace,
          eventMirror: (_) => throw StateError('console unavailable'),
        ),
      );

      final emitted = kit.service.manager.emit(
        AppDiagnosticEvents.routeChanged,
        attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{'toRoute': DiagnosticValue.string('library')}),
      );

      expect(emitted.accepted, isTrue);
    });

    test('keeps the caller bounded and reports queue drops after recovery', () async {
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
          attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{'toRoute': DiagnosticValue.string('route$index')}),
        );
      }
      final beforeFlush = kit.service.writerStatistics;
      await kit.service.manager.flush(timeout: const Duration(seconds: 2));
      final afterFlush = kit.service.writerStatistics;

      expect(beforeFlush.queueDepth, lessThanOrEqualTo(8));
      expect(beforeFlush.queueBytes, lessThanOrEqualTo(16 * 1024));
      expect(afterFlush.droppedEvents, greaterThan(0));
      expect(afterFlush.committedEvents, greaterThan(0));
      final dropped = await kit.service.listEvents(filter: DiagnosticEventFilter(eventNames: <String>{'diagnostics.events.dropped'}));
      expect(dropped.items, hasLength(1));
    });

    test('streams large text into a separate truncated detail TXT', () async {
      kit = await PersistentDiagnosticsTestkit.open(
        configuration: const PersistentDiagnosticsConfiguration(
          minimumSeverity: DiagnosticSeverity.trace,
          retentionPolicy: DiagnosticRetentionPolicy(singleAttachmentBytes: 128 * 1024),
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
        attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{'toRoute': DiagnosticValue.string('library')}),
      );
      final payload = List<int>.filled(500 * 1024, 0x61, growable: false);

      final descriptor = await kit.service.captureAttachment(
        eventId: emitted.event!.eventId,
        kind: 'http.response.body',
        mediaType: 'text/html',
        formatId: 'utf8-text',
        formatVersion: 1,
        bytes: Stream<List<int>>.fromIterable(<List<int>>[payload.sublist(0, 200 * 1024), payload.sublist(200 * 1024)]),
      );
      final rangeBytes = await kit.service
          .openAttachment(descriptor.attachmentId, range: DiagnosticByteRange(offset: 1024, length: 4096))
          .expand((chunk) => chunk)
          .toList();

      expect(descriptor.captureState, DiagnosticCaptureState.truncated);
      expect(descriptor.rawByteLength, 500 * 1024);
      expect(descriptor.storedByteLength, 128 * 1024);
      expect(descriptor.sha256, matches(RegExp(r'^[a-f0-9]{64}$')));
      expect(rangeBytes, payload.sublist(1024, 1024 + 4096));
      final diagnostics = Directory('${kit.root.path}${Platform.pathSeparator}diagnostics');
      final eventFiles = await diagnostics
          .list(recursive: true, followLinks: false)
          .where((entity) => entity is File && entity.path.contains('events'))
          .cast<File>()
          .toList();
      expect(eventFiles, isNotEmpty);
      for (final file in eventFiles) {
        expect(await file.readAsString(), isNot(contains(List<String>.filled(1024, 'a').join())));
      }
      final detailFile = File(
        '${diagnostics.path}${Platform.pathSeparator}details'
        '${Platform.pathSeparator}${descriptor.attachmentId}.txt',
      );
      expect(await detailFile.exists(), isTrue);
    });

    test('records policy-blocked payload without consuming its stream', () async {
      kit = await PersistentDiagnosticsTestkit.open();
      final emitted = kit.service.manager.emit(
        AppDiagnosticEvents.routeChanged,
        attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{'toRoute': DiagnosticValue.string('library')}),
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
        bytes: bytes,
      );

      expect(descriptor.captureState, DiagnosticCaptureState.policyBlocked);
      expect(descriptor.truncationReason, 'explicitCaptureRequired');
      expect(listened, isFalse);
      await expectLater(kit.service.openAttachment(descriptor.attachmentId).drain<void>(), throwsA(isA<StateError>()));
    });

    test('keeps live-debug details in bounded memory only', () async {
      kit = await PersistentDiagnosticsTestkit.open(
        configuration: const PersistentDiagnosticsConfiguration(minimumSeverity: DiagnosticSeverity.trace, detailMemoryBytes: 32 * 1024),
      );
      final capture = await kit.service.startCapture(
        DiagnosticCapturePolicy(
          payloadKind: DiagnosticPayloadKind.contentPayload,
          duration: const Duration(minutes: 5),
          maxStoredBytes: 16 * 1024,
          detailStorage: DiagnosticDetailStorage.memoryOnly,
          components: <String>{'app.router'},
        ),
      );
      final emitted = kit.service.manager.emit(
        AppDiagnosticEvents.routeChanged,
        attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{'toRoute': DiagnosticValue.string('library')}),
      );
      const detail = '<html><body>仅供实时调试</body></html>';
      final descriptor = await kit.service.captureAttachment(
        eventId: emitted.event!.eventId,
        kind: 'http.response.body',
        mediaType: 'text/html',
        formatId: 'utf8-text',
        formatVersion: 1,
        bytes: Stream<List<int>>.value(utf8.encode(detail)),
      );

      final beforeStop = await kit.service.getStatistics();
      expect(descriptor.captureState, DiagnosticCaptureState.captured);
      expect(beforeStop.memoryDetailBytes, greaterThan(0));
      expect(beforeStop.detailTextBytes, 0);
      expect(utf8.decode(await kit.service.openAttachment(descriptor.attachmentId).expand((chunk) => chunk).toList()), detail);

      await kit.service.stopCapture(capture.sessionId);
      expect((await kit.service.getStatistics()).memoryDetailBytes, 0);
      await expectLater(kit.service.openAttachment(descriptor.attachmentId).drain<void>(), throwsA(isA<StateError>()));
    });

    test('writes debug JSON bytes unchanged to detail TXT', () async {
      kit = await PersistentDiagnosticsTestkit.open();
      await kit.service.startCapture(
        DiagnosticCapturePolicy(
          payloadKind: DiagnosticPayloadKind.safeStructured,
          duration: const Duration(minutes: 5),
          maxStoredBytes: 64 * 1024,
          components: <String>{'app.router'},
        ),
      );
      final emitted = kit.service.manager.emit(
        AppDiagnosticEvents.routeChanged,
        attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{'toRoute': DiagnosticValue.string('library')}),
      );
      const secret = 'DETAIL_TOKEN_CANARY_28dd8f';
      const body =
          '{"token":"DETAIL_TOKEN_CANARY_28dd8f",'
          '"chapter":"仅在调试详情中保存"}';
      final descriptor = await kit.service.captureAttachment(
        eventId: emitted.event!.eventId,
        kind: 'http.response.json',
        mediaType: 'application/json',
        formatId: 'json-document',
        formatVersion: 1,
        bytes: Stream<List<int>>.value(utf8.encode(body)),
      );

      final diagnostics = Directory('${kit.root.path}${Platform.pathSeparator}diagnostics');
      final detail = File(
        '${diagnostics.path}${Platform.pathSeparator}details'
        '${Platform.pathSeparator}${descriptor.attachmentId}.txt',
      );
      expect(await detail.exists(), isTrue);
      final detailText = await detail.readAsString();
      expect(detailText, body);
      expect(detailText, contains('仅在调试详情中保存'));
      expect(detailText, contains(secret));

      await for (final entity in diagnostics.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        expect(entity.path.endsWith('.txt'), isTrue, reason: entity.path);
        final text = await entity.readAsString();
        if (entity.path.contains('${Platform.pathSeparator}events')) {
          expect(text, isNot(contains('仅在调试详情中保存')));
        }
      }
    });

    test('schema values are mirrored and persisted unchanged', () async {
      final canaryDefinition = DiagnosticEventDefinition.instant(
        name: 'test.secret.canary',
        component: 'test.security',
        summary: 'Secret canary event.',
        fields: <String, DiagnosticFieldDefinition>{
          'credential': const DiagnosticFieldDefinition(
            type: DiagnosticFieldType.string,
            requiredFor: <DiagnosticPhase>{DiagnosticPhase.instant},
          ),
        },
      );
      final registry = DiagnosticEventRegistry(<DiagnosticEventDefinition>[...AppDiagnosticEvents.registry.definitions, canaryDefinition]);
      final mirrored = <DiagnosticEvent>[];
      kit = await PersistentDiagnosticsTestkit.open(
        registry: registry,
        configuration: PersistentDiagnosticsConfiguration(minimumSeverity: DiagnosticSeverity.trace, eventMirror: mirrored.add),
      );
      mirrored.clear();
      kit.service.manager.emit(
        canaryDefinition,
        attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{'credential': DiagnosticValue.string(_secretCanary)}),
      );
      await kit.service.manager.flush(timeout: const Duration(seconds: 2));
      final consoleRecords = jsonEncode(mirrored.map(const DiagnosticEventCodec().encode).toList());
      expect(consoleRecords, contains(_secretCanary));

      final events = await kit.service.listEvents(filter: DiagnosticEventFilter(eventNames: <String>{canaryDefinition.name}));
      expect(
        events.items.single.attributes.values['credential'],
        isA<DiagnosticStringValue>().having((value) => value.value, 'value', _secretCanary),
      );
      await for (final entity in kit.root.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        final text = utf8.decode(await entity.readAsBytes(), allowMalformed: true);
        if (entity.path.contains('${Platform.pathSeparator}events')) {
          expect(text, contains(_secretCanary), reason: entity.path);
        }
      }
    });

    test('deletes a stopped capture and reclaims its unleased detail', () async {
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
        attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{'toRoute': DiagnosticValue.string('library')}),
      );
      final descriptor = await kit.service.captureAttachment(
        eventId: emitted.event!.eventId,
        kind: 'http.response.body',
        mediaType: 'text/plain',
        formatId: 'raw-bytes',
        formatVersion: 1,
        bytes: Stream<List<int>>.value(utf8.encode('captured payload')),
      );
      await kit.service.stopCapture(capture.sessionId);

      await kit.service.deleteSession(capture.sessionId);

      expect(await kit.service.getEvent(emitted.event!.eventId), isNull);
      expect((await kit.service.getStatistics()).detailCount, 0);
      await expectLater(kit.service.openAttachment(descriptor.attachmentId).drain<void>(), throwsA(isA<StateError>()));
    });

    test('enforces origin allowlists when assigning capture sessions', () async {
      final originDefinition = DiagnosticEventDefinition.instant(
        name: 'test.http.origin',
        component: 'test.http',
        summary: 'Projected HTTP origin.',
        fields: <String, DiagnosticFieldDefinition>{
          'origin': const DiagnosticFieldDefinition(
            type: DiagnosticFieldType.string,
            requiredFor: <DiagnosticPhase>{DiagnosticPhase.instant},
          ),
        },
      );
      kit = await PersistentDiagnosticsTestkit.open(
        registry: DiagnosticEventRegistry(<DiagnosticEventDefinition>[...AppDiagnosticEvents.registry.definitions, originDefinition]),
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
        captureContext: const DiagnosticCaptureContext(payloadKind: DiagnosticPayloadKind.contentPayload),
        attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{'origin': DiagnosticValue.string(origin)}),
      );

      final allowed = emit('https://allowed.example');
      final blocked = emit('https://blocked.example');
      await kit.service.manager.flush(timeout: const Duration(seconds: 2));

      final storedAllowed = await kit.service.getEvent(allowed.event!.eventId);
      final storedBlocked = await kit.service.getEvent(blocked.event!.eventId);
      expect(storedAllowed!.captureSessionId, capture.sessionId);
      expect(storedBlocked!.captureSessionId, kit.service.sourceRunId);
    });

    test('keeps stopped captures for capture retention instead of duration', () async {
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
      await kit.service.enforceRetention(const DiagnosticRetentionPolicy(captureAge: Duration(hours: 24)));
      var sessions = await kit.service.listSessions();
      expect(sessions.items.any((item) => item.sessionId == capture.sessionId), isTrue);

      clock.advance(const Duration(hours: 24));
      await kit.service.enforceRetention(const DiagnosticRetentionPolicy(captureAge: Duration(hours: 24)));
      sessions = await kit.service.listSessions();
      expect(sessions.items.any((item) => item.sessionId == capture.sessionId), isFalse);
    });

    test('caps explicit capture bytes and rejects oversized policies', () async {
      kit = await PersistentDiagnosticsTestkit.open(
        configuration: const PersistentDiagnosticsConfiguration(
          minimumSeverity: DiagnosticSeverity.trace,
          retentionPolicy: DiagnosticRetentionPolicy(captureBytes: 32 * 1024, globalHardBytes: 64 * 1024, singleAttachmentBytes: 16 * 1024),
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
        attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{'toRoute': DiagnosticValue.string('library')}),
      );
      final descriptor = await kit.service.captureAttachment(
        eventId: emitted.event!.eventId,
        kind: 'http.response.body',
        mediaType: 'text/plain',
        formatId: 'utf8-text',
        formatVersion: 1,
        bytes: Stream<List<int>>.value(List<int>.filled(64 * 1024, 7)),
      );
      final sessions = await kit.service.listSessions();
      final stored = sessions.items.singleWhere((item) => item.sessionId == capture.sessionId);

      expect(descriptor.captureState, DiagnosticCaptureState.truncated);
      expect(descriptor.storedByteLength, lessThanOrEqualTo(16 * 1024));
      expect(stored.storedBytes, lessThanOrEqualTo(20 * 1024));
    });

    test('serializes concurrent attachments so session quota cannot race', () async {
      kit = await PersistentDiagnosticsTestkit.open(
        configuration: const PersistentDiagnosticsConfiguration(
          minimumSeverity: DiagnosticSeverity.trace,
          retentionPolicy: DiagnosticRetentionPolicy(captureBytes: 32 * 1024, globalHardBytes: 64 * 1024, singleAttachmentBytes: 16 * 1024),
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
        attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{'toRoute': DiagnosticValue.string('library')}),
      );

      final descriptors = await Future.wait(
        List<Future<DiagnosticAttachmentDescriptor>>.generate(
          2,
          (index) => kit.service.captureAttachment(
            eventId: emitted.event!.eventId,
            kind: 'http.response.part$index',
            mediaType: 'text/plain',
            formatId: 'utf8-text',
            formatVersion: 1,
            bytes: Stream<List<int>>.value(List<int>.filled(16 * 1024, index)),
          ),
        ),
      );
      final sessions = await kit.service.listSessions();
      final stored = sessions.items.singleWhere((item) => item.sessionId == capture.sessionId);

      expect(descriptors.fold<int>(0, (sum, item) => sum + item.storedByteLength), lessThan(24 * 1024));
      expect(stored.storedBytes, lessThanOrEqualTo(24 * 1024));
    });

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
        attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{'toRoute': DiagnosticValue.string('library')}),
      );
      var cancelled = false;
      final controller = StreamController<List<int>>(onCancel: () => cancelled = true);
      addTearDown(controller.close);

      final descriptor = await kit.service.captureAttachment(
        eventId: emitted.event!.eventId,
        kind: 'http.response.body',
        mediaType: 'text/plain',
        formatId: 'utf8-text',
        formatVersion: 1,
        bytes: controller.stream,
      );

      expect(descriptor.captureState, DiagnosticCaptureState.truncated);
      expect(descriptor.truncationReason, 'attachmentWriteDeadline');
      expect(cancelled, isTrue);
    });

    test('defers detail deletion while a range reader holds a lease', () async {
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
        attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{'toRoute': DiagnosticValue.string('library')}),
      );
      final descriptor = await kit.service.captureAttachment(
        eventId: emitted.event!.eventId,
        kind: 'http.response.body',
        mediaType: 'text/plain',
        formatId: 'utf8-text',
        formatVersion: 1,
        bytes: Stream<List<int>>.value(List<int>.filled(128 * 1024, 11)),
      );
      await kit.service.stopCapture(capture.sessionId);
      final firstChunk = Completer<void>();
      late StreamSubscription<List<int>> subscription;
      subscription = kit.service.openAttachment(descriptor.attachmentId).listen((_) {
        if (!firstChunk.isCompleted) {
          subscription.pause();
          firstChunk.complete();
        }
      });
      await firstChunk.future;

      await kit.service.deleteSession(capture.sessionId);
      expect((await kit.service.getStatistics()).detailCount, 1);

      subscription.resume();
      await subscription.asFuture<void>();
      await kit.service.enforceRetention(const DiagnosticRetentionPolicy());
      expect((await kit.service.getStatistics()).detailCount, 0);
    });
  });

  test('startup retention trims ended regular sessions by byte budget', () async {
    final root = await Directory.systemTemp.createTemp('mg-read-diagnostics-retention-');
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
        attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{'toRoute': DiagnosticValue.string('route$index')}),
      );
    }
    await first.manager.flush(timeout: const Duration(seconds: 5));
    expect((await first.getStatistics()).logicalStoredBytes, greaterThan(8 * 1024));
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
  });

  test('reopen keeps history cold and isolates a partial TXT file until selection', () async {
    final root = await Directory.systemTemp.createTemp('mg-read-diagnostics-recovery-');
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
      '${Platform.pathSeparator}staging'
      '${Platform.pathSeparator}orphan.partial.txt',
    );
    await staging.writeAsString('partial');
    await first.close();
    final eventFiles = await Directory(
      '${root.path}${Platform.pathSeparator}diagnostics'
      '${Platform.pathSeparator}events',
    ).list().where((entity) => entity is File).cast<File>().toList();
    expect(eventFiles, hasLength(1));
    await eventFiles.single.writeAsString('{"incomplete":true}', mode: FileMode.append);

    final reopened = await DiagnosticsPersistence.open(dataRoot: root);
    addTearDown(reopened.close);
    final files = await reopened.listLogFiles();

    expect(files, hasLength(1));
    expect(await staging.exists(), isFalse);
    final unchanged = await eventFiles.single.readAsString();
    expect(unchanged, contains('incomplete'));
    await expectLater(reopened.listLogEvents(files.single.fileId), throwsFormatException);
  });

  test('removes legacy diagnostics databases and creates only TXT files', () async {
    final root = await Directory.systemTemp.createTemp('mg-read-diagnostics-legacy-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final diagnostics = Directory('${root.path}${Platform.pathSeparator}diagnostics');
    await diagnostics.create(recursive: true);
    final legacyFiles = <File>[
      File('${diagnostics.path}${Platform.pathSeparator}index.sqlite'),
      File('${diagnostics.path}${Platform.pathSeparator}index.sqlite-wal'),
      File('${diagnostics.path}${Platform.pathSeparator}index.sqlite-shm'),
    ];
    for (final file in legacyFiles) {
      await file.writeAsString('legacy');
    }
    final legacyObject = File(
      '${diagnostics.path}${Platform.pathSeparator}objects'
      '${Platform.pathSeparator}legacy.bin',
    );
    await legacyObject.parent.create(recursive: true);
    await legacyObject.writeAsString('legacy');

    final store = await DiagnosticsPersistence.open(dataRoot: root);
    addTearDown(store.close);
    await store.beginRun(
      sourceRunId: 'run_000000000000000000000100',
      source: DiagnosticSource.app,
      regularSessionMaxBytes: 1024,
      regularSessionAge: const Duration(days: 3),
    );

    for (final file in legacyFiles) {
      expect(await file.exists(), isFalse);
    }
    expect(await legacyObject.parent.exists(), isFalse);
    await for (final entity in diagnostics.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        expect(entity.path.endsWith('.txt'), isTrue, reason: entity.path);
      }
    }
  });
}

const String _secretCanary = 'MGREAD_SECRET_CANARY_7f62c7ad';
