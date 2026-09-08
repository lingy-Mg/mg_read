part of mgread_plugin_runtime;

const MethodChannel _androidRuntimeChannel = MethodChannel(
  'mgread_plugin_runtime/android',
);
const EventChannel _androidRuntimeProgressChannel = EventChannel(
  'mgread_plugin_runtime/android/progress',
);
const Duration _androidStartupTimeout = Duration(seconds: 30);
const int _maxAndroidPluginTransferBatchItems = 32;

/// Flutter-facing Android supervisor backed by the Runtime-owned Javet host.
final class _AndroidRuntimeSupervisor implements _RuntimeSupervisor {
  @override
  Future<void> configureNodeEnvironmentProxy(bool enabled) async {
    if (_disposed) {
      throw const PluginRuntimeException(
        'runtime_unavailable',
        'The Android Runtime has been closed.',
      );
    }
  }

  @override
  Future<void> configurePluginHttpProxy(Uri? proxyUri) async {
    if (_disposed) {
      throw const PluginRuntimeException(
        'runtime_unavailable',
        'The Android Runtime has been closed.',
      );
    }
    final deadline = DateTime.now()
        .add(_androidStartupTimeout)
        .millisecondsSinceEpoch;
    final requestId =
        'dart-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-${++_invocationSequence}';
    try {
      final encoded = await _androidRuntimeChannel
          .invokeMethod<String>('invoke', <String, Object?>{
            'requestId': requestId,
            'method': 'runtime.pluginHttpProxy.configure.v1',
            'params': <String, Object?>{'proxyUrl': proxyUri?.toString()},
            'deadlineUnixMs': deadline,
          })
          .timeout(
            _androidStartupTimeout,
            onTimeout: () {
              _cancelInvocation(requestId);
              throw TimeoutException(
                'The Android Runtime proxy configuration timed out.',
                _androidStartupTimeout,
              );
            },
          );
      if (encoded == null) {
        throw const PluginRuntimeException(
          'runtime_no_response',
          'The Android Runtime returned no proxy configuration result.',
        );
      }
      _started = true;
      final decoded = jsonDecode(encoded);
      if (decoded is! Map<Object?, Object?> || decoded['ok'] != true) {
        final error = decoded is Map<Object?, Object?>
            ? decoded['error']
            : null;
        final code = error is Map<Object?, Object?> && error['code'] is String
            ? error['code'] as String
            : 'invalid_response';
        throw PluginRuntimeException(
          code,
          'The Android Runtime rejected the plugin HTTP proxy setting.',
        );
      }
      final result = decoded['result'];
      if (result is! Map<Object?, Object?> ||
          result.length != 1 ||
          result['enabled'] != (proxyUri != null)) {
        throw const PluginRuntimeException(
          'invalid_response',
          'The Android Runtime returned an invalid plugin HTTP proxy result.',
        );
      }
    } on PluginRuntimeException {
      rethrow;
    } on PlatformException catch (error) {
      throw PluginRuntimeException(
        error.code,
        'The Android Runtime proxy configuration failed.',
      );
    } on TimeoutException {
      throw const PluginRuntimeException(
        'timeout',
        'The Android Runtime proxy configuration timed out.',
      );
    }
  }

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
  int _invocationSequence = 0;

  @override
  Stream<RuntimeDiagnostic> get diagnostics => _diagnosticsController.stream;

  @override
  Stream<RuntimeInitializationProgress> get initialization =>
      _initializationController.stream;

  @override
  Stream<DevelopmentPluginChangeBatch> get developmentChanges =>
      const Stream<DevelopmentPluginChangeBatch>.empty();

  @override
  List<RuntimeDiagnostic> get latestDiagnostics =>
      List<RuntimeDiagnostic>.unmodifiable(_latestDiagnostics);

  @override
  int get debugProcessStartCount => 0;

  @override
  Future<T> invoke<T>(
    PluginInvocation<T> invocation, {
    PluginInvocationCancellation? cancellation,
  }) async {
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
    final requestId =
        'dart-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-${++_invocationSequence}';
    _recordDiagnostic(
      const RuntimeDiagnostic(
        code: 'runtime_facade_invoke_started',
        level: RuntimeDiagnosticLevel.info,
        message: 'The Android Runtime capability invocation started.',
      ),
    );
    try {
      final nativeInvocation = _androidRuntimeChannel
          .invokeMethod<String>('invoke', <String, Object?>{
            'requestId': requestId,
            'method': invocation._wireMethod,
            'params': invocation._wireParams,
            'deadlineUnixMs': deadline,
          });
      final encoded =
          await _awaitPluginInvocation(
            nativeInvocation,
            cancellation,
            onCancel: () => _cancelInvocation(requestId),
          ).timeout(
            timeout,
            onTimeout: () {
              _cancelInvocation(requestId);
              throw TimeoutException(
                'The Android Runtime capability call timed out.',
                timeout,
              );
            },
          );
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

  void _cancelInvocation(String requestId) {
    unawaited(
      _androidRuntimeChannel
          .invokeMethod<void>('cancelInvocation', <String, Object?>{
            'requestId': requestId,
          })
          .catchError((Object _) {}),
    );
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
    final materialized = await materializePluginArtifact(
      PluginTransferOffer(
        developmentFingerprint: artifact.developmentFingerprint,
        developmentRevision: artifact.developmentRevision,
        format: artifact.format,
        pluginId: artifact.pluginId,
        provenance: artifact.provenance,
        version: artifact.version,
      ),
    );
    if (materialized.artifact.bytes != artifact.bytes ||
        materialized.artifact.sha256 != artifact.sha256) {
      throw const PluginRuntimeException(
        'plugin_transfer_checksum_mismatch',
        'Android Runtime returned an invalid transfer artifact.',
      );
    }
    return materialized.bytes;
  }

  @override
  Future<MaterializedPluginArtifact> materializePluginArtifact(
    PluginTransferOffer offer,
  ) async {
    try {
      final metadata = await _androidRuntimeChannel
          .invokeMethod<Object?>('beginPluginTransferExport', <String, Object?>{
            'format': offer.format.name,
            'pluginId': offer.pluginId,
            'version': offer.version,
          });
      final item = _jsonObject(metadata, 'Android plugin transfer export');
      final id = item['id'];
      final bytes = item['bytes'];
      final sha256 = item['sha256'];
      if (id is! String ||
          bytes is! int ||
          bytes <= 0 ||
          bytes > maxPluginTransferBytes ||
          item['format'] != offer.format.name ||
          sha256 is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256)) {
        if (id is String) {
          try {
            await _androidRuntimeChannel.invokeMethod<void>(
              'cancelPluginTransferExport',
              <String, Object?>{'id': id},
            );
          } on Object {
            // Preserve the stable metadata failure.
          }
        }
        throw const PluginRuntimeException(
          'plugin_transfer_checksum_mismatch',
          'Android Runtime returned an invalid transfer artifact.',
        );
      }
      final artifact = PluginTransferArtifact(
        bytes: bytes,
        developmentFingerprint: offer.developmentFingerprint,
        developmentRevision: offer.developmentRevision,
        format: offer.format,
        pluginId: offer.pluginId,
        provenance: offer.provenance,
        sha256: sha256,
        version: offer.version,
      );
      return MaterializedPluginArtifact(
        artifact: artifact,
        bytes: _readAndroidExport(id, bytes),
      );
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
    artifacts, {
    Set<String> forceUpgradePluginIds = const <String>{},
  }) async {
    if (artifacts.isEmpty) {
      throw const PluginRuntimeException(
        'plugin_transfer_batch_too_large',
        'The plugin transfer batch is invalid.',
      );
    }
    try {
      final plan = await invoke(
        PluginTransferPlanInvocation(
          artifacts: [for (final item in artifacts) item.artifact],
          forceUpgradePluginIds: forceUpgradePluginIds,
        ),
      );
      if (plan.any(
        (item) =>
            item.action == PluginTransferPlanAction.developmentConflict ||
            item.action == PluginTransferPlanAction.receiverNewer ||
            item.action == PluginTransferPlanAction.same ||
            item.action == PluginTransferPlanAction.unavailable,
      )) {
        throw const PluginRuntimeException(
          'invalid_request',
          'The plugin transfer would downgrade or replace an equal Runtime version.',
        );
      }
      var total = 0;
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
      }

      for (
        var offset = 0;
        offset < artifacts.length;
        offset += _maxAndroidPluginTransferBatchItems
      ) {
        await _importPluginArtifactBatch(
          artifacts.sublist(
            offset,
            min(offset + _maxAndroidPluginTransferBatchItems, artifacts.length),
          ),
        );
      }
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

  Future<void> _importPluginArtifactBatch(
    List<({PluginTransferArtifact artifact, Stream<List<int>> bytes})>
    artifacts,
  ) async {
    final ids = <String>[];
    try {
      for (final item in artifacts) {
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
    } on Object catch (error, stackTrace) {
      if (ids.isNotEmpty) {
        try {
          await _androidRuntimeChannel.invokeMethod<void>(
            'cancelPluginTransferBatch',
            <String, Object?>{'ids': ids},
          );
        } on Object {
          // Preserve the transfer failure if native cleanup also fails.
        }
      }
      Error.throwWithStackTrace(error, stackTrace);
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
