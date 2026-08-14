import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:mg_read/core/persistence/src/diagnostics_persistence.dart';

import 'diagnostic_event.dart';
import 'diagnostic_ports.dart';
import 'diagnostic_privacy.dart';
import 'diagnostic_registry.dart';
import 'diagnostic_value.dart';
import 'diagnostics_manager.dart';

final class PersistentDiagnosticsConfiguration {
  const PersistentDiagnosticsConfiguration({
    this.minimumSeverity = DiagnosticSeverity.debug,
    this.traceComponents = const <String>{},
    this.maxQueueEvents = 4096,
    this.maxQueueBytes = 4 * 1024 * 1024,
    this.priorityReservedEvents = 256,
    this.priorityReservedBytes = 512 * 1024,
    this.batchSize = 128,
    this.maxBatchDelay = const Duration(milliseconds: 50),
    this.defaultFlushTimeout = const Duration(seconds: 2),
    this.attachmentWriteTimeout = const Duration(seconds: 10),
    this.retentionPolicy = const DiagnosticRetentionPolicy(),
  });

  final DiagnosticSeverity minimumSeverity;
  final Set<String> traceComponents;
  final int maxQueueEvents;
  final int maxQueueBytes;
  final int priorityReservedEvents;
  final int priorityReservedBytes;
  final int batchSize;
  final Duration maxBatchDelay;
  final Duration defaultFlushTimeout;
  final Duration attachmentWriteTimeout;
  final DiagnosticRetentionPolicy retentionPolicy;

  void validate() {
    retentionPolicy.validate();
    if (maxQueueEvents <= 0 ||
        maxQueueBytes <= 0 ||
        priorityReservedEvents < 0 ||
        priorityReservedEvents >= maxQueueEvents ||
        priorityReservedBytes < 0 ||
        priorityReservedBytes >= maxQueueBytes ||
        batchSize <= 0 ||
        batchSize > DiagnosticsPersistence.maxWriteBatchSize ||
        maxBatchDelay <= Duration.zero ||
        defaultFlushTimeout <= Duration.zero ||
        attachmentWriteTimeout <= Duration.zero) {
      throw ArgumentError('Persistent diagnostics configuration is invalid.');
    }
  }
}

final class DiagnosticWriterStatistics {
  const DiagnosticWriterStatistics({
    required this.queueDepth,
    required this.queueBytes,
    required this.queueHighWater,
    required this.queueByteHighWater,
    required this.acceptedEvents,
    required this.committedEvents,
    required this.droppedEvents,
    required this.writerErrors,
    required this.lastCommitMicros,
    required this.lastBatchSize,
    required this.flushTimeouts,
    required this.lastWriterFailureType,
    required this.eventEncodingOffloaded,
  });

  final int queueDepth;
  final int queueBytes;
  final int queueHighWater;
  final int queueByteHighWater;
  final int acceptedEvents;
  final int committedEvents;
  final int droppedEvents;
  final int writerErrors;
  final int lastCommitMicros;
  final int lastBatchSize;
  final int flushTimeouts;
  final String? lastWriterFailureType;
  final bool eventEncodingOffloaded;
}

typedef DiagnosticActiveSessionResolver =
    String? Function(DiagnosticEvent event);
typedef DiagnosticCaptureEnabledResolver = bool Function(String component);
typedef DiagnosticDropReporter =
    void Function(int droppedEvents, int windowMicros, String reason);

/// Bounded, non-blocking queue between app call sites and background SQLite.
final class _PersistentDiagnosticEventSink implements DiagnosticEventSink {
  _PersistentDiagnosticEventSink({
    required this.persistence,
    required this.configuration,
  }) {
    configuration.validate();
    _dropWindow.start();
  }

  final DiagnosticsPersistence persistence;
  final PersistentDiagnosticsConfiguration configuration;
  final ListQueue<_QueuedDiagnosticEvent> _normalQueue =
      ListQueue<_QueuedDiagnosticEvent>();
  final ListQueue<_QueuedDiagnosticEvent> _priorityQueue =
      ListQueue<_QueuedDiagnosticEvent>();
  final Stopwatch _dropWindow = Stopwatch();
  Timer? _batchTimer;
  Future<void>? _drainFuture;
  DiagnosticActiveSessionResolver? activeSessionResolver;
  DiagnosticCaptureEnabledResolver? captureEnabledResolver;
  DiagnosticDropReporter? dropReporter;
  var _queueBytes = 0;
  var _normalQueueBytes = 0;
  var _queueHighWater = 0;
  var _queueByteHighWater = 0;
  var _acceptedEvents = 0;
  var _committedEvents = 0;
  var _droppedEvents = 0;
  var _pendingDropReport = 0;
  var _writerErrors = 0;
  var _lastCommitMicros = 0;
  var _lastBatchSize = 0;
  var _flushTimeouts = 0;
  var _lastDropReason = 'queuePressure';
  String? _lastWriterFailureType;
  var _eventEncodingOffloaded = false;
  var _closing = false;
  var _closed = false;

  DiagnosticWriterStatistics get statistics => DiagnosticWriterStatistics(
    queueDepth: _queueDepth,
    queueBytes: _queueBytes,
    queueHighWater: _queueHighWater,
    queueByteHighWater: _queueByteHighWater,
    acceptedEvents: _acceptedEvents,
    committedEvents: _committedEvents,
    droppedEvents: _droppedEvents,
    writerErrors: _writerErrors,
    lastCommitMicros: _lastCommitMicros,
    lastBatchSize: _lastBatchSize,
    flushTimeouts: _flushTimeouts,
    lastWriterFailureType: _lastWriterFailureType,
    eventEncodingOffloaded: _eventEncodingOffloaded,
  );

  int get _queueDepth => _normalQueue.length + _priorityQueue.length;

  @override
  bool isEnabled({
    required String component,
    required DiagnosticSeverity severity,
    required DiagnosticPayloadKind payloadKind,
  }) {
    if (_closing || _closed) return false;
    if (severity == DiagnosticSeverity.trace &&
        !configuration.traceComponents.contains(component)) {
      return false;
    }
    if (severity.index < configuration.minimumSeverity.index) return false;
    return payloadKind == DiagnosticPayloadKind.metadataOnly ||
        captureEnabledResolver?.call(component) == true;
  }

  @override
  bool add(DiagnosticEvent rawEvent) {
    if (_closing || _closed) return false;
    final activeSessionId = activeSessionResolver?.call(rawEvent);
    final event = rawEvent.captureSessionId == null && activeSessionId != null
        ? rawEvent.copyWith(captureSessionId: activeSessionId)
        : rawEvent;
    final estimatedBytes = _estimateBytes(event);
    final priority = event.severity.index >= DiagnosticSeverity.warn.index;
    if (priority) {
      while (!_fitsPriority(estimatedBytes) && _normalQueue.isNotEmpty) {
        _dropQueued(_normalQueue.removeFirst(), 'priorityReservation');
      }
      if (!_fitsPriority(estimatedBytes)) {
        _recordDrop('priorityQueueFull');
        return false;
      }
      _priorityQueue.addLast(_QueuedDiagnosticEvent(event, estimatedBytes));
    } else {
      final normalEventLimit =
          configuration.maxQueueEvents - configuration.priorityReservedEvents;
      final normalByteLimit =
          configuration.maxQueueBytes - configuration.priorityReservedBytes;
      if (_normalQueue.length >= normalEventLimit ||
          _normalQueueBytes + estimatedBytes > normalByteLimit ||
          _queueDepth >= configuration.maxQueueEvents ||
          _queueBytes + estimatedBytes > configuration.maxQueueBytes) {
        _recordDrop('normalQueueFull');
        return false;
      }
      _normalQueue.addLast(_QueuedDiagnosticEvent(event, estimatedBytes));
      _normalQueueBytes += estimatedBytes;
    }
    _queueBytes += estimatedBytes;
    _acceptedEvents += 1;
    _queueHighWater = max(_queueHighWater, _queueDepth);
    _queueByteHighWater = max(_queueByteHighWater, _queueBytes);
    _scheduleDrain(immediate: _queueDepth >= configuration.batchSize);
    return true;
  }

  @override
  Future<void> flush({required Duration timeout}) async {
    if (_closed) return;
    _batchTimer?.cancel();
    _batchTimer = null;
    _startDrain();
    final drain = _drainFuture;
    if (drain == null) return;
    try {
      await drain.timeout(timeout);
    } on TimeoutException {
      _flushTimeouts += 1;
    }
  }

  @override
  Future<void> close({required Duration timeout}) async {
    if (_closed) return;
    _closing = true;
    await flush(timeout: timeout);
    if (_queueDepth > 0) {
      while (_normalQueue.isNotEmpty) {
        _dropQueued(_normalQueue.removeFirst(), 'closeDeadline');
      }
      while (_priorityQueue.isNotEmpty) {
        _dropQueued(_priorityQueue.removeFirst(), 'closeDeadline');
      }
    }
    _closed = true;
    _batchTimer?.cancel();
    _dropWindow.stop();
  }

  bool _fitsPriority(int bytes) =>
      _queueDepth < configuration.maxQueueEvents &&
      _queueBytes + bytes <= configuration.maxQueueBytes;

  void _scheduleDrain({required bool immediate}) {
    if (_drainFuture != null || _closed) return;
    if (immediate) {
      _batchTimer?.cancel();
      _batchTimer = null;
      scheduleMicrotask(_startDrain);
      return;
    }
    _batchTimer ??= Timer(configuration.maxBatchDelay, _startDrain);
  }

  void _startDrain() {
    if (_drainFuture != null || _closed || _queueDepth == 0) return;
    _batchTimer?.cancel();
    _batchTimer = null;
    _drainFuture = _drain().whenComplete(() {
      _drainFuture = null;
      if (_queueDepth > 0 && !_closed) _scheduleDrain(immediate: true);
    });
  }

  Future<void> _drain() async {
    while (_queueDepth > 0) {
      final batch = <DiagnosticEvent>[];
      while (batch.length < configuration.batchSize && _queueDepth > 0) {
        final queued = _removeNextInSourceOrder();
        batch.add(queued.event);
        _queueBytes -= queued.estimatedBytes;
      }
      final stopwatch = Stopwatch()..start();
      try {
        await persistence.insertEvents(batch);
        _eventEncodingOffloaded =
            persistence.lastEncoderWorkerIsolateIdForTest != null &&
            persistence.lastEncoderWorkerIsolateIdForTest !=
                Isolate.current.hashCode;
        stopwatch.stop();
        _lastCommitMicros = stopwatch.elapsedMicroseconds;
        _lastBatchSize = batch.length;
        _committedEvents += batch.length;
        _reportRecoveredDrops();
      } catch (error) {
        stopwatch.stop();
        _writerErrors += 1;
        _lastWriterFailureType = error.runtimeType.toString();
        _lastCommitMicros = stopwatch.elapsedMicroseconds;
        _lastBatchSize = batch.length;
        for (var index = 0; index < batch.length; index += 1) {
          _recordDrop('writerFailure');
        }
      }
    }
  }

  _QueuedDiagnosticEvent _removeNextInSourceOrder() {
    if (_normalQueue.isEmpty) return _priorityQueue.removeFirst();
    if (_priorityQueue.isEmpty) {
      final event = _normalQueue.removeFirst();
      _normalQueueBytes -= event.estimatedBytes;
      return event;
    }
    if (_normalQueue.first.event.sourceSequence <
        _priorityQueue.first.event.sourceSequence) {
      final event = _normalQueue.removeFirst();
      _normalQueueBytes -= event.estimatedBytes;
      return event;
    }
    return _priorityQueue.removeFirst();
  }

  void _dropQueued(_QueuedDiagnosticEvent event, String reason) {
    _queueBytes -= event.estimatedBytes;
    _normalQueueBytes -= event.estimatedBytes;
    _recordDrop(reason);
  }

  void _recordDrop(String reason) {
    _droppedEvents += 1;
    _pendingDropReport += 1;
    _lastDropReason = reason;
  }

  void _reportRecoveredDrops() {
    if (_pendingDropReport == 0 || dropReporter == null) return;
    final count = _pendingDropReport;
    final window = _dropWindow.elapsedMicroseconds;
    final reason = _lastDropReason;
    _pendingDropReport = 0;
    _dropWindow
      ..reset()
      ..start();
    dropReporter!(count, window, reason);
  }

  int _estimateBytes(DiagnosticEvent event) =>
      512 + event.summary.length * 2 + event.attributes.encodedByteLength;
}

final class _QueuedDiagnosticEvent {
  const _QueuedDiagnosticEvent(this.event, this.estimatedBytes);

  final DiagnosticEvent event;
  final int estimatedBytes;
}

/// App-side facade combining manager, durable index, object storage and ports.
final class AppDiagnosticsService
    implements DiagnosticsQuery, DiagnosticsCapture, DiagnosticsMaintenance {
  AppDiagnosticsService._({
    required this.manager,
    required this._sink,
    required this._persistence,
    required this.configuration,
    required this.sourceRunId,
    required this._idGenerator,
    required this._runSpan,
  });

  final DiagnosticsManager manager;
  final _PersistentDiagnosticEventSink _sink;
  final DiagnosticsPersistence _persistence;
  final PersistentDiagnosticsConfiguration configuration;
  final String sourceRunId;
  final DiagnosticIdGenerator _idGenerator;
  final DiagnosticSpanHandle _runSpan;
  DiagnosticStoredCaptureSession? _activeCapture;
  DiagnosticSpanHandle? _captureSpan;
  Timer? _captureExpiryTimer;
  Future<void> _attachmentWriteTail = Future<void>.value();
  bool _closing = false;
  bool _closed = false;

  DiagnosticWriterStatistics get writerStatistics => _sink.statistics;

  static Future<AppDiagnosticsService> open({
    required Directory dataRoot,
    PersistentDiagnosticsConfiguration configuration =
        const PersistentDiagnosticsConfiguration(),
    DiagnosticIdGenerator? idGenerator,
    DiagnosticClock? clock,
    DiagnosticEventRegistry? registry,
    DiagnosticPrivacyPolicy? privacyPolicy,
    String buildMode = 'debug',
    String platform = 'unknown',
  }) async {
    configuration.validate();
    final ids = idGenerator ?? SecureDiagnosticIdGenerator();
    final effectiveClock = clock ?? const SystemDiagnosticClock();
    final sourceRunId = ids.nextId('run');
    final persistence = await DiagnosticsPersistence.open(
      dataRoot: dataRoot,
      clock: effectiveClock.nowUtc,
    );
    await persistence.enforceRetention(configuration.retentionPolicy);
    await persistence.beginRun(
      sourceRunId: sourceRunId,
      source: DiagnosticSource.app,
      regularSessionMaxBytes: configuration.retentionPolicy.regularEventBytes,
      regularSessionAge: configuration.retentionPolicy.regularEventAge,
    );
    final sink = _PersistentDiagnosticEventSink(
      persistence: persistence,
      configuration: configuration,
    );
    final manager = DiagnosticsManager(
      sink: sink,
      registry: registry ?? AppDiagnosticEvents.registry,
      source: DiagnosticSource.app,
      privacyPolicy: privacyPolicy,
      idGenerator: ids,
      clock: effectiveClock,
      sourceRunId: sourceRunId,
      buildMode: buildMode,
      platform: platform,
    );
    final runSpan = manager.startSpan(
      AppDiagnosticEvents.diagnosticsRun,
      attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
        'buildMode': DiagnosticValue.string(buildMode),
        'platform': DiagnosticValue.string(platform),
      }),
    );
    final service = AppDiagnosticsService._(
      manager: manager,
      sink: sink,
      persistence: persistence,
      configuration: configuration,
      sourceRunId: sourceRunId,
      idGenerator: ids,
      runSpan: runSpan,
    );
    sink.activeSessionResolver = service._activeSessionForEvent;
    sink.captureEnabledResolver = service._isCaptureEnabledForComponent;
    sink.dropReporter = service._reportDrops;
    manager.emit(
      AppDiagnosticEvents.writerState,
      attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
        'state': DiagnosticValue.string('ready'),
        'queueDepth': DiagnosticValue.int64(sink.statistics.queueDepth),
        'queueBytes': DiagnosticValue.int64(sink.statistics.queueBytes),
      }),
    );
    return service;
  }

  @override
  Future<DiagnosticPage<DiagnosticSession>> listSessions({
    DiagnosticSessionFilter filter = const DiagnosticSessionFilter(),
    DiagnosticCursor? cursor,
    int limit = 100,
  }) async {
    await _sink.flush(timeout: const Duration(milliseconds: 500));
    return _persistence.listSessions(
      filter: filter,
      cursor: cursor,
      limit: limit,
    );
  }

  @override
  Future<DiagnosticPage<DiagnosticEvent>> listEvents({
    required DiagnosticEventFilter filter,
    DiagnosticCursor? cursor,
    int limit = 100,
  }) async {
    await _sink.flush(timeout: const Duration(milliseconds: 500));
    return _persistence.listEvents(
      filter: filter,
      cursor: cursor,
      limit: limit,
    );
  }

  @override
  Future<DiagnosticEvent?> getEvent(String eventId) async {
    await _sink.flush(timeout: const Duration(milliseconds: 500));
    return _persistence.getEvent(eventId);
  }

  @override
  Future<List<DiagnosticAttachmentDescriptor>> listAttachments(
    String eventId,
  ) => _persistence.listAttachments(eventId);

  @override
  Stream<List<int>> openAttachment(
    String attachmentId, {
    DiagnosticByteRange? range,
  }) => _persistence.openAttachment(attachmentId, range: range);

  @override
  Future<DiagnosticPage<DiagnosticStructuredNode>> listStructuredNodes(
    String attachmentId, {
    required String path,
    DiagnosticCursor? cursor,
    int limit = 100,
  }) {
    throw UnsupportedError(
      'Structured attachment paging is delivered with the diagnostics viewer.',
    );
  }

  @override
  Future<DiagnosticSession> startCapture(DiagnosticCapturePolicy policy) async {
    _ensureOpen();
    final span = manager.startSpan(
      AppDiagnosticEvents.capture,
      attributes: () => _captureAttributes(policy, sessionState: 'starting'),
    );
    try {
      if (policy.payloadKind == DiagnosticPayloadKind.restrictedRaw) {
        throw UnsupportedError(
          'restrictedRaw requires the separately approved encrypted D5 store.',
        );
      }
      if (_activeCapture != null) {
        throw StateError(
          'Only one explicit app capture session may be active.',
        );
      }
      final sessionId = _idGenerator.nextId('capture');
      if (policy.maxStoredBytes > configuration.retentionPolicy.captureBytes) {
        throw RangeError.range(
          policy.maxStoredBytes,
          1,
          configuration.retentionPolicy.captureBytes,
          'policy.maxStoredBytes',
        );
      }
      await _persistence.createCaptureSession(
        sessionId: sessionId,
        sourceRunId: sourceRunId,
        policy: policy,
      );
      _activeCapture = await _persistence.getCaptureSession(sessionId);
      _captureSpan = span;
      _captureExpiryTimer = Timer(policy.duration, () {
        unawaited(stopCapture(sessionId).catchError((_) {}));
      });
      return _activeCapture!.session;
    } catch (error, stackTrace) {
      span.fail(
        attributes: _captureAttributes(
          policy,
          sessionState: 'failed',
          errorCode: _captureErrorCode(error),
        ),
      );
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  @override
  Future<void> stopCapture(String sessionId) async {
    _ensureOpen();
    final active = _activeCapture;
    try {
      await _persistence.stopCaptureSession(sessionId);
      if (active?.session.sessionId == sessionId) {
        _captureExpiryTimer?.cancel();
        _captureExpiryTimer = null;
        _activeCapture = null;
        if (_captureSpan case final span? when !span.isEnded) {
          span.complete(
            attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
              'sessionState': DiagnosticValue.string('ended'),
            }),
          );
        }
        _captureSpan = null;
      }
    } catch (error, stackTrace) {
      if (active?.session.sessionId == sessionId) {
        final span = _captureSpan;
        if (span != null && !span.isEnded) {
          span.fail(
            attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
              'sessionState': DiagnosticValue.string('stopFailed'),
              'errorCode': DiagnosticValue.string('capture_stop_failed'),
            }),
          );
          _captureSpan = null;
        }
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  @override
  Future<DiagnosticAttachmentDescriptor> captureAttachment({
    required String eventId,
    required String kind,
    required String mediaType,
    required String formatId,
    required int formatVersion,
    required DiagnosticPrivacyClass privacyClass,
    required Stream<List<int>> bytes,
    String? charset,
    String? schemaId,
    int? schemaVersion,
  }) {
    final operation = _attachmentWriteTail.then(
      (_) => _captureAttachment(
        eventId: eventId,
        kind: kind,
        mediaType: mediaType,
        formatId: formatId,
        formatVersion: formatVersion,
        privacyClass: privacyClass,
        bytes: bytes,
        charset: charset,
        schemaId: schemaId,
        schemaVersion: schemaVersion,
      ),
    );
    _attachmentWriteTail = operation.then<void>((_) {}, onError: (_, _) {});
    return operation;
  }

  Future<DiagnosticAttachmentDescriptor> _captureAttachment({
    required String eventId,
    required String kind,
    required String mediaType,
    required String formatId,
    required int formatVersion,
    required DiagnosticPrivacyClass privacyClass,
    required Stream<List<int>> bytes,
    String? charset,
    String? schemaId,
    int? schemaVersion,
  }) async {
    final span = manager.startSpan(
      AppDiagnosticEvents.attachment,
      attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
        'kind': DiagnosticValue.string(kind),
        'privacyClass': DiagnosticValue.string(privacyClass.name),
      }),
    );
    try {
      final result = await _captureAttachmentCore(
        eventId: eventId,
        kind: kind,
        mediaType: mediaType,
        formatId: formatId,
        formatVersion: formatVersion,
        privacyClass: privacyClass,
        bytes: bytes,
        charset: charset,
        schemaId: schemaId,
        schemaVersion: schemaVersion,
      );
      final attributes = DiagnosticObjectValue(<String, DiagnosticValue>{
        'kind': DiagnosticValue.string(kind),
        'privacyClass': DiagnosticValue.string(privacyClass.name),
        'captureState': DiagnosticValue.string(result.captureState.name),
        'rawBytes': DiagnosticValue.int64(result.rawByteLength),
        'storedBytes': DiagnosticValue.int64(result.storedByteLength),
        if (result.captureState == DiagnosticCaptureState.failed)
          'errorCode': DiagnosticValue.string('attachment_failed'),
      });
      if (result.captureState == DiagnosticCaptureState.failed) {
        span.fail(attributes: attributes);
      } else {
        span.complete(attributes: attributes);
      }
      return result;
    } catch (error, stackTrace) {
      span.fail(
        attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
          'kind': DiagnosticValue.string(kind),
          'privacyClass': DiagnosticValue.string(privacyClass.name),
          'captureState': DiagnosticValue.string('failed'),
          'errorCode': DiagnosticValue.string('attachment_failed'),
        }),
      );
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<DiagnosticAttachmentDescriptor> _captureAttachmentCore({
    required String eventId,
    required String kind,
    required String mediaType,
    required String formatId,
    required int formatVersion,
    required DiagnosticPrivacyClass privacyClass,
    required Stream<List<int>> bytes,
    String? charset,
    String? schemaId,
    int? schemaVersion,
  }) async {
    _ensureOpen();
    await _sink.flush(timeout: configuration.defaultFlushTimeout);
    final event = await _persistence.getEvent(eventId);
    if (event == null) throw StateError('Diagnostic event does not exist.');
    final session = await _persistence.getCaptureSession(
      event.captureSessionId!,
    );
    final attachmentId = _idGenerator.nextId('attachment');
    String? blockedReason;
    if (session == null || session.isDefault) {
      blockedReason = 'explicitCaptureRequired';
    } else if (session.session.state != DiagnosticSessionState.active) {
      blockedReason = 'captureSessionInactive';
    } else if (privacyClass == DiagnosticPrivacyClass.secret) {
      blockedReason = 'secretNeverPersisted';
    } else if (privacyClass == DiagnosticPrivacyClass.restricted) {
      blockedReason = 'restrictedRawUnsupported';
    } else if (privacyClass == DiagnosticPrivacyClass.content &&
        session.session.payloadKind == DiagnosticPayloadKind.metadataOnly) {
      blockedReason = 'payloadModeBlocked';
    } else if (privacyClass == DiagnosticPrivacyClass.content &&
        session.session.payloadKind == DiagnosticPayloadKind.safeStructured) {
      blockedReason = 'safeStructuredRedactorRequired';
    } else if (session.remainingBytes <= 0) {
      blockedReason = 'captureSessionQuota';
    }
    if (blockedReason != null) {
      final descriptor = _descriptor(
        attachmentId: attachmentId,
        eventId: eventId,
        kind: kind,
        mediaType: mediaType,
        charset: charset,
        formatId: formatId,
        formatVersion: formatVersion,
        schemaId: schemaId,
        schemaVersion: schemaVersion,
        privacyClass: privacyClass,
        captureState: DiagnosticCaptureState.policyBlocked,
        rawByteLength: 0,
        storedByteLength: 0,
        truncationReason: blockedReason,
      );
      return _persistence.commitAttachment(
        descriptor: descriptor,
        objectKey: null,
      );
    }
    final maxBytes = min(
      configuration.retentionPolicy.singleAttachmentBytes,
      session!.remainingBytes,
    );
    try {
      final statistics = await _persistence.getStatistics();
      final globalRemaining =
          configuration.retentionPolicy.globalHardBytes -
          statistics.logicalStoredBytes;
      if (globalRemaining <= 0) {
        final descriptor = _descriptor(
          attachmentId: attachmentId,
          eventId: eventId,
          kind: kind,
          mediaType: mediaType,
          charset: charset,
          formatId: formatId,
          formatVersion: formatVersion,
          schemaId: schemaId,
          schemaVersion: schemaVersion,
          privacyClass: privacyClass,
          captureState: DiagnosticCaptureState.pressureDropped,
          rawByteLength: 0,
          storedByteLength: 0,
          truncationReason: 'globalDiagnosticsQuota',
        );
        return _persistence.commitAttachment(
          descriptor: descriptor,
          objectKey: null,
        );
      }
      final effectiveMaxBytes = min(maxBytes, globalRemaining);
      final commit = await _persistence.objectStore.write(
        attachmentId: attachmentId,
        privacyClass: privacyClass,
        bytes: bytes,
        maxStoredBytes: effectiveMaxBytes,
        maxDuration: configuration.attachmentWriteTimeout,
      );
      final descriptor = _descriptor(
        attachmentId: attachmentId,
        eventId: eventId,
        kind: kind,
        mediaType: mediaType,
        charset: charset,
        formatId: formatId,
        formatVersion: formatVersion,
        schemaId: schemaId,
        schemaVersion: schemaVersion,
        privacyClass: privacyClass,
        captureState: commit.captureState,
        rawByteLength: commit.rawByteLength,
        storedByteLength: commit.storedByteLength,
        sha256: commit.sha256,
        truncationReason: commit.truncationReason,
      );
      final stored = await _persistence.commitAttachment(
        descriptor: descriptor,
        objectKey: commit.objectKey,
      );
      _activeCapture = await _persistence.getCaptureSession(
        session.session.sessionId,
      );
      return stored;
    } catch (_) {
      final descriptor = _descriptor(
        attachmentId: attachmentId,
        eventId: eventId,
        kind: kind,
        mediaType: mediaType,
        charset: charset,
        formatId: formatId,
        formatVersion: formatVersion,
        schemaId: schemaId,
        schemaVersion: schemaVersion,
        privacyClass: privacyClass,
        captureState: DiagnosticCaptureState.failed,
        rawByteLength: 0,
        storedByteLength: 0,
        truncationReason: 'objectWriteFailed',
      );
      try {
        return await _persistence.commitAttachment(
          descriptor: descriptor,
          objectKey: null,
        );
      } catch (_) {
        return descriptor;
      }
    }
  }

  @override
  Future<DiagnosticMaintenanceResult> enforceRetention(
    DiagnosticRetentionPolicy policy,
  ) => manager.runSpan<DiagnosticMaintenanceResult>(
    AppDiagnosticEvents.retention,
    (_) async {
      await _sink.flush(timeout: configuration.defaultFlushTimeout);
      return _persistence.enforceRetention(policy);
    },
    successAttributes: (result) =>
        DiagnosticObjectValue(<String, DiagnosticValue>{
          'sessionCount': DiagnosticValue.int64(result.deletedSessions),
          'eventCount': DiagnosticValue.int64(result.deletedEvents),
          'objectBytes': DiagnosticValue.int64(result.reclaimedBytes),
        }),
    errorAttributes: (_) => DiagnosticObjectValue(<String, DiagnosticValue>{
      'errorCode': DiagnosticValue.string('retention_failed'),
    }),
  );

  @override
  Future<void> deleteSession(String sessionId) async {
    await _persistence.deleteSession(sessionId);
  }

  @override
  Future<DiagnosticExportResult> exportBundle({
    required DiagnosticExportSelection selection,
    required DiagnosticExportPolicy policy,
  }) {
    throw UnsupportedError(
      'Bundle export is delivered with the diagnostics viewer package.',
    );
  }

  Future<DiagnosticStorageStatistics> getStatistics() async {
    await _sink.flush(timeout: configuration.defaultFlushTimeout);
    return _persistence.getStatistics();
  }

  Future<void> close() async {
    if (_closed || _closing) return;
    _closing = true;
    _captureExpiryTimer?.cancel();
    if (_activeCapture case final capture?) {
      await _persistence.stopCaptureSession(capture.session.sessionId);
      if (_captureSpan case final span? when !span.isEnded) {
        span.complete(
          attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
            'sessionState': DiagnosticValue.string('closed'),
          }),
        );
      }
      _captureSpan = null;
      _activeCapture = null;
    }
    manager.emit(
      AppDiagnosticEvents.writerState,
      attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
        'state': DiagnosticValue.string('stopping'),
        'queueDepth': DiagnosticValue.int64(_sink.statistics.queueDepth),
        'queueBytes': DiagnosticValue.int64(_sink.statistics.queueBytes),
        'batchSize': DiagnosticValue.int64(_sink.statistics.lastBatchSize),
        'commitMicros': DiagnosticValue.int64(
          _sink.statistics.lastCommitMicros,
        ),
      }),
    );
    try {
      await _attachmentWriteTail.timeout(
        configuration.attachmentWriteTimeout + const Duration(seconds: 1),
      );
    } on TimeoutException {
      // The object writer has its own deadline; shutdown stays fail-open.
    }
    _runSpan.complete();
    await manager.close(timeout: configuration.defaultFlushTimeout);
    await _persistence.endRun(sourceRunId);
    await _persistence.checkpointWal();
    await _persistence.close();
    _closed = true;
  }

  String? _activeSessionForEvent(DiagnosticEvent event) {
    final capture = _activeCapture;
    if (capture == null ||
        capture.session.state != DiagnosticSessionState.active ||
        capture.remainingBytes <= 0) {
      return null;
    }
    if (capture.components.isNotEmpty &&
        !capture.components.contains(event.component)) {
      return null;
    }
    if (capture.origins.isNotEmpty) {
      final origin = event.attributes.values['origin'];
      if (origin is! DiagnosticStringValue ||
          !capture.origins.contains(origin.value)) {
        return null;
      }
    }
    return capture.session.sessionId;
  }

  bool _isCaptureEnabledForComponent(String component) {
    final capture = _activeCapture;
    if (capture == null ||
        capture.session.state != DiagnosticSessionState.active ||
        capture.remainingBytes <= 0) {
      return false;
    }
    return capture.components.isEmpty || capture.components.contains(component);
  }

  void _reportDrops(int count, int windowMicros, String reason) {
    manager.emit(
      AppDiagnosticEvents.eventsDropped,
      attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
        'reason': DiagnosticValue.string(reason),
        'dropCount': DiagnosticValue.int64(count),
        'windowMicros': DiagnosticValue.int64(windowMicros),
        'lowestSeverity': DiagnosticValue.string('trace'),
      }),
    );
  }

  DiagnosticAttachmentDescriptor _descriptor({
    required String attachmentId,
    required String eventId,
    required String kind,
    required String mediaType,
    required String formatId,
    required int formatVersion,
    required DiagnosticPrivacyClass privacyClass,
    required DiagnosticCaptureState captureState,
    required int rawByteLength,
    required int storedByteLength,
    String? charset,
    String? schemaId,
    int? schemaVersion,
    String? sha256,
    String? truncationReason,
  }) => DiagnosticAttachmentDescriptor(
    attachmentId: attachmentId,
    eventId: eventId,
    kind: kind,
    mediaType: mediaType,
    charset: charset,
    formatId: formatId,
    formatVersion: formatVersion,
    schemaId: schemaId,
    schemaVersion: schemaVersion,
    privacyClass: privacyClass,
    captureState: captureState,
    rawByteLength: rawByteLength,
    storedByteLength: storedByteLength,
    sha256: sha256,
    storageCodec: DiagnosticStorageCodec.identity,
    redactionVersion: 1,
    truncationReason: truncationReason,
  );

  void _ensureOpen() {
    if (_closing || _closed) {
      throw StateError('AppDiagnosticsService is closing or closed.');
    }
  }
}

DiagnosticObjectValue _captureAttributes(
  DiagnosticCapturePolicy policy, {
  required String sessionState,
  String? errorCode,
}) => DiagnosticObjectValue(<String, DiagnosticValue>{
  'payloadKind': DiagnosticValue.string(policy.payloadKind.name),
  'durationMicros': DiagnosticValue.int64(policy.duration.inMicroseconds),
  'maxBytes': DiagnosticValue.int64(policy.maxStoredBytes),
  'componentCount': DiagnosticValue.int64(policy.components.length),
  'originCount': DiagnosticValue.int64(policy.origins.length),
  'sessionState': DiagnosticValue.string(sessionState),
  if (errorCode != null) 'errorCode': DiagnosticValue.string(errorCode),
});

String _captureErrorCode(Object error) => switch (error) {
  UnsupportedError() => 'capture_mode_unsupported',
  RangeError() => 'capture_quota_invalid',
  StateError() => 'capture_state_invalid',
  _ => 'capture_start_failed',
};
