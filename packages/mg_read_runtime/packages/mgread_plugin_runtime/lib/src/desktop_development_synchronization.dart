part of mgread_plugin_runtime;

/// Rebinds the immutable development root after an explicit directory change.
extension _DesktopDevelopmentSynchronization on _DesktopRuntimeSupervisor {
  Future<void> _restartForDevelopmentDirectoryChange() async {
    _controlledRestarting = true;
    try {
      final connection = _connection;
      if (connection != null) {
        try {
          await connection
              .request(
                method: 'runtime.shutdown',
                params: const <String, Object?>{},
                idempotencyKey: 'development-directory-change',
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
          code: 'runtime_development_directory_rebound',
          level: RuntimeDiagnosticLevel.info,
          message: 'The Windows development source directory was rebound.',
        ),
      );
    } finally {
      _controlledRestarting = false;
    }
  }
}
