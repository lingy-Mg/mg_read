part of mgread_plugin_runtime;

/// Synchronizes Windows Debug development projects before Facade calls.
extension _DesktopDevelopmentSynchronization on _DesktopRuntimeSupervisor {
  Future<void> _synchronizeDevelopmentRuntime() async {
    final developmentRoot = _developmentPluginDirectory;
    if (developmentRoot == null) return;
    final previous = _developmentSynchronization;
    final gate = Completer<void>();
    _developmentSynchronization = gate.future;
    try {
      await previous;
      final nextFingerprint = await _fingerprintDevelopmentPlugins(
        developmentRoot,
      );
      final currentFingerprint = _developmentFingerprint;
      if (currentFingerprint == null) {
        _developmentFingerprint = nextFingerprint;
        return;
      }
      if (currentFingerprint == nextFingerprint) return;
      await _restartForDevelopmentChange();
      _developmentFingerprint = nextFingerprint;
    } finally {
      gate.complete();
    }
  }

  Future<void> _restartForDevelopmentChange() async {
    _developmentRestarting = true;
    try {
      final connection = _connection;
      if (connection != null) {
        try {
          await connection
              .request(
                method: 'runtime.shutdown',
                params: const <String, Object?>{},
                idempotencyKey: 'development-source-change',
              )
              .timeout(_startupTimeout);
        } on Object {
          // The Job Object remains the authoritative bounded cleanup path.
        }
        await connection.close();
        _connection = null;
      }
      await _terminateOwnedProcessTree();
      await _disposeMonitor();
      _startup = null;
      _recordDiagnostic(
        const RuntimeDiagnostic(
          code: 'runtime_development_plugins_reloaded',
          level: RuntimeDiagnosticLevel.info,
          message:
              'Windows development sources changed and the Runtime was reloaded.',
        ),
      );
    } finally {
      _developmentRestarting = false;
    }
  }
}
