import 'dart:async';
import 'dart:collection';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/core/errors/app_error.dart';

/// Immutable, user-copyable projection of a fatal application diagnostic.
///
/// Values supplied by the reporting boundary are kept unchanged.
final class AppFatalDiagnosticReport {
  const AppFatalDiagnosticReport({
    required this.errorCode,
    required this.errorText,
    required this.traceId,
    required this.stackTrace,
    required this.phase,
    required this.runtimeState,
    required this.diagnosticsMarker,
  });

  /// A small controlled lifecycle phase, never an exception-derived value.
  final String phase;

  /// A controlled Runtime health projection, never a launcher detail.
  final String runtimeState;

  /// Signals that Runtime retained bounded diagnostics for this failure.
  final String diagnosticsMarker;
  final String errorCode;
  final String errorText;
  final String traceId;
  final String stackTrace;

  String get copyPayload =>
      'MgRead 诊断报告\n'
      '错误代码: $errorCode\n'
      '错误内容: $errorText\n'
      '追踪 ID: $traceId\n'
      '堆栈: $stackTrace\n'
      '阶段: $phase\n'
      'Runtime 状态: $runtimeState\n'
      '诊断标记: $diagnosticsMarker';
}

/// Process-scoped, fail-open bridge from fatal app boundaries to the root UI.
///
/// Callers provide stable codes plus the original error text and [StackTrace].
final class AppFatalErrorReporter {
  AppFatalErrorReporter(this._diagnostics);

  final DiagnosticsManager _diagnostics;
  final StreamController<AppFatalDiagnosticReport> _reports = StreamController<AppFatalDiagnosticReport>.broadcast(sync: true);
  final Queue<AppFatalDiagnosticReport> _pending = Queue<AppFatalDiagnosticReport>();
  bool _disposed = false;

  Stream<AppFatalDiagnosticReport> get reports => _reports.stream;

  bool get hasPendingReports => _pending.isNotEmpty;

  AppFatalDiagnosticReport? takeNextReport() => _pending.isEmpty ? null : _pending.removeFirst();

  /// Records and queues an uncaught Flutter or platform boundary failure.
  void reportUnhandled({
    required String boundary,
    required String errorCode,
    required String errorText,
    required StackTrace stackTrace,
    required bool fatal,
  }) {
    final traceId = _newOpaqueId('trace', 'fataltraceunavailable');
    final spanId = _newOpaqueId('span', 'fatalspanunavailable');
    final stackText = stackTrace.toString();
    try {
      _diagnostics.emit(
        AppDiagnosticEvents.unhandledError,
        traceContext: DiagnosticTraceContext(traceId: traceId, spanId: spanId),
        attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
          'boundary': DiagnosticValue.string(boundary),
          'errorCode': DiagnosticValue.string(errorCode),
          'errorText': DiagnosticValue.string(errorText),
          'stackTrace': DiagnosticValue.string(stackText),
          'fatal': DiagnosticValue.boolean(fatal),
        }),
      );
    } catch (_) {
      // Diagnostics persistence must not change error handling.
    }
    if (fatal) {
      _enqueue(
        AppFatalDiagnosticReport(
          errorCode: errorCode,
          errorText: errorText,
          traceId: traceId,
          stackTrace: stackText,
          phase: 'unhandled',
          runtimeState: 'not_applicable',
          diagnosticsMarker: 'app_boundary_recorded',
        ),
      );
    }
  }

  /// Queues only Runtime-wide failures observed by the startup application
  /// layer. Ordinary source capability failures stay with their local UI.
  void reportFatalRuntimeFailure(AppError error, StackTrace stackTrace, {Object? originalError}) {
    if (!isFatalRuntimeFailure(error)) return;
    final traceId = _validatedTraceId(error.traceId) ?? _newOpaqueId('trace', 'fataltraceunavailable');
    final spanId = _newOpaqueId('span', 'fatalspanunavailable');
    final stackText = stackTrace.toString();
    final errorText = (originalError ?? error).toString();
    try {
      _diagnostics.emit(
        AppDiagnosticEvents.unhandledError,
        traceContext: DiagnosticTraceContext(traceId: traceId, spanId: spanId),
        severity: DiagnosticSeverity.fatal,
        attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
          'boundary': DiagnosticValue.string('runtime-warmup'),
          'errorCode': DiagnosticValue.string(error.code.wireValue),
          'errorText': DiagnosticValue.string(errorText),
          'stackTrace': DiagnosticValue.string(stackText),
          'fatal': DiagnosticValue.boolean(true),
        }),
      );
    } catch (_) {
      // Diagnostics persistence must not change Runtime recovery behavior.
    }
    _enqueue(
      AppFatalDiagnosticReport(
        errorCode: error.code.wireValue,
        errorText: errorText,
        traceId: traceId,
        stackTrace: stackText,
        phase: 'runtime_facade',
        runtimeState: _runtimeStateFor(error),
        diagnosticsMarker: 'runtime_failure_observed',
      ),
    );
  }

  /// Records a Runtime-wide diagnostic with its original diagnostic text.
  void reportFatalRuntimeDiagnostic({
    required String errorCode,
    required String diagnosticText,
    required String phase,
    required String runtimeState,
  }) {
    final traceId = _newOpaqueId('trace', 'fataltraceunavailable');
    final spanId = _newOpaqueId('span', 'fatalspanunavailable');
    final stackText = StackTrace.empty.toString();
    try {
      _diagnostics.emit(
        AppDiagnosticEvents.unhandledError,
        traceContext: DiagnosticTraceContext(traceId: traceId, spanId: spanId),
        severity: DiagnosticSeverity.fatal,
        attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
          'boundary': DiagnosticValue.string('runtime-observer'),
          'errorCode': DiagnosticValue.string(errorCode),
          'errorText': DiagnosticValue.string(diagnosticText),
          'stackTrace': DiagnosticValue.string(stackText),
          'fatal': DiagnosticValue.boolean(true),
        }),
      );
    } catch (_) {
      // Diagnostics persistence must not change Runtime recovery behavior.
    }
    _enqueue(
      AppFatalDiagnosticReport(
        errorCode: errorCode,
        errorText: diagnosticText,
        traceId: traceId,
        stackTrace: stackText,
        phase: phase,
        runtimeState: runtimeState,
        diagnosticsMarker: 'runtime_diagnostic_observed',
      ),
    );
  }

  static bool isFatalRuntimeFailure(AppError error) => switch (error.code) {
    AppErrorCode.runtimeUnavailable ||
    AppErrorCode.runtimeStartFailed ||
    AppErrorCode.runtimeNotReady ||
    AppErrorCode.transportDisconnected ||
    AppErrorCode.versionIncompatible => true,
    _ => false,
  };

  static String _runtimeStateFor(AppError error) => switch (error.code) {
    AppErrorCode.runtimeStartFailed => 'startup_failed',
    AppErrorCode.runtimeNotReady => 'not_ready',
    AppErrorCode.transportDisconnected => 'disconnected',
    AppErrorCode.versionIncompatible => 'incompatible',
    _ => 'unavailable',
  };

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _pending.clear();
    unawaited(_reports.close());
  }

  void _enqueue(AppFatalDiagnosticReport report) {
    if (_disposed) return;
    try {
      _pending.addLast(report);
      _reports.add(report);
    } catch (_) {
      // Showing a dialog is best effort while an error is already in flight.
    }
  }

  String _newOpaqueId(String namespace, String fallback) {
    try {
      return _diagnostics.idGenerator.nextId(namespace);
    } catch (_) {
      return fallback;
    }
  }

  String? _validatedTraceId(String? value) {
    if (value == null) return null;
    try {
      validateDiagnosticOpaqueId(value, 'traceId');
      return value;
    } catch (_) {
      return null;
    }
  }
}

final fatalErrorReporterProvider = Provider<AppFatalErrorReporter>((Ref ref) {
  final reporter = AppFatalErrorReporter(ref.watch(diagnosticsManagerProvider));
  ref.onDispose(reporter.dispose);
  return reporter;
});
