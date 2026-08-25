/// 调试日志查看器的强类型查询与捕获网关。
///
/// 职责：
/// - 将 App 的受限诊断读取映射为页面数据。
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

  String get identity => '${source.name}:$eventId';
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
  Future<DiagnosticsViewerEventPage> listEvents({required DiagnosticsViewerSource source, String? cursor});

  Future<DiagnosticsViewerEventDetails> loadEventDetails(DiagnosticsViewerEvent event);

  Future<String> readAttachmentPreview(DiagnosticsViewerAttachment attachment);

  Future<DiagnosticsViewerCapture> startCapture({required DiagnosticsDetailMode mode, required DiagnosticsViewerSource source});

  Future<void> stopCapture(DiagnosticsViewerCapture capture);
}

final diagnosticsViewerGatewayProvider = Provider<DiagnosticsViewerGateway>(
  (Ref ref) => DefaultDiagnosticsViewerGateway(
    ref.watch(diagnosticsQueryProvider),
    ref.watch(diagnosticsCaptureProvider),
    ref.watch(diagnosticsManagerProvider),
  ),
);

final class DefaultDiagnosticsViewerGateway implements DiagnosticsViewerGateway {
  DefaultDiagnosticsViewerGateway(this._appQuery, this._appCapture, this._diagnostics);

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
  final DiagnosticsQuery? _appQuery;
  final DiagnosticsManager _diagnostics;

  @override
  Future<DiagnosticsViewerEventPage> listEvents({required DiagnosticsViewerSource source, String? cursor}) async {
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
          final query = _appQuery;
          if (query == null) {
            result = const DiagnosticsViewerEventPage(items: <DiagnosticsViewerEvent>[]);
          } else {
            final page = await query.listEvents(
              filter: DiagnosticEventFilter(),
              cursor: cursor == null ? null : DiagnosticCursor(cursor),
              limit: 20,
            );
            result = DiagnosticsViewerEventPage(
              items: List<DiagnosticsViewerEvent>.unmodifiable(page.items.map(_mapAppEvent)),
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
          final query = _appQuery;
          if (query == null) throw StateError('app_diagnostics_unavailable');
          final detail = await query.getEvent(event.eventId);
          if (detail == null) throw StateError('diagnostic_event_not_found');
          final attachments = await query.listAttachments(event.eventId);
          result = DiagnosticsViewerEventDetails(
            attributesText: _prettyJson(detail.attributes.toWireValue()),
            attachments: List<DiagnosticsViewerAttachment>.unmodifiable(attachments.map(_mapAppAttachment)),
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
          final query = _appQuery;
          if (query == null) throw StateError('app_diagnostics_unavailable');
          final output = <int>[];
          await for (final chunk in query.openAttachment(
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
}

DiagnosticsViewerEvent _mapAppEvent(DiagnosticEvent event) => DiagnosticsViewerEvent(
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
);

DiagnosticsViewerAttachment _mapAppAttachment(DiagnosticAttachmentDescriptor attachment) => DiagnosticsViewerAttachment(
  source: DiagnosticsViewerSource.app,
  attachmentId: attachment.attachmentId,
  kind: attachment.kind,
  mediaType: attachment.mediaType,
  captureState: attachment.captureState.name,
  rawByteLength: attachment.rawByteLength,
  storedByteLength: attachment.storedByteLength,
  truncationReason: attachment.truncationReason,
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
