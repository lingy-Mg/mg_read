import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'diagnostic_event.dart';
import 'diagnostic_ports.dart';
import 'diagnostic_registry.dart';
import 'diagnostics_manager.dart';

/// Process-scoped diagnostics manager. The production composition root
/// overrides this with the persistent app manager.
final diagnosticsManagerProvider = Provider<DiagnosticsManager>((Ref ref) {
  final manager = DiagnosticsManager(
    sink: const NoopDiagnosticEventSink(),
    registry: AppDiagnosticEvents.registry,
    source: DiagnosticSource.app,
  );
  ref.onDispose(() => unawaited(manager.close()));
  return manager;
});

/// Read/query capabilities are absent in isolated widget and unit tests unless
/// explicitly overridden by the composition root.
final diagnosticsQueryProvider = Provider<DiagnosticsQuery?>((Ref ref) => null);
final diagnosticsCaptureProvider = Provider<DiagnosticsCapture?>(
  (Ref ref) => null,
);
final diagnosticsMaintenanceProvider = Provider<DiagnosticsMaintenance?>(
  (Ref ref) => null,
);
