/// 应用持久化诊断服务。
///
/// 职责：
/// - 将全局诊断事件写入有界队列和 TXT 持久化存储。
/// - 提供受限详情捕获、附件和会话生命周期管理。
///
/// 注意：
/// - 诊断压力或写入失败不得阻塞业务链路。
/// - 默认禁止捕获正文、凭据、Cookie、路径和原始异常。
///
/// TODO:
/// - 无。
library;

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

part 'persistent_diagnostics_service.dart';

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
    this.detailMemoryBytes = 8 * 1024 * 1024,
    this.retentionPolicy = const DiagnosticRetentionPolicy(),
    this.eventMirror,
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
  final int detailMemoryBytes;
  final DiagnosticRetentionPolicy retentionPolicy;

  /// Optional process-local mirror for already schema-validated events.
  ///
  /// Production wiring uses this only for the developer console in non-release
  /// builds. Failures are deliberately isolated from event admission.
  final DiagnosticEventMirror? eventMirror;

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
        attachmentWriteTimeout <= Duration.zero ||
        detailMemoryBytes <= 0) {
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

typedef DiagnosticActiveSessionResolver = String? Function(DiagnosticEvent event);
typedef DiagnosticCaptureEnabledResolver = bool Function(String component);
typedef DiagnosticDropReporter = void Function(int droppedEvents, int windowMicros, String reason);

/// Receives the manager-sanitized event for an optional live diagnostics sink.
///
/// The callback must remain best-effort; any buffering it performs is bounded.
typedef DiagnosticEventMirror = void Function(DiagnosticEvent event);

/// Bounded, non-blocking queue between app call sites and segmented TXT.
final class _PersistentDiagnosticEventSink implements DiagnosticEventSink {
  _PersistentDiagnosticEventSink({required this.persistence, required this.configuration}) {
    configuration.validate();
    _dropWindow.start();
  }

  final DiagnosticsPersistence persistence;
  final PersistentDiagnosticsConfiguration configuration;
  final ListQueue<_QueuedDiagnosticEvent> _normalQueue = ListQueue<_QueuedDiagnosticEvent>();
  final ListQueue<_QueuedDiagnosticEvent> _priorityQueue = ListQueue<_QueuedDiagnosticEvent>();
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
  bool isEnabled({required String component, required DiagnosticSeverity severity, required DiagnosticPayloadKind payloadKind}) {
    if (_closing || _closed) return false;
    if (severity == DiagnosticSeverity.trace && !configuration.traceComponents.contains(component)) {
      return false;
    }
    if (severity.index < configuration.minimumSeverity.index) return false;
    return payloadKind == DiagnosticPayloadKind.metadataOnly || captureEnabledResolver?.call(component) == true;
  }

  @override
  bool add(DiagnosticEvent rawEvent) {
    if (_closing || _closed) return false;
    final activeSessionId = activeSessionResolver?.call(rawEvent);
    final event = rawEvent.captureSessionId == null && activeSessionId != null
        ? rawEvent.copyWith(captureSessionId: activeSessionId)
        : rawEvent;
    _mirror(event);
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
      final normalEventLimit = configuration.maxQueueEvents - configuration.priorityReservedEvents;
      final normalByteLimit = configuration.maxQueueBytes - configuration.priorityReservedBytes;
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

  void _mirror(DiagnosticEvent event) {
    final mirror = configuration.eventMirror;
    if (mirror == null) return;
    try {
      mirror(event);
    } on Object {
      // Live developer output is not allowed to affect application behavior.
    }
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

  bool _fitsPriority(int bytes) => _queueDepth < configuration.maxQueueEvents && _queueBytes + bytes <= configuration.maxQueueBytes;

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
            persistence.lastEncoderWorkerIsolateIdForTest != Isolate.current.hashCode;
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
    if (_normalQueue.first.event.sourceSequence < _priorityQueue.first.event.sourceSequence) {
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

  int _estimateBytes(DiagnosticEvent event) => 512 + event.summary.length * 2 + event.attributes.encodedByteLength;
}

final class _QueuedDiagnosticEvent {
  const _QueuedDiagnosticEvent(this.event, this.estimatedBytes);

  final DiagnosticEvent event;
  final int estimatedBytes;
}

/// App-side facade combining manager, segmented TXT, debug details and ports.
