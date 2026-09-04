import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/core/diagnostics/diagnostics.dart';

/// One source failure retained inside a user-facing recovery report.
final class DataSourceSystemDiagnosticFailure {
  const DataSourceSystemDiagnosticFailure({
    required this.errorCode,
    required this.traceId,
    required this.diagnosticsMarker,
    this.pluginId,
    this.pluginName,
    this.buildOutput,
  });

  final String errorCode;
  final String traceId;
  final String diagnosticsMarker;
  final String? pluginId;
  final String? pluginName;
  final String? buildOutput;

  String get displayName => pluginName ?? pluginId ?? '未命名数据源';
}

/// Copyable projection of the Runtime startup-recovery result supplied to the
/// application layer.
final class DataSourceSystemDiagnosticReport {
  DataSourceSystemDiagnosticReport({
    required this.errorCode,
    required this.quarantinedCount,
    required this.traceId,
    required this.diagnosticsMarker,
    this.pluginId,
    this.pluginName,
    this.buildOutput,
    Iterable<DataSourceSystemDiagnosticFailure>? failures,
  }) : failures = List<DataSourceSystemDiagnosticFailure>.unmodifiable(
         failures ??
             <DataSourceSystemDiagnosticFailure>[
               DataSourceSystemDiagnosticFailure(
                 errorCode: errorCode,
                 traceId: traceId,
                 diagnosticsMarker: diagnosticsMarker,
                 pluginId: pluginId,
                 pluginName: pluginName,
                 buildOutput: buildOutput,
               ),
             ],
       );

  factory DataSourceSystemDiagnosticReport.mergeDevelopment(Iterable<DataSourceSystemDiagnosticReport> reports) {
    final values = List<DataSourceSystemDiagnosticReport>.of(reports);
    if (values.isEmpty) throw ArgumentError.value(reports, 'reports', 'At least one report is required.');
    final first = values.first;
    return DataSourceSystemDiagnosticReport(
      errorCode: first.errorCode,
      quarantinedCount: 0,
      traceId: first.traceId,
      diagnosticsMarker: first.diagnosticsMarker,
      pluginId: first.pluginId,
      pluginName: first.pluginName,
      buildOutput: first.buildOutput,
      failures: values.expand((report) => report.failures),
    );
  }

  final String errorCode;
  final int quarantinedCount;
  final String traceId;
  final String diagnosticsMarker;
  final String? pluginId;
  final String? pluginName;
  final String? buildOutput;
  final List<DataSourceSystemDiagnosticFailure> failures;

  bool get isDevelopmentReload =>
      failures.isNotEmpty && failures.every((failure) => failure.diagnosticsMarker == 'runtime_source_development_reload_failed');

  int get failureCount => failures.length;

  List<String> get _metadataLines => <String>[
    'MgRead 数据源系统诊断报告',
    '错误代码: $errorCode',
    if (pluginName != null) '数据源名称: $pluginName',
    if (pluginId != null) '数据源 ID: $pluginId',
    '已隔离数据源数量: $quarantinedCount',
    '追踪 ID: $traceId',
    '诊断标记: $diagnosticsMarker',
  ];

  /// Full payload used by the copy action; raw build output stays out of the
  /// dialog body so a large compiler failure cannot make the overlay unwieldy.
  String get copyPayload {
    if (failures.length == 1) {
      return <String>[..._metadataLines, if (buildOutput != null) '构建原始输出:\n$buildOutput'].join('\n');
    }
    return <String>[
      'MgRead 数据源系统诊断报告',
      '失败数据源数量: ${failures.length}',
      ...failures.indexed.map((entry) {
        final failure = entry.$2;
        return <String>[
          '失败 ${entry.$1 + 1}',
          '错误代码: ${failure.errorCode}',
          '数据源名称: ${failure.pluginName ?? '未提供'}',
          '数据源 ID: ${failure.pluginId ?? '未提供'}',
          '追踪 ID: ${failure.traceId}',
          '诊断标记: ${failure.diagnosticsMarker}',
          if (failure.buildOutput != null) '构建原始输出:\n${failure.buildOutput}',
        ].join('\n');
      }),
    ].join('\n');
  }

  String get dialogPayload {
    if (failures.length == 1) return _metadataLines.join('\n');
    return <String>[
      '本批次有 ${failures.length} 个开发数据源失败。',
      ...failures.indexed.map((entry) {
        final failure = entry.$2;
        return '失败 ${entry.$1 + 1}：${failure.displayName}（${failure.pluginId ?? '无 ID'}），错误代码: ${failure.errorCode}';
      }),
    ].join('\n');
  }
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

  DataSourceSystemDiagnosticReport? takeNextReport() {
    if (_pending.isEmpty) return null;
    final first = _pending.removeFirst();
    if (!first.isDevelopmentReload || _pending.isEmpty) return first;

    // Runtime events arrive one source at a time. Drain all currently pending
    // development failures into one report, while leaving startup recovery
    // notices in their original queue order.
    final developmentReports = <DataSourceSystemDiagnosticReport>[first];
    final remaining = Queue<DataSourceSystemDiagnosticReport>();
    while (_pending.isNotEmpty) {
      final report = _pending.removeFirst();
      if (report.isDevelopmentReload) {
        developmentReports.add(report);
      } else {
        remaining.addLast(report);
      }
    }
    _pending.addAll(remaining);
    return developmentReports.length == 1 ? first : DataSourceSystemDiagnosticReport.mergeDevelopment(developmentReports);
  }

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

  void reportDevelopmentReloadFailure({required String errorCode, String? pluginId, String? pluginName, String? buildOutput}) {
    if (_disposed) return;
    final traceId = _newTraceId();
    final debugBuildOutput = kDebugMode ? buildOutput : null;
    try {
      _diagnostics.emit(
        AppDiagnosticEvents.unhandledError,
        traceContext: DiagnosticTraceContext(traceId: traceId, spanId: _diagnostics.idGenerator.nextId('datasourceerror')),
        severity: DiagnosticSeverity.error,
        attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
          'boundary': DiagnosticValue.string('data-source-development-reload'),
          'errorCode': DiagnosticValue.string(errorCode),
          'fatal': DiagnosticValue.boolean(false),
          if (pluginId != null) 'pluginId': DiagnosticValue.string(pluginId),
          if (pluginName != null) 'pluginName': DiagnosticValue.string(pluginName),
          if (debugBuildOutput != null) 'errorText': DiagnosticValue.string(debugBuildOutput),
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
        pluginId: pluginId,
        pluginName: pluginName,
        buildOutput: debugBuildOutput,
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
