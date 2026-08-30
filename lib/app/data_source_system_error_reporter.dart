import 'dart:async';
import 'dart:collection';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/core/diagnostics/diagnostics.dart';

/// Copyable projection of the Runtime startup-recovery result supplied to the
/// application layer.
final class DataSourceSystemDiagnosticReport {
  const DataSourceSystemDiagnosticReport({
    required this.errorCode,
    required this.quarantinedCount,
    required this.traceId,
    required this.diagnosticsMarker,
  });

  final String errorCode;
  final int quarantinedCount;
  final String traceId;
  final String diagnosticsMarker;

  String get copyPayload =>
      'MgRead 数据源系统诊断报告\n'
      '错误代码: $errorCode\n'
      '已隔离数据源数量: $quarantinedCount\n'
      '追踪 ID: $traceId\n'
      '诊断标记: $diagnosticsMarker';
}

/// Delivers a non-fatal Runtime recovery notice to the dedicated root dialog.
final class DataSourceSystemErrorReporter {
  DataSourceSystemErrorReporter(this._diagnostics);

  final DiagnosticsManager _diagnostics;
  final StreamController<DataSourceSystemDiagnosticReport> _reports = StreamController<DataSourceSystemDiagnosticReport>.broadcast(
    sync: true,
  );
  final Queue<DataSourceSystemDiagnosticReport> _pending = Queue<DataSourceSystemDiagnosticReport>();
  bool _disposed = false;

  Stream<DataSourceSystemDiagnosticReport> get reports => _reports.stream;

  bool get hasPendingReports => _pending.isNotEmpty;

  DataSourceSystemDiagnosticReport? takeNextReport() => _pending.isEmpty ? null : _pending.removeFirst();

  void reportQuarantinedSources({required int quarantinedCount}) {
    if (_disposed || quarantinedCount <= 0) return;
    final traceId = _newTraceId();
    const errorCode = 'plugin_load_failed';
    try {
      _diagnostics.emit(
        AppDiagnosticEvents.unhandledError,
        traceContext: DiagnosticTraceContext(traceId: traceId, spanId: _diagnostics.idGenerator.nextId('datasourceerror')),
        severity: DiagnosticSeverity.error,
        attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
          'boundary': DiagnosticValue.string('data-source-startup-recovery'),
          'errorCode': DiagnosticValue.string(errorCode),
          'stackTrace': DiagnosticValue.string(StackTrace.current.toString()),
          'fatal': DiagnosticValue.boolean(false),
        }),
      );
    } catch (_) {
      // Error presentation must not alter the isolated Runtime recovery path.
    }
    _enqueue(
      DataSourceSystemDiagnosticReport(
        errorCode: errorCode,
        quarantinedCount: quarantinedCount,
        traceId: traceId,
        diagnosticsMarker: 'runtime_source_quarantined',
      ),
    );
  }

  void reportDevelopmentReloadFailure({required String errorCode}) {
    if (_disposed) return;
    final traceId = _newTraceId();
    try {
      _diagnostics.emit(
        AppDiagnosticEvents.unhandledError,
        traceContext: DiagnosticTraceContext(traceId: traceId, spanId: _diagnostics.idGenerator.nextId('datasourceerror')),
        severity: DiagnosticSeverity.error,
        attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
          'boundary': DiagnosticValue.string('data-source-development-reload'),
          'errorCode': DiagnosticValue.string(errorCode),
          'fatal': DiagnosticValue.boolean(false),
        }),
      );
    } catch (_) {
      // Error presentation must not alter the retained active generation.
    }
    _enqueue(
      DataSourceSystemDiagnosticReport(
        errorCode: errorCode,
        quarantinedCount: 0,
        traceId: traceId,
        diagnosticsMarker: 'runtime_source_development_reload_failed',
      ),
    );
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _pending.clear();
    unawaited(_reports.close());
  }

  String _newTraceId() {
    try {
      return _diagnostics.idGenerator.nextId('datasourcetrace');
    } catch (_) {
      return 'datasourcetraceunavailable';
    }
  }

  void _enqueue(DataSourceSystemDiagnosticReport report) {
    if (_disposed) return;
    try {
      _pending.addLast(report);
      _reports.add(report);
    } catch (_) {
      // The dialog is best effort after Runtime recovery has completed.
    }
  }
}

final dataSourceSystemErrorReporterProvider = Provider<DataSourceSystemErrorReporter>((Ref ref) {
  final reporter = DataSourceSystemErrorReporter(ref.watch(diagnosticsManagerProvider));
  ref.onDispose(reporter.dispose);
  return reporter;
});
