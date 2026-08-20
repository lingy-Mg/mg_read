part of mgread_plugin_runtime;

const MethodChannel _androidRuntimeChannel = MethodChannel(
  'mgread_plugin_runtime/android',
);
const EventChannel _androidRuntimeProgressChannel = EventChannel(
  'mgread_plugin_runtime/android/progress',
);
const Duration _androidStartupTimeout = Duration(seconds: 30);

/// Flutter-facing Android supervisor backed by the Runtime-owned Javet host.
final class _AndroidRuntimeSupervisor implements _RuntimeSupervisor {
  final StreamController<RuntimeDiagnostic> _diagnosticsController =
      StreamController<RuntimeDiagnostic>.broadcast();
  final List<RuntimeDiagnostic> _latestDiagnostics = <RuntimeDiagnostic>[];
  final StreamController<RuntimeInitializationProgress>
  _initializationController =
      StreamController<RuntimeInitializationProgress>.broadcast();
  late final StreamSubscription<dynamic> _progressSubscription =
      _androidRuntimeProgressChannel.receiveBroadcastStream().listen(
        _onNativeProgress,
      );
  bool _disposed = false;
  bool _started = false;

  @override
  Stream<RuntimeDiagnostic> get diagnostics => _diagnosticsController.stream;

  @override
  Stream<RuntimeInitializationProgress> get initialization =>
      _initializationController.stream;

  @override
  List<RuntimeDiagnostic> get latestDiagnostics =>
      List<RuntimeDiagnostic>.unmodifiable(_latestDiagnostics);

  @override
  int get debugProcessStartCount => 0;

  @override
  Future<T> invoke<T>(PluginInvocation<T> invocation) async {
    if (_disposed) {
      throw const PluginRuntimeException(
        'runtime_unavailable',
        'The Android Runtime has been closed.',
      );
    }
    final timeout = _started ? _controlTimeout : _androidStartupTimeout;
    final deadline = DateTime.now().add(timeout).millisecondsSinceEpoch;
    _recordDiagnostic(
      const RuntimeDiagnostic(
        code: 'runtime_facade_invoke_started',
        level: RuntimeDiagnosticLevel.info,
        message: 'The Android Runtime capability invocation started.',
      ),
    );
    try {
      final encoded = await _androidRuntimeChannel
          .invokeMethod<String>('invoke', <String, Object?>{
            'method': invocation._wireMethod,
            'params': invocation._wireParams,
            'deadlineUnixMs': deadline,
          })
          .timeout(timeout);
      if (encoded == null) {
        throw const PluginRuntimeException(
          'invalid_response',
          'The Android Runtime returned no result.',
        );
      }
      final decoded = jsonDecode(encoded);
      if (decoded is! Map<Object?, Object?>) {
        throw const PluginRuntimeException(
          'invalid_response',
          'The Android Runtime returned an invalid result.',
        );
      }
      if (decoded['ok'] != true) {
        final error = decoded['error'];
        final code = error is Map<Object?, Object?> && error['code'] is String
            ? error['code'] as String
            : 'internal';
        final message =
            error is Map<Object?, Object?> && error['message'] is String
            ? error['message'] as String
            : 'The Android Runtime rejected the request.';
        throw PluginRuntimeException(code, message);
      }
      final result = invocation._decodeResult(decoded['result']);
      _started = true;
      _recordDiagnostic(
        const RuntimeDiagnostic(
          code: 'runtime_facade_invoke_completed',
          level: RuntimeDiagnosticLevel.info,
          message: 'The Android Runtime capability invocation completed.',
        ),
      );
      return result;
    } on PluginRuntimeException {
      _recordDiagnostic(
        const RuntimeDiagnostic(
          code: 'runtime_facade_invoke_rejected',
          level: RuntimeDiagnosticLevel.warning,
          message: 'The Android Runtime rejected a capability invocation.',
        ),
      );
      rethrow;
    } on PlatformException catch (error) {
      _recordDiagnostic(
        const RuntimeDiagnostic(
          code: 'runtime_facade_invoke_bridge_failed',
          level: RuntimeDiagnosticLevel.error,
          message: 'The Android Runtime platform bridge failed.',
        ),
      );
      throw PluginRuntimeException(
        error.code,
        'The Android Runtime platform bridge failed.',
      );
    } on TimeoutException {
      _recordDiagnostic(
        const RuntimeDiagnostic(
          code: 'runtime_facade_invoke_timeout',
          level: RuntimeDiagnosticLevel.warning,
          message: 'The Android Runtime capability invocation timed out.',
        ),
      );
      throw const PluginRuntimeException(
        'timeout',
        'The Android Runtime capability call timed out.',
      );
    } on Object {
      _recordDiagnostic(
        const RuntimeDiagnostic(
          code: 'runtime_facade_invoke_failed',
          level: RuntimeDiagnosticLevel.error,
          message: 'The Android Runtime capability invocation failed.',
        ),
      );
      throw const PluginRuntimeException(
        'runtime_unavailable',
        'The Android Runtime capability call failed.',
      );
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _androidRuntimeChannel.invokeMethod<void>('dispose');
    await _progressSubscription.cancel();
    await _diagnosticsController.close();
    await _initializationController.close();
  }

  void _recordDiagnostic(RuntimeDiagnostic diagnostic) {
    if (_latestDiagnostics.length == _maxDiagnosticEntries) {
      _latestDiagnostics.removeAt(0);
    }
    _latestDiagnostics.add(diagnostic);
    if (!_diagnosticsController.isClosed) {
      _diagnosticsController.add(diagnostic);
    }
  }

  void _onNativeProgress(dynamic raw) {
    if (raw is! Map<Object?, Object?>) return;
    final completedBytes = raw['completedBytes'];
    final stage = raw['stage'];
    final totalBytes = raw['totalBytes'];
    if (completedBytes is! int ||
        stage is! String ||
        totalBytes is! int ||
        completedBytes < 0 ||
        totalBytes < 0 ||
        completedBytes > totalBytes && totalBytes != 0) {
      return;
    }
    final progress = RuntimeInitializationProgress.fromPlatform(
      completedBytes: completedBytes,
      stage: stage,
      totalBytes: totalBytes,
    );
    if (progress != null && !_initializationController.isClosed) {
      _initializationController.add(progress);
    }
  }
}
