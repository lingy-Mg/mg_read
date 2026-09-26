/// 调试日志查看器的强类型查询与捕获网关。
///
/// 职责：
/// - 将 App 的元数据文件列表和单文件按需读取映射为页面数据。
/// - 内存排查仅开启有界元数据，不初始化文件服务；保存时显式捕获附件。
/// - 网关拥有临时捕获及到期计时器；跨页面复现不终止记录，应用销毁时清理。
///
/// 注意：
/// - Runtime 的旧结构化事件 Facade 已移除；实时日志由 Runtime Debug 检查页提供。
///
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mg_read/core/diagnostics/diagnostics.dart';

enum DiagnosticsViewerSource { app }

enum DiagnosticsDetailMode { off, memoryOnly, persistToText }

@immutable
final class DiagnosticsViewerEvent {
  const DiagnosticsViewerEvent({
    required this.source,
    required this.eventId,
    required this.component,
    required this.eventName,
    required this.summary,
    required this.severity,
    required this.phase,
    required this.occurredAtUtcMicros,
    required this.attachmentCount,
    required this.capturedBytes,
    required this.logFileId,
    this.outcome,
    this.durationMicros,
  });

  final int attachmentCount;
  final int capturedBytes;
  final String component;
  final int? durationMicros;
  final String eventId;
  final String eventName;
  final int occurredAtUtcMicros;
  final String? outcome;
  final String phase;
  final String severity;
  final DiagnosticsViewerSource source;
  final String summary;
  final String logFileId;

  String get identity => '${source.name}:$eventId';
}

@immutable
final class DiagnosticsViewerLogFile {
  const DiagnosticsViewerLogFile({
    required this.fileId,
    required this.startedAtUtcMicros,
    required this.modifiedAtUtcMicros,
    required this.storedBytes,
    required this.isCurrent,
    this.isLive = false,
  });

  final String fileId;
  final int startedAtUtcMicros;
  final int modifiedAtUtcMicros;
  final int storedBytes;
  final bool isCurrent;
  final bool isLive;
}

@immutable
final class DiagnosticsViewerAttachment {
  const DiagnosticsViewerAttachment({
    required this.source,
    required this.attachmentId,
    required this.kind,
    required this.mediaType,
    required this.captureState,
    required this.rawByteLength,
    required this.storedByteLength,
    required this.logFileId,
    this.truncationReason,
  });

  final String attachmentId;
  final String captureState;
  final String kind;
  final String mediaType;
  final int rawByteLength;
  final DiagnosticsViewerSource source;
  final int storedByteLength;
  final String? truncationReason;
  final String logFileId;

  String get identity => '${source.name}:$attachmentId';
}

@immutable
final class DiagnosticsViewerEventDetails {
  const DiagnosticsViewerEventDetails({required this.attributesText, required this.attachments});

  final List<DiagnosticsViewerAttachment> attachments;
  final String attributesText;
}

@immutable
final class DiagnosticsViewerEventPage {
  const DiagnosticsViewerEventPage({required this.items, this.nextCursor});

  final List<DiagnosticsViewerEvent> items;
  final String? nextCursor;
}

@immutable
final class DiagnosticsViewerCapture {
  const DiagnosticsViewerCapture({
    required this.mode,
    required this.source,
    required this.expiresAtUtcMicros,
    this.appSessionId,
    this.warningCode,
  });

  final String? appSessionId;
  final int expiresAtUtcMicros;
  final DiagnosticsDetailMode mode;
  final DiagnosticsViewerSource source;
  final String? warningCode;
}

abstract interface class DiagnosticsViewerGateway {
  DiagnosticsViewerCapture? get activeCapture;

  Stream<void> watchCaptureChanges();

  Stream<void> watchLiveEvents();

  Future<List<DiagnosticsViewerLogFile>> listLogFiles();

  Future<DiagnosticsViewerEventPage> listEvents({required DiagnosticsViewerSource source, required String logFileId, String? cursor});

  Future<DiagnosticsViewerEventDetails> loadEventDetails(DiagnosticsViewerEvent event);

  Future<String> readAttachmentPreview(DiagnosticsViewerAttachment attachment);

  Future<DiagnosticsViewerCapture> startCapture({required DiagnosticsDetailMode mode, required DiagnosticsViewerSource source});

  Future<void> stopCapture(DiagnosticsViewerCapture capture);

  Future<void> deleteLogFile(String logFileId);

  Future<DiagnosticExportResult> exportLogFile(String logFileId);
}

final diagnosticsViewerGatewayProvider = Provider<DiagnosticsViewerGateway>((Ref ref) {
  final gateway = DefaultDiagnosticsViewerGateway(
    ref.watch(diagnosticsQueryProvider),
    ref.watch(diagnosticsCaptureProvider),
    ref.watch(diagnosticsManagerProvider),
    ref.watch(diagnosticsLogArchiveProvider),
    ref.watch(diagnosticsLiveBufferProvider),
  );
  ref.onDispose(gateway.dispose);
  return gateway;
});

final class DefaultDiagnosticsViewerGateway implements DiagnosticsViewerGateway {
  DefaultDiagnosticsViewerGateway(
    DiagnosticsQuery? appQuery,
    this._appCapture,
    this._diagnostics, [
    DiagnosticsLogArchive? appArchive,
    this._liveBuffer,
  ]) : _appArchive = appArchive ?? (appQuery is DiagnosticsLogArchive ? appQuery as DiagnosticsLogArchive : null);

  static const int _previewBytes = 32 * 1024;
  static const String _liveFileId = 'live-current';
  static const int _livePageSize = 50;
  static const Duration _captureDuration = Duration(minutes: 15);
  static const Set<String> _appDetailComponents = <String>{
    'app.diagnostics',
    'app.persistence',
    'core.content-library',
    'feature.library',
    'feature.plugins',
    'feature.reader',
  };
  final DiagnosticsCapture? _appCapture;
  final DiagnosticsManager _diagnostics;
  final DiagnosticsLogArchive? _appArchive;
  final LiveDiagnosticsBuffer? _liveBuffer;
  final _captureChanges = StreamController<void>.broadcast();
  Timer? _captureTimer;
  DiagnosticsViewerCapture? _activeCapture;
  bool _disposed = false;

  @override
  DiagnosticsViewerCapture? get activeCapture => _activeCapture;

  @override
  Stream<void> watchCaptureChanges() => _captureChanges.stream;

  void dispose() {
    _disposed = true;
    _captureTimer?.cancel();
    final capture = _activeCapture;
    if (capture != null) unawaited(stopCapture(capture).catchError((_) {}));
    unawaited(_captureChanges.close());
  }

  DiagnosticsViewerCapture _activate(DiagnosticsViewerCapture capture) {
    if (_disposed) {
      if (capture.appSessionId case final sessionId?) {
        unawaited(_appCapture?.stopCapture(sessionId).catchError((_) {}));
      }
      throw StateError('diagnostics_disposed');
    }
    _activeCapture = capture;
    _liveBuffer?.setDetailedRecording(true);
    _captureTimer = Timer(_captureDuration, () {
      unawaited(stopCapture(capture).catchError((_) {}));
    });
    _captureChanges.add(null);
    return capture;
  }

  @override
  Stream<void> watchLiveEvents() => _liveBuffer?.changes ?? const Stream<void>.empty();

  @override
  Future<List<DiagnosticsViewerLogFile>> listLogFiles() async {
    final archive = _appArchive;
    final files = archive == null ? const <DiagnosticLogFile>[] : await archive.listLogFiles();
    final live = _liveBuffer;
    return List<DiagnosticsViewerLogFile>.unmodifiable(<DiagnosticsViewerLogFile>[
      if (live != null)
        DiagnosticsViewerLogFile(
          fileId: _liveFileId,
          startedAtUtcMicros: live.startedAtUtcMicros,
          modifiedAtUtcMicros: live.modifiedAtUtcMicros,
          storedBytes: live.storedBytes,
          isCurrent: true,
          isLive: true,
        ),
      ...files.map(
        (file) => DiagnosticsViewerLogFile(
          fileId: file.fileId,
          startedAtUtcMicros: file.startedAtUtcMicros,
          modifiedAtUtcMicros: file.modifiedAtUtcMicros,
          storedBytes: file.storedBytes,
          isCurrent: file.isCurrent,
        ),
      ),
    ]);
  }

  @override
  Future<DiagnosticsViewerEventPage> listEvents({
    required DiagnosticsViewerSource source,
    required String logFileId,
    String? cursor,
  }) async {
    if (logFileId == _liveFileId) return _listLiveEvents(source: source, cursor: cursor);
    final span = _diagnostics.startSpan(
      AppDiagnosticEvents.viewerOperation,
      attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
        'operation': DiagnosticValue.string('events.list'),
        'source': DiagnosticValue.string(source.name),
        'resultState': DiagnosticValue.string('loading'),
      }),
    );
    try {
      final DiagnosticsViewerEventPage result;
      switch (source) {
        case DiagnosticsViewerSource.app:
          final archive = _appArchive;
          if (archive == null) {
            result = const DiagnosticsViewerEventPage(items: <DiagnosticsViewerEvent>[]);
          } else {
            final page = await archive.listLogEvents(logFileId, cursor: cursor == null ? null : DiagnosticCursor(cursor), limit: 20);
            result = DiagnosticsViewerEventPage(
              items: List<DiagnosticsViewerEvent>.unmodifiable(page.items.map((event) => _mapAppEvent(event, logFileId))),
              nextCursor: page.nextCursor?.value,
            );
          }
      }
      span.complete(
        attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
          'operation': DiagnosticValue.string('events.list'),
          'source': DiagnosticValue.string(source.name),
          'resultCount': DiagnosticValue.int64(result.items.length),
          'resultState': DiagnosticValue.string(result.items.isEmpty ? 'empty' : 'content'),
        }),
      );
      return result;
    } on Object catch (error, stackTrace) {
      span.fail(
        attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
          'operation': DiagnosticValue.string('events.list'),
          'source': DiagnosticValue.string(source.name),
          'resultState': DiagnosticValue.string('failure'),
          'errorCode': DiagnosticValue.string(_stableErrorCode(error)),
        }),
      );
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  @override
  Future<DiagnosticsViewerEventDetails> loadEventDetails(DiagnosticsViewerEvent event) async {
    if (event.logFileId == _liveFileId) {
      final liveEvent = _liveBuffer?.findEvent(event.eventId);
      if (liveEvent == null) throw const DiagnosticsViewerException('diagnostic_event_expired');
      return DiagnosticsViewerEventDetails(attributesText: _prettyJson(liveEvent.attributes.toWireValue()), attachments: const []);
    }
    final span = _diagnostics.startSpan(
      AppDiagnosticEvents.viewerOperation,
      attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
        'operation': DiagnosticValue.string('event.get'),
        'source': DiagnosticValue.string(event.source.name),
        'resultState': DiagnosticValue.string('loading'),
      }),
    );
    try {
      final DiagnosticsViewerEventDetails result;
      switch (event.source) {
        case DiagnosticsViewerSource.app:
          final archive = _appArchive;
          if (archive == null) throw StateError('app_diagnostics_unavailable');
          final detail = await archive.getLogEvent(event.logFileId, event.eventId);
          if (detail == null) throw StateError('diagnostic_event_not_found');
          final attachments = await archive.listLogAttachments(event.logFileId, event.eventId);
          result = DiagnosticsViewerEventDetails(
            attributesText: _prettyJson(detail.attributes.toWireValue()),
            attachments: List<DiagnosticsViewerAttachment>.unmodifiable(
              attachments.map((attachment) => _mapAppAttachment(attachment, event.logFileId)),
            ),
          );
      }
      span.complete(
        attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
          'operation': DiagnosticValue.string('event.get'),
          'source': DiagnosticValue.string(event.source.name),
          'resultCount': DiagnosticValue.int64(result.attachments.length),
          'resultState': DiagnosticValue.string('content'),
        }),
      );
      return result;
    } on Object catch (error, stackTrace) {
      span.fail(
        attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
          'operation': DiagnosticValue.string('event.get'),
          'source': DiagnosticValue.string(event.source.name),
          'resultState': DiagnosticValue.string('failure'),
          'errorCode': DiagnosticValue.string(_stableErrorCode(error)),
        }),
      );
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  @override
  Future<String> readAttachmentPreview(DiagnosticsViewerAttachment attachment) async {
    final span = _diagnostics.startSpan(
      AppDiagnosticEvents.viewerOperation,
      attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
        'operation': DiagnosticValue.string('attachment.preview'),
        'source': DiagnosticValue.string(attachment.source.name),
        'resultState': DiagnosticValue.string('loading'),
      }),
    );
    try {
      final List<int> bytes;
      switch (attachment.source) {
        case DiagnosticsViewerSource.app:
          final archive = _appArchive;
          if (archive == null) throw StateError('app_diagnostics_unavailable');
          final output = <int>[];
          await for (final chunk in archive.openLogAttachment(
            attachment.logFileId,
            attachment.attachmentId,
            range: DiagnosticByteRange(offset: 0, length: _previewBytes),
          )) {
            final remaining = _previewBytes - output.length;
            if (remaining <= 0) break;
            output.addAll(chunk.length <= remaining ? chunk : chunk.take(remaining));
          }
          bytes = output;
      }
      final preview = utf8.decode(bytes, allowMalformed: true);
      span.complete(
        attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
          'operation': DiagnosticValue.string('attachment.preview'),
          'source': DiagnosticValue.string(attachment.source.name),
          'bytes': DiagnosticValue.int64(bytes.length),
          'resultState': DiagnosticValue.string('content'),
        }),
      );
      return preview;
    } on Object catch (error, stackTrace) {
      span.fail(
        attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
          'operation': DiagnosticValue.string('attachment.preview'),
          'source': DiagnosticValue.string(attachment.source.name),
          'resultState': DiagnosticValue.string('failure'),
          'errorCode': DiagnosticValue.string(_stableErrorCode(error)),
        }),
      );
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  @override
  Future<DiagnosticsViewerCapture> startCapture({required DiagnosticsDetailMode mode, required DiagnosticsViewerSource source}) async {
    if (_disposed || _activeCapture != null) throw StateError('capture_unavailable');
    if (mode == DiagnosticsDetailMode.off) {
      throw ArgumentError.value(mode, 'mode', 'Capture mode cannot be off.');
    }
    if (mode == DiagnosticsDetailMode.memoryOnly && _liveBuffer != null) {
      return _activate(
        DiagnosticsViewerCapture(
          mode: mode,
          source: source,
          expiresAtUtcMicros: DateTime.now().toUtc().add(_captureDuration).microsecondsSinceEpoch,
        ),
      );
    }
    final maxBytes = mode == DiagnosticsDetailMode.memoryOnly ? 8 * 1024 * 1024 : 64 * 1024 * 1024;
    final detailStorage = mode == DiagnosticsDetailMode.memoryOnly
        ? DiagnosticDetailStorage.memoryOnly
        : DiagnosticDetailStorage.persistToText;
    switch (source) {
      case DiagnosticsViewerSource.app:
        final capture = _appCapture;
        if (capture == null) {
          throw const DiagnosticsViewerException('app_diagnostics_unavailable');
        }
        try {
          final session = await capture.startCapture(
            DiagnosticCapturePolicy(
              payloadKind: DiagnosticPayloadKind.contentPayload,
              detailStorage: detailStorage,
              duration: _captureDuration,
              maxStoredBytes: maxBytes,
              components: _appDetailComponents,
            ),
          );
          return _activate(
            DiagnosticsViewerCapture(
              mode: mode,
              source: source,
              appSessionId: session.sessionId,
              expiresAtUtcMicros: DateTime.now().toUtc().add(_captureDuration).microsecondsSinceEpoch,
            ),
          );
        } on Object catch (error, stackTrace) {
          Error.throwWithStackTrace(DiagnosticsViewerException(_stableErrorCode(error)), stackTrace);
        }
    }
  }

  @override
  Future<void> stopCapture(DiagnosticsViewerCapture capture) async {
    if (!identical(_activeCapture, capture)) return;
    _activeCapture = null;
    _captureTimer?.cancel();
    _liveBuffer?.setDetailedRecording(false);
    if (!_captureChanges.isClosed) _captureChanges.add(null);
    Object? firstError;
    if (capture.appSessionId case final sessionId?) {
      try {
        await _appCapture?.stopCapture(sessionId);
      } on Object catch (error) {
        firstError = error;
      }
    }
    if (firstError != null) throw firstError;
  }

  @override
  Future<void> deleteLogFile(String logFileId) async {
    if (logFileId == _liveFileId) throw const DiagnosticsViewerException('live_log_not_deletable');
    final archive = _appArchive;
    if (archive == null) throw const DiagnosticsViewerException('app_diagnostics_unavailable');
    await archive.deleteLogFile(logFileId);
  }

  @override
  Future<DiagnosticExportResult> exportLogFile(String logFileId) async {
    if (logFileId == _liveFileId) throw const DiagnosticsViewerException('live_log_not_exportable');
    final archive = _appArchive;
    if (archive == null) throw const DiagnosticsViewerException('app_diagnostics_unavailable');
    return archive.exportLogFile(logFileId);
  }

  DiagnosticsViewerEventPage _listLiveEvents({required DiagnosticsViewerSource source, String? cursor}) {
    final live = _liveBuffer;
    if (live == null) return const DiagnosticsViewerEventPage(items: <DiagnosticsViewerEvent>[]);
    final beforeSequence = cursor == null ? null : _decodeLiveCursor(cursor);
    final events = live.snapshot(beforeSourceSequence: beforeSequence, limit: _livePageSize + 1);
    final hasMore = events.length > _livePageSize;
    final visible = hasMore ? events.take(_livePageSize).toList(growable: false) : events;
    return DiagnosticsViewerEventPage(
      items: List<DiagnosticsViewerEvent>.unmodifiable(visible.map((event) => _mapAppEvent(event, _liveFileId))),
      nextCursor: hasMore ? _encodeLiveCursor(visible.last.sourceSequence) : null,
    );
  }
}

String _encodeLiveCursor(int sourceSequence) => 'live_${sourceSequence.toRadixString(16).padLeft(16, '0')}';

int _decodeLiveCursor(String cursor) {
  if (!RegExp(r'^live_[a-f0-9]{16}$').hasMatch(cursor)) throw const DiagnosticsViewerException('invalid_cursor');
  return int.parse(cursor.substring(5), radix: 16);
}

DiagnosticsViewerEvent _mapAppEvent(DiagnosticEvent event, String logFileId) => DiagnosticsViewerEvent(
  source: DiagnosticsViewerSource.app,
  eventId: event.eventId,
  component: event.component,
  eventName: event.eventName,
  summary: event.summary,
  severity: event.severity.name,
  phase: event.phase.name,
  outcome: event.outcome?.name,
  occurredAtUtcMicros: event.occurredAtUtcMicros,
  durationMicros: event.durationMicros,
  attachmentCount: event.attachmentCount,
  capturedBytes: event.capturedBytes,
  logFileId: logFileId,
);

DiagnosticsViewerAttachment _mapAppAttachment(DiagnosticAttachmentDescriptor attachment, String logFileId) => DiagnosticsViewerAttachment(
  source: DiagnosticsViewerSource.app,
  attachmentId: attachment.attachmentId,
  kind: attachment.kind,
  mediaType: attachment.mediaType,
  captureState: attachment.captureState.name,
  rawByteLength: attachment.rawByteLength,
  storedByteLength: attachment.storedByteLength,
  truncationReason: attachment.truncationReason,
  logFileId: logFileId,
);

String _prettyJson(Object? value) => const JsonEncoder.withIndent('  ').convert(value);

String _stableErrorCode(Object error) {
  if (error is StateError) return 'invalid_state';
  if (error is ArgumentError) return 'invalid_argument';
  if (error is TimeoutException) return 'timeout';
  return 'internal_error';
}

/// Stable diagnostic viewer failure.
final class DiagnosticsViewerException implements Exception {
  const DiagnosticsViewerException(this.code);

  final String code;
}
