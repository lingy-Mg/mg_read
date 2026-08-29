/// 调试日志查看器的强类型查询与捕获网关。
///
/// 职责：
/// - 将 App 的元数据文件列表和单文件按需读取映射为页面数据。
/// - 创建和停止有时限的 App 详情捕获会话。
///
/// 注意：
/// - Runtime 的旧结构化事件 Facade 已移除；实时日志由 Runtime Debug 检查页提供。
///
/// TODO:
/// - 无。
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
  });

  final String fileId;
  final int startedAtUtcMicros;
  final int modifiedAtUtcMicros;
  final int storedBytes;
  final bool isCurrent;
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
  Future<List<DiagnosticsViewerLogFile>> listLogFiles();

  Future<DiagnosticsViewerEventPage> listEvents({required DiagnosticsViewerSource source, required String logFileId, String? cursor});

  Future<DiagnosticsViewerEventDetails> loadEventDetails(DiagnosticsViewerEvent event);

  Future<String> readAttachmentPreview(DiagnosticsViewerAttachment attachment);

  Future<DiagnosticsViewerCapture> startCapture({required DiagnosticsDetailMode mode, required DiagnosticsViewerSource source});

  Future<void> stopCapture(DiagnosticsViewerCapture capture);

  Future<void> deleteLogFile(String logFileId);

  Future<DiagnosticExportResult> exportLogFile(String logFileId);
}

final diagnosticsViewerGatewayProvider = Provider<DiagnosticsViewerGateway>(
  (Ref ref) => DefaultDiagnosticsViewerGateway(
    ref.watch(diagnosticsQueryProvider),
    ref.watch(diagnosticsCaptureProvider),
    ref.watch(diagnosticsManagerProvider),
    ref.watch(diagnosticsLogArchiveProvider),
  ),
);

final class DefaultDiagnosticsViewerGateway implements DiagnosticsViewerGateway {
  DefaultDiagnosticsViewerGateway(DiagnosticsQuery? appQuery, this._appCapture, this._diagnostics, [DiagnosticsLogArchive? appArchive])
    : _appArchive = appArchive ?? (appQuery is DiagnosticsLogArchive ? appQuery as DiagnosticsLogArchive : null);

  static const int _previewBytes = 32 * 1024;
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

  @override
  Future<List<DiagnosticsViewerLogFile>> listLogFiles() async {
    final archive = _appArchive;
    if (archive == null) return const <DiagnosticsViewerLogFile>[];
    final files = await archive.listLogFiles();
    return List<DiagnosticsViewerLogFile>.unmodifiable(
      files.map(
        (file) => DiagnosticsViewerLogFile(
          fileId: file.fileId,
          startedAtUtcMicros: file.startedAtUtcMicros,
          modifiedAtUtcMicros: file.modifiedAtUtcMicros,
          storedBytes: file.storedBytes,
          isCurrent: file.isCurrent,
        ),
      ),
    );
  }

  @override
  Future<DiagnosticsViewerEventPage> listEvents({
    required DiagnosticsViewerSource source,
    required String logFileId,
    String? cursor,
  }) async {
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
    if (mode == DiagnosticsDetailMode.off) {
      throw ArgumentError.value(mode, 'mode', 'Capture mode cannot be off.');
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
          return DiagnosticsViewerCapture(
            mode: mode,
            source: source,
            appSessionId: session.sessionId,
            expiresAtUtcMicros: DateTime.now().toUtc().add(_captureDuration).microsecondsSinceEpoch,
          );
        } on Object catch (error, stackTrace) {
          Error.throwWithStackTrace(DiagnosticsViewerException(_stableErrorCode(error)), stackTrace);
        }
    }
  }

  @override
  Future<void> stopCapture(DiagnosticsViewerCapture capture) async {
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
    final archive = _appArchive;
    if (archive == null) throw const DiagnosticsViewerException('app_diagnostics_unavailable');
    await archive.deleteLogFile(logFileId);
  }

  @override
  Future<DiagnosticExportResult> exportLogFile(String logFileId) async {
    final archive = _appArchive;
    if (archive == null) throw const DiagnosticsViewerException('app_diagnostics_unavailable');
    return archive.exportLogFile(logFileId);
  }
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

/// Stable, user-safe diagnostic viewer failure.
final class DiagnosticsViewerException implements Exception {
  const DiagnosticsViewerException(this.code);

  final String code;
}
