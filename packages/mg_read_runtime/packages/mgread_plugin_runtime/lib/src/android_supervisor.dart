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
  @override
  Future<void> configureFlutterTransportProxy(Uri? proxyUri) async {}

  final StreamController<RuntimeDiagnostic> _diagnosticsController =
      StreamController<RuntimeDiagnostic>.broadcast();
  final List<RuntimeDiagnostic> _latestDiagnostics = <RuntimeDiagnostic>[];
  final StreamController<RuntimeInitializationProgress>
  _initializationController =
      StreamController<RuntimeInitializationProgress>.broadcast();
  late final StreamSubscription<dynamic> _progressSubscription =
      _androidRuntimeProgressChannel.receiveBroadcastStream().listen(
        _onNativeProgress,
        onError: (Object _, StackTrace __) {
          _recordDiagnostic(
            const RuntimeDiagnostic(
              code: 'runtime_progress_channel_failed',
              level: RuntimeDiagnosticLevel.warning,
              message: 'The Android Runtime progress channel failed.',
            ),
          );
        },
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
    // A size request can be the first Android Runtime call. Keep the normal
    // cold-start allowance, but do not shorten a long-running capability such
    // as the npm tree scan back to the 30-second startup timeout.
    final timeout = _started
        ? invocation._timeout
        : invocation._timeout > _androidStartupTimeout
        ? invocation._timeout
        : _androidStartupTimeout;
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
          'runtime_no_response',
          'The Android Runtime returned no result.',
        );
      }
      // A non-null bridge payload proves the owned Runtime started, even when
      // that payload is later rejected by the typed wire decoder.
      _started = true;
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
  Future<bool> pickAndImportLocalPlugin() async {
    if (_disposed) {
      throw const PluginRuntimeException(
        'runtime_unavailable',
        'The Android Runtime has been closed.',
      );
    }
    try {
      final imported = await _androidRuntimeChannel.invokeMethod<bool>(
        'pickAndImportLocalPlugin',
      );
      if (imported != true) return false;
      _started = false;
      return true;
    } on PlatformException catch (error) {
      throw PluginRuntimeException(
        error.code,
        'The Android Runtime could not import the selected plugin.',
      );
    } on Object {
      throw const PluginRuntimeException(
        'runtime_unavailable',
        'The Android Runtime could not import the selected plugin.',
      );
    }
  }

  @override
  Future<Stream<List<int>>> exportPluginArtifact(
    PluginTransferArtifact artifact,
  ) async {
    try {
      final metadata = await _androidRuntimeChannel
          .invokeMethod<Object?>('beginPluginTransferExport', <String, Object?>{
            'format': artifact.format.name,
            'pluginId': artifact.pluginId,
            'version': artifact.version,
          });
      final item = _jsonObject(metadata, 'Android plugin transfer export');
      if (item['id'] is! String ||
          item['bytes'] != artifact.bytes ||
          item['format'] != artifact.format.name ||
          item['sha256'] != artifact.sha256) {
        throw const PluginRuntimeException(
          'plugin_transfer_checksum_mismatch',
          'Android Runtime returned an invalid transfer artifact.',
        );
      }
      final id = item['id'] as String;
      return _readAndroidExport(id, artifact.bytes);
    } on PlatformException catch (error) {
      throw PluginRuntimeException(
        error.code,
        'The Android Runtime could not export the plugin artifact.',
      );
    }
  }

  @override
  Future<PluginDevelopmentPackage> packageDevelopmentPlugin(
    String pluginId,
    String directoryPath,
  ) {
    throw const PluginRuntimeException(
      'unsupported',
      'Development source packaging is available on Windows only.',
    );
  }

  Stream<List<int>> _readAndroidExport(String id, int expectedBytes) async* {
    var received = 0;
    try {
      while (received < expectedBytes) {
        final chunk = await _androidRuntimeChannel.invokeMethod<Uint8List>(
          'readPluginTransferExportChunk',
          <String, Object?>{'id': id},
        );
        if (chunk == null ||
            chunk.isEmpty ||
            received + chunk.length > expectedBytes) {
          throw const PluginRuntimeException(
            'plugin_transfer_size_mismatch',
            'The Android Runtime transfer artifact was truncated.',
          );
        }
        received += chunk.length;
        yield chunk;
      }
      if (received != expectedBytes) {
        throw const PluginRuntimeException(
          'plugin_transfer_size_mismatch',
          'The Android Runtime transfer artifact was truncated.',
        );
      }
    } finally {
      if (received < expectedBytes) {
        await _androidRuntimeChannel.invokeMethod<void>(
          'cancelPluginTransferExport',
          <String, Object?>{'id': id},
        );
      }
    }
  }

  @override
  Future<List<PluginTransferImportResult>> importPluginArtifacts(
    List<({PluginTransferArtifact artifact, Stream<List<int>> bytes})>
    artifacts,
  ) async {
    if (artifacts.isEmpty || artifacts.length > maxPluginTransferBatch) {
      throw const PluginRuntimeException(
        'plugin_transfer_batch_too_large',
        'The plugin transfer batch is invalid.',
      );
    }
    var total = 0;
    final ids = <String>[];
    try {
      final plan = await invoke(
        PluginTransferPlanInvocation(
          artifacts: [for (final item in artifacts) item.artifact],
        ),
      );
      if (plan.any(
        (item) =>
            item.action == PluginTransferPlanAction.receiverNewer ||
            item.action == PluginTransferPlanAction.same ||
            item.action == PluginTransferPlanAction.unavailable,
      )) {
        throw const PluginRuntimeException(
          'invalid_request',
          'The plugin transfer would downgrade or replace an equal Runtime version.',
        );
      }
      for (final item in artifacts) {
        if (item.artifact.bytes <= 0 ||
            item.artifact.bytes > maxPluginTransferBytes) {
          throw const PluginRuntimeException(
            'plugin_transfer_artifact_too_large',
            'The plugin transfer artifact is too large.',
          );
        }
        total += item.artifact.bytes;
        if (total > maxPluginTransferBatchBytes) {
          throw const PluginRuntimeException(
            'plugin_transfer_batch_too_large',
            'The plugin transfer batch is too large.',
          );
        }
        final id = await _androidRuntimeChannel
            .invokeMethod<String>('beginPluginTransfer', <String, Object?>{
              'bytes': item.artifact.bytes,
              'format': item.artifact.format.name,
              'pluginId': item.artifact.pluginId,
              'sha256': item.artifact.sha256,
              'version': item.artifact.version,
            });
        if (id == null || id.isEmpty) {
          throw const PluginRuntimeException(
            'runtime_no_response',
            'Android Runtime returned no transfer session.',
          );
        }
        ids.add(id);
        var copied = 0;
        await for (final chunk in item.bytes) {
          copied += chunk.length;
          if (copied > item.artifact.bytes) {
            throw const PluginRuntimeException(
              'plugin_transfer_size_mismatch',
              'The plugin transfer artifact exceeded its declared size.',
            );
          }
          await _androidRuntimeChannel.invokeMethod<void>(
            'writePluginTransferChunk',
            <String, Object?>{'chunk': Uint8List.fromList(chunk), 'id': id},
          );
        }
        if (copied != item.artifact.bytes) {
          throw const PluginRuntimeException(
            'plugin_transfer_size_mismatch',
            'The plugin transfer artifact was truncated.',
          );
        }
      }
      await _androidRuntimeChannel.invokeMethod<void>(
        'finishPluginTransferBatch',
        <String, Object?>{'ids': ids},
      );
      _started = false;
      return <PluginTransferImportResult>[
        for (final item in artifacts)
          PluginTransferImportResult(
            pluginId: item.artifact.pluginId,
            status: PluginTransferImportStatus.installed,
            version: item.artifact.version,
          ),
      ];
    } on PlatformException catch (error) {
      throw PluginRuntimeException(
        error.code,
        'The Android Runtime could not import the plugin transfer.',
      );
    }
  }

  @override
  Future<void> importLocalPlugin(String sourcePath) async {
    if (_disposed) {
      throw const PluginRuntimeException(
        'runtime_unavailable',
        'The Android Runtime has been closed.',
      );
    }
    try {
      await _androidRuntimeChannel.invokeMethod<void>(
        'importLocalPlugin',
        <String, Object?>{'sourcePath': sourcePath},
      );
      _started = false;
    } on PlatformException catch (error) {
      throw PluginRuntimeException(
        error.code,
        'The Android Runtime could not import the selected plugin.',
      );
    } on Object {
      throw const PluginRuntimeException(
        'runtime_unavailable',
        'The Android Runtime could not import the selected plugin.',
      );
    }
  }

  @override
  Future<void> setDevelopmentDirectory(String path) {
    throw const PluginRuntimeException(
      'unsupported',
      'Development source directories are available on Windows only.',
    );
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
    final detail = raw['detail'];
    if (completedBytes is! int ||
        stage is! String ||
        totalBytes is! int ||
        (detail != null && detail is! String) ||
        completedBytes < 0 ||
        totalBytes < 0 ||
        completedBytes > totalBytes && totalBytes != 0) {
      return;
    }
    final progress = RuntimeInitializationProgress.fromPlatform(
      completedBytes: completedBytes,
      detail: detail as String?,
      stage: stage,
      totalBytes: totalBytes,
    );
    if (progress != null && !_initializationController.isClosed) {
      _initializationController.add(progress);
    }
  }
}
