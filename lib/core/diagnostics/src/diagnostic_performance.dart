import 'diagnostic_event.dart';
import 'diagnostic_registry.dart';
import 'diagnostic_value.dart';
import 'diagnostics_manager.dart';

abstract final class AppDiagnosticThresholds {
  static const Duration persistenceOperation = Duration(milliseconds: 50);
  static const Duration settingsWrite = Duration(milliseconds: 100);
  static const Duration libraryOperation = Duration(milliseconds: 300);
  static const Duration libraryOverview = Duration(milliseconds: 300);
  static const Duration readerFirstFrame = Duration(milliseconds: 100);
  // Windows source-tree cold inspect baseline is 163 ms; 2 s allows package I/O variance.
  static const Duration runtimeFacade = Duration(seconds: 2);
  static const Duration bootstrap = Duration(seconds: 1);
}

void reportSlowDiagnostic(
  DiagnosticsManager diagnostics, {
  required String subjectComponent,
  required String operation,
  required Duration elapsed,
  required Duration threshold,
  required DiagnosticOutcome outcome,
  DiagnosticTraceContext? traceContext,
}) {
  if (elapsed < threshold || diagnostics.isClosed) return;
  try {
    diagnostics.emit(
      AppDiagnosticEvents.performanceSlow,
      traceContext: traceContext,
      attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
        'subjectComponent': DiagnosticValue.string(subjectComponent),
        'operation': DiagnosticValue.string(operation),
        'durationMicros': DiagnosticValue.int64(elapsed.inMicroseconds),
        'thresholdMicros': DiagnosticValue.int64(threshold.inMicroseconds),
        'outcome': DiagnosticValue.string(outcome.name),
        'buildMode': DiagnosticValue.string(diagnostics.buildMode),
        'platform': DiagnosticValue.string(diagnostics.platform),
      }),
    );
  } catch (_) {
    // Performance reporting never changes the measured operation.
  }
}
