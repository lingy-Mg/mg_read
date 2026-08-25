import 'dart:async';
import 'dart:collection';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/core/errors/app_error.dart';

/// Immutable, user-copyable projection of a fatal application diagnostic.
///
/// This deliberately has no exception, stack, URL, content, path, or secret
/// fields. The fingerprint is computed before the report is enqueued.
final class AppFatalDiagnosticReport {
  const AppFatalDiagnosticReport({
    required this.errorCode,
    required this.traceId,
    required this.stackFingerprint,
    required this.phase,
    required this.runtimeState,
    required this.diagnosticsMarker,
  });

  /// A small controlled lifecycle phase, never an exception-derived value.
  final String phase;

  /// A controlled Runtime health projection, never a launcher detail.
  final String runtimeState;

  /// Signals that Runtime retained bounded safe diagnostics for this failure.
  final String diagnosticsMarker;
  final String errorCode;
  final String traceId;
  final String stackFingerprint;

  String get copyPayload =>
      'MgRead 诊断报告\n'
      '错误代码: $errorCode\n'
      '追踪 ID: $traceId\n'
      '堆栈指纹: $stackFingerprint\n'
      '阶段: $phase\n'
      'Runtime 状态: $runtimeState\n'
      '诊断标记: $diagnosticsMarker';
}

/// Process-scoped, fail-open bridge from fatal app boundaries to the root UI.
///
/// Callers provide stable codes and a [StackTrace] only for fingerprinting.
/// They must never pass an exception or Runtime transport object here.
final class AppFatalErrorReporter {
  AppFatalErrorReporter(this._diagnostics);

  final DiagnosticsManager _diagnostics;
  final StreamController<AppFatalDiagnosticReport> _reports =
      StreamController<AppFatalDiagnosticReport>.broadcast(sync: true);
  final Queue<AppFatalDiagnosticReport> _pending =
      Queue<AppFatalDiagnosticReport>();
  bool _disposed = false;

  Stream<AppFatalDiagnosticReport> get reports => _reports.stream;

  bool get hasPendingReports => _pending.isNotEmpty;

  AppFatalDiagnosticReport? takeNextReport() =>
      _pending.isEmpty ? null : _pending.removeFirst();

  /// Records and queues an uncaught Flutter or platform boundary failure.
  void reportUnhandled({
    required String boundary,
    required String errorCode,
    required StackTrace stackTrace,
    required bool fatal,
  }) {
    final traceId = _newOpaqueId('trace', 'fataltraceunavailable');
    final spanId = _newOpaqueId('span', 'fatalspanunavailable');
    final fingerprint = _stackFingerprint(stackTrace);
    try {
      _diagnostics.emit(
        AppDiagnosticEvents.unhandledError,
        traceContext: DiagnosticTraceContext(traceId: traceId, spanId: spanId),
        attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
          'boundary': DiagnosticValue.string(boundary),
          'errorCode': DiagnosticValue.string(errorCode),
          'stackFingerprint': DiagnosticValue.string(fingerprint),
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
          traceId: traceId,
          stackFingerprint: fingerprint,
          phase: 'unhandled',
          runtimeState: 'not_applicable',
          diagnosticsMarker: 'app_boundary_recorded',
        ),
      );
    }
  }

  /// Queues only Runtime-wide failures observed by the startup application
  /// layer. Ordinary source capability failures stay with their local UI.
  void reportFatalRuntimeFailure(AppError error, StackTrace stackTrace) {
    if (!isFatalRuntimeFailure(error)) return;
    final traceId =
        _validatedTraceId(error.traceId) ??
        _newOpaqueId('trace', 'fataltraceunavailable');
    final spanId = _newOpaqueId('span', 'fatalspanunavailable');
    final fingerprint = _stackFingerprint(stackTrace);
    try {
      _diagnostics.emit(
        AppDiagnosticEvents.unhandledError,
        traceContext: DiagnosticTraceContext(traceId: traceId, spanId: spanId),
        severity: DiagnosticSeverity.fatal,
        attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
          'boundary': DiagnosticValue.string('runtime-warmup'),
          'errorCode': DiagnosticValue.string(error.code.wireValue),
          'stackFingerprint': DiagnosticValue.string(fingerprint),
          'fatal': DiagnosticValue.boolean(true),
        }),
      );
    } catch (_) {
      // Diagnostics persistence must not change Runtime recovery behavior.
    }
    _enqueue(
      AppFatalDiagnosticReport(
        errorCode: error.code.wireValue,
        traceId: traceId,
        stackFingerprint: fingerprint,
        phase: 'runtime_facade',
        runtimeState: _runtimeStateFor(error),
        diagnosticsMarker: 'runtime_failure_observed',
      ),
    );
  }

  /// Accepts only application-owned, allowlisted projections of Runtime
  /// diagnostics. The caller must never forward the Runtime diagnostic text.
  void reportFatalRuntimeDiagnostic({
    required String errorCode,
    required String phase,
    required String runtimeState,
  }) {
    final safeErrorCode = _runtimeDiagnosticCodes.contains(errorCode)
        ? errorCode
        : 'runtime_unavailable';
    final safePhase = _runtimePhases.contains(phase)
        ? phase
        : 'runtime_lifecycle';
    final safeRuntimeState = _runtimeStates.contains(runtimeState)
        ? runtimeState
        : 'unavailable';
    final traceId = _newOpaqueId('trace', 'fataltraceunavailable');
    final spanId = _newOpaqueId('span', 'fatalspanunavailable');
    final fingerprint = _stackFingerprint(StackTrace.empty);
    try {
      _diagnostics.emit(
        AppDiagnosticEvents.unhandledError,
        traceContext: DiagnosticTraceContext(traceId: traceId, spanId: spanId),
        severity: DiagnosticSeverity.fatal,
        attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
          'boundary': DiagnosticValue.string('runtime-observer'),
          'errorCode': DiagnosticValue.string(safeErrorCode),
          'stackFingerprint': DiagnosticValue.string(fingerprint),
          'fatal': DiagnosticValue.boolean(true),
        }),
      );
    } catch (_) {
      // Diagnostics persistence must not change Runtime recovery behavior.
    }
    _enqueue(
      AppFatalDiagnosticReport(
        errorCode: safeErrorCode,
        traceId: traceId,
        stackFingerprint: fingerprint,
        phase: safePhase,
        runtimeState: safeRuntimeState,
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

  static const Set<String> _runtimeDiagnosticCodes = <String>{
    'runtime_process_exited',
    'runtime_start_failed',
    'runtime_not_ready',
    'runtime_unavailable',
  };
  static const Set<String> _runtimePhases = <String>{
    'runtime_facade',
    'runtime_startup',
    'runtime_lifecycle',
  };
  static const Set<String> _runtimeStates = <String>{
    'startup_failed',
    'not_ready',
    'exited',
    'unavailable',
    'disconnected',
    'incompatible',
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

  String _stackFingerprint(StackTrace stackTrace) {
    try {
      return _diagnostics.privacyPolicy.stackFingerprint(stackTrace);
    } catch (_) {
      return 'fingerprintunavailable';
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
