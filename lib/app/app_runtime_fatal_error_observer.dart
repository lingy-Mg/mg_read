import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_fatal_error_reporter.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';

/// Narrow typed source used by the app-level Runtime fatal observer.
abstract interface class RuntimeFatalDiagnosticSource {
  Stream<RuntimeDiagnostic> get diagnostics;

  List<RuntimeDiagnostic> get latestDiagnostics;
}

final class PluginRuntimeFatalDiagnosticSource implements RuntimeFatalDiagnosticSource {
  const PluginRuntimeFatalDiagnosticSource(this._runtime);

  final PluginRuntime _runtime;

  @override
  Stream<RuntimeDiagnostic> get diagnostics => _runtime.diagnostics;

  @override
  List<RuntimeDiagnostic> get latestDiagnostics => _runtime.latestDiagnostics;
}

/// Bridges Runtime-wide terminal diagnostics to the root UI.
///
/// It is intentionally process-scoped and begins before app warmup, so a
/// Windows Node exit reported after startup is observed even when the next
/// Facade request originates from a feature rather than from the root widget.
final class RuntimeFatalErrorObserver {
  RuntimeFatalErrorObserver(this._source, this._reporter);

  final RuntimeFatalDiagnosticSource _source;
  final AppFatalErrorReporter _reporter;
  StreamSubscription<RuntimeDiagnostic>? _subscription;
  bool _disposed = false;
  bool _hasObservedFatal = false;

  bool get hasObservedFatal => _hasObservedFatal;

  void start() {
    if (_disposed || _subscription != null) return;
    observeLatestDiagnostics();
    if (_disposed || _hasObservedFatal) return;
    _subscription = _source.diagnostics.listen(
      _observe,
      onError: (_, _) {
        // Runtime diagnostics are best effort; an observer failure must not
        // alter the Runtime call that is already in flight.
      },
    );
  }

  /// Rechecks the bounded typed snapshot after a Facade failure, closing the
  /// small scheduling window between a Runtime diagnostic and its stream
  /// delivery without exposing any Runtime transport detail.
  void observeLatestDiagnostics() {
    if (_disposed || _hasObservedFatal) return;
    for (final diagnostic in _source.latestDiagnostics) {
      _observe(diagnostic);
    }
  }

  void _observe(RuntimeDiagnostic diagnostic) {
    if (_disposed || _hasObservedFatal) return;
    final projection = _fatalProjectionFor(diagnostic.code);
    if (projection == null) return;
    _hasObservedFatal = true;
    _reporter.reportFatalRuntimeDiagnostic(
      errorCode: projection.errorCode,
      diagnosticText: diagnostic.message,
      phase: projection.phase,
      runtimeState: projection.runtimeState,
    );
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_subscription?.cancel());
  }
}

final class _RuntimeFatalProjection {
  const _RuntimeFatalProjection({required this.errorCode, required this.phase, required this.runtimeState});

  final String errorCode;
  final String phase;
  final String runtimeState;
}

_RuntimeFatalProjection? _fatalProjectionFor(String code) => switch (code) {
  'runtime_process_exited' => const _RuntimeFatalProjection(
    errorCode: 'runtime_process_exited',
    phase: 'runtime_lifecycle',
    runtimeState: 'exited',
  ),
  'runtime_data_root_unavailable' ||
  'runtime_bundled_plugin_assets_missing' ||
  'runtime_entrypoint_missing' ||
  'runtime_exited_before_ready' ||
  'runtime_node_executable_missing' ||
  'runtime_process_launch_failed' ||
  'runtime_startup_channel_failed' ||
  'runtime_start_failed' => const _RuntimeFatalProjection(
    errorCode: 'runtime_start_failed',
    phase: 'runtime_startup',
    runtimeState: 'startup_failed',
  ),
  'runtime_http_readiness_failed' ||
  'runtime_invalid_ready_signal' ||
  'runtime_ready_timeout' ||
  'runtime_not_ready' => const _RuntimeFatalProjection(errorCode: 'runtime_not_ready', phase: 'runtime_startup', runtimeState: 'not_ready'),
  'runtime_unavailable' => const _RuntimeFatalProjection(
    errorCode: 'runtime_unavailable',
    phase: 'runtime_lifecycle',
    runtimeState: 'unavailable',
  ),
  _ => null,
};

/// Starts the single app-level Runtime observer before the first Facade call.
final runtimeFatalErrorObserverProvider = Provider<RuntimeFatalErrorObserver>((Ref ref) {
  final observer = RuntimeFatalErrorObserver(
    PluginRuntimeFatalDiagnosticSource(ref.watch(pluginRuntimeFacadeProvider)),
    ref.watch(fatalErrorReporterProvider),
  )..start();
  ref.onDispose(observer.dispose);
  return observer;
});
