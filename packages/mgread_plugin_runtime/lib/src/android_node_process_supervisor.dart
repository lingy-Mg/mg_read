part of mgread_plugin_runtime;

/// Android backend selected in settings, owning one Node service and Core socket.
///
/// All capabilities and resources use the same authenticated Core protocol as
/// desktop. The native channel owns only process lifetime, WebView and local
/// artifact IO; callers retain the unchanged PluginRuntime Facade.
final class _AndroidNodeProcessSupervisor implements _RuntimeSupervisor {
  static const _channel = MethodChannel('mgread_plugin_runtime/android_node');
  static const _events = EventChannel(
    'mgread_plugin_runtime/android_node/events',
  );
  static const _nodeVersion = '24.21.0';
  static const _startupTimeout = Duration(seconds: 30);
  final StreamController<RuntimeDiagnostic> _diagnosticController =
      StreamController<RuntimeDiagnostic>.broadcast();
  final StreamController<RuntimeInitializationProgress> _progressController =
      StreamController<RuntimeInitializationProgress>.broadcast();
  final List<RuntimeDiagnostic> _diagnostics = <RuntimeDiagnostic>[];
  late final StreamSubscription<dynamic> _subscription = _events
      .receiveBroadcastStream()
      .listen(_onEvent);
  _WireConnection? _connection;
  Future<_WireConnection>? _startup;
  Uri? _pluginHttpProxy;
  bool _disposed = false;
  bool _restarting = false;
  bool _restartAfterExit = false;
  int _starts = 0;

  @override
  Stream<RuntimeDiagnostic> get diagnostics => _diagnosticController.stream;

  @override
  Stream<RuntimeInitializationProgress> get initialization =>
      _progressController.stream;

  @override
  Stream<DevelopmentPluginChangeBatch> get developmentChanges =>
      const Stream<DevelopmentPluginChangeBatch>.empty();

  @override
  List<RuntimeDiagnostic> get latestDiagnostics =>
      List<RuntimeDiagnostic>.unmodifiable(_diagnostics);

  @override
  int get debugProcessStartCount => _starts;

  void _assertOpen() {
    if (_disposed) {
      throw const PluginRuntimeException(
        'runtime_unavailable',
        'The Android Node process has been closed.',
      );
    }
  }

  void _record(RuntimeDiagnostic diagnostic) {
    if (_diagnostics.length >= _maxDiagnosticEntries) _diagnostics.removeAt(0);
    _diagnostics.add(diagnostic);
    if (!_diagnosticController.isClosed) _diagnosticController.add(diagnostic);
  }

  void _onEvent(dynamic raw) {
    if (raw is! Map<Object?, Object?>) return;
    final type = raw['type'];
    if (type == 'node_stderr' || type == 'node_stdout') {
      final line = raw['line'];
      if (line is! String || line.length > 64 * 1024) return;
      final progress = _parseStructuredProgress(line);
      if (progress != null) {
        if (!_progressController.isClosed) _progressController.add(progress);
        return;
      }
      final diagnostic = _parseStructuredDiagnostic(line);
      if (diagnostic != null) _record(diagnostic.diagnostic);
      return;
    }
    if (type == 'progress') {
      final completed = raw['completedBytes'];
      final total = raw['totalBytes'];
      final stage = raw['stage'];
      if (completed is int && total is int && stage is String) {
        final progress = RuntimeInitializationProgress.fromPlatform(
          completedBytes: completed,
          totalBytes: total,
          stage: stage,
          catalogState: raw['catalogState'] as String?,
          detail: raw['detail'] as String?,
          durationMicros: raw['durationMicros'] as int?,
          itemCount: raw['itemCount'] as int?,
        );
        if (progress != null && !_progressController.isClosed) {
          _progressController.add(progress);
        }
      }
    } else if (type == 'node_exit' && !_disposed && !_restarting) {
      _restartAfterExit = true;
      _connection = null;
      _startup = null;
      final code = raw['code'];
      _record(
        RuntimeDiagnostic(
          code: code is String ? code : 'runtime_process_exited',
          level: RuntimeDiagnosticLevel.fatal,
          message: 'The Android Node process exited.',
        ),
      );
    }
  }

  Future<_WireConnection> _ensureStarted() {
    _assertOpen();
    return _startup ??= _start();
  }

  Future<_WireConnection> _start() async {
    _WireConnection? candidate;
    try {
      final line = await _channel
          .invokeMethod<String>(_restartAfterExit ? 'restart' : 'start')
          .timeout(_startupTimeout);
      _restartAfterExit = false;
      if (line == null)
        throw const FormatException('Missing Node ready record.');
      final ready = _RuntimeReady.parse(
        line,
        expectedNodeVersion: _nodeVersion,
      );
      await _probeReady(ready);
      candidate = await _WireConnection.connect(
        ready,
        browserSessionHost: AndroidNodeBrowserSessionHost(),
        onDevelopmentChange: (_) {},
      );
      await candidate.hello();
      await _applyProxy(candidate);
      _connection = candidate;
      _starts++;
      return candidate;
    } on PlatformException catch (error) {
      await candidate?.close();
      _startup = null;
      throw PluginRuntimeException(
        error.code,
        'The Android Node process could not start.',
        diagnostics: latestDiagnostics,
      );
    } on FormatException {
      await candidate?.close();
      _startup = null;
      _record(
        const RuntimeDiagnostic(
          code: 'version_incompatible',
          level: RuntimeDiagnosticLevel.fatal,
          message: 'The Android Node ready record is incompatible.',
        ),
      );
      throw PluginRuntimeException(
        'version_incompatible',
        'The Android Node ready record is incompatible.',
        diagnostics: latestDiagnostics,
      );
    } on PluginRuntimeException {
      await candidate?.close();
      _startup = null;
      rethrow;
    } on Object {
      await candidate?.close();
      _startup = null;
      _record(
        const RuntimeDiagnostic(
          code: 'runtime_start_failed',
          level: RuntimeDiagnosticLevel.fatal,
          message: 'The Android Node process failed its readiness checks.',
        ),
      );
      throw PluginRuntimeException(
        'runtime_start_failed',
        'The Android Node process failed its readiness checks.',
        diagnostics: latestDiagnostics,
      );
    }
  }

  Future<void> _probeReady(_RuntimeReady ready) async {
    final client = HttpClient()..connectionTimeout = _startupTimeout;
    try {
      final request = await client
          .getUrl(
            Uri(
              scheme: 'http',
              host: ready.host,
              port: ready.port,
              path: '/health/ready',
            ),
          )
          .timeout(_startupTimeout);
      final response = await request.close().timeout(_startupTimeout);
      final body = await utf8.decoder
          .bind(response)
          .join()
          .timeout(_startupTimeout);
      final record = _jsonObject(
        jsonDecode(body),
        'Android Node health record',
      );
      if (response.statusCode != HttpStatus.ok ||
          record['status'] != 'ready' ||
          record['bootId'] != ready.bootId ||
          record['nodeVersion'] != _nodeVersion ||
          record['protocolVersion'] != _protocolVersion) {
        throw const FormatException('Android Node health record mismatch.');
      }
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _applyProxy(_WireConnection connection) async {
    final result = _jsonObject(
      await connection.request(
        method: 'runtime.pluginHttpProxy.configure.v1',
        params: <String, Object?>{'proxyUrl': _pluginHttpProxy?.toString()},
      ),
      'Android Node proxy result',
    );
    if (result['enabled'] != (_pluginHttpProxy != null)) {
      throw const PluginRuntimeException(
        'invalid_response',
        'The Android Node process returned an invalid proxy result.',
      );
    }
  }

  @override
  Future<void> configureNodeEnvironmentProxy(bool enabled) async {
    _assertOpen();
    // Android uses the explicit source proxy only.
  }

  @override
  Future<void> configurePluginHttpProxy(Uri? proxyUri) async {
    _assertOpen();
    _pluginHttpProxy = proxyUri;
    final connection = _connection;
    if (connection != null) await _applyProxy(connection);
  }

  @override
  Future<T> invoke<T>(
    PluginInvocation<T> invocation, {
    PluginInvocationCancellation? cancellation,
  }) async {
    _assertOpen();
    try {
      final connection = await _awaitPluginInvocation(
        _ensureStarted(),
        cancellation,
      );
      final result = await connection.request(
        method: invocation._wireMethod,
        params: invocation._wireParams,
        timeout: invocation._timeout,
        cancellation: cancellation,
      );
      return invocation._decodeResult(result);
    } on PluginRuntimeException catch (error) {
      if (error.code == 'transport_disconnected') {
        _connection = null;
        _startup = null;
        _restartAfterExit = true;
      }
      rethrow;
    }
  }

  @override
  Future<bool> pickAndImportLocalPlugin() async {
    _assertOpen();
    _restarting = true;
    try {
      final selected = await _channel.invokeMethod<bool>('pickAndImportLocal');
      if (selected == true) await _reconnectAfterNativeRestart();
      return selected == true;
    } finally {
      _restarting = false;
    }
  }

  @override
  Future<void> importLocalPlugin(String sourcePath) async {
    _assertOpen();
    _restarting = true;
    try {
      await _channel.invokeMethod<void>('importLocal', <String, Object?>{
        'sourcePath': sourcePath,
      });
      await _reconnectAfterNativeRestart();
    } on PlatformException catch (error) {
      throw PluginRuntimeException(
        error.code,
        'The Android Node process could not import the plugin.',
      );
    } finally {
      _restarting = false;
    }
  }

  Future<void> _reconnectAfterNativeRestart() async {
    await _connection?.close();
    _connection = null;
    _startup = null;
    await _ensureStarted();
  }

  @override
  Future<Stream<List<int>>> exportPluginArtifact(
    PluginTransferArtifact artifact,
  ) async {
    final result = await materializePluginArtifact(
      PluginTransferOffer(
        developmentFingerprint: artifact.developmentFingerprint,
        developmentRevision: artifact.developmentRevision,
        format: artifact.format,
        pluginId: artifact.pluginId,
        provenance: artifact.provenance,
        version: artifact.version,
      ),
    );
    if (result.artifact.bytes != artifact.bytes ||
        result.artifact.checksum != artifact.checksum) {
      throw const PluginRuntimeException(
        'plugin_transfer_checksum_mismatch',
        'The Android Node process returned a different artifact.',
      );
    }
    return result.bytes;
  }

  @override
  Future<MaterializedPluginArtifact> materializePluginArtifact(
    PluginTransferOffer offer,
  ) async {
    _assertOpen();
    final metadata = _jsonObject(
      await _channel
          .invokeMethod<Object?>('beginPluginTransferExport', <String, Object?>{
            'pluginId': offer.pluginId,
            'version': offer.version,
            'format': offer.format.name,
          }),
      'Android Node export metadata',
    );
    final id = metadata['id'];
    final bytes = metadata['bytes'];
    final checksum = metadata['checksum'];
    if (id is! String ||
        bytes is! int ||
        bytes <= 0 ||
        bytes > maxPluginTransferBytes ||
        checksum is! String ||
        !RegExp(r'^[a-f0-9]{8}$').hasMatch(checksum) ||
        metadata['format'] != offer.format.name) {
      throw const PluginRuntimeException(
        'plugin_transfer_checksum_mismatch',
        'The Android Node process returned invalid export metadata.',
      );
    }
    return MaterializedPluginArtifact(
      artifact: PluginTransferArtifact(
        bytes: bytes,
        checksum: checksum,
        format: offer.format,
        pluginId: offer.pluginId,
        provenance: offer.provenance,
        version: offer.version,
        developmentFingerprint: offer.developmentFingerprint,
        developmentRevision: offer.developmentRevision,
      ),
      bytes: _readExport(id, bytes),
    );
  }

  Stream<List<int>> _readExport(String id, int expectedBytes) async* {
    var received = 0;
    try {
      while (received < expectedBytes) {
        final chunk = await _channel.invokeMethod<Uint8List>(
          'readPluginTransferExportChunk',
          <String, Object?>{'id': id},
        );
        if (chunk == null ||
            chunk.isEmpty ||
            received + chunk.length > expectedBytes) {
          throw const PluginRuntimeException(
            'plugin_transfer_size_mismatch',
            'The Android Node export was truncated.',
          );
        }
        received += chunk.length;
        yield chunk;
      }
    } finally {
      if (received < expectedBytes) {
        await _channel.invokeMethod<void>(
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
    _assertOpen();
    if (artifacts.isEmpty) {
      throw const PluginRuntimeException(
        'plugin_transfer_batch_too_large',
        'The Android Node transfer batch is empty.',
      );
    }
    final plan = await invoke(
      PluginTransferPlanInvocation(
        artifacts: [for (final item in artifacts) item.artifact],
        forceUpgradePluginIds: forceUpgradePluginIds,
      ),
    );
    if (plan.any(
      (item) =>
          item.action != PluginTransferPlanAction.missing &&
          item.action != PluginTransferPlanAction.upgrade,
    )) {
      throw const PluginRuntimeException(
        'invalid_request',
        'The Android Node transfer plan rejected an artifact.',
      );
    }
    var total = 0;
    for (final item in artifacts) {
      total += item.artifact.bytes;
      if (item.artifact.bytes <= 0 ||
          item.artifact.bytes > maxPluginTransferBytes ||
          total > maxPluginTransferBatchBytes) {
        throw const PluginRuntimeException(
          'plugin_transfer_batch_too_large',
          'The Android Node transfer batch is too large.',
        );
      }
    }
    await _importBatch(artifacts);
    return _pluginImportResults(
      artifacts.map((item) => item.artifact),
      await invoke(const InstalledPluginsInvocation()),
    );
  }

  Future<void> _importBatch(
    List<({PluginTransferArtifact artifact, Stream<List<int>> bytes})>
    artifacts,
  ) async {
    final ids = <String>[];
    try {
      for (final item in artifacts) {
        final artifact = item.artifact;
        final id = await _channel
            .invokeMethod<String>('beginPluginTransfer', <String, Object?>{
              'pluginId': artifact.pluginId,
              'version': artifact.version,
              'bytes': artifact.bytes,
              'checksum': artifact.checksum,
              'format': artifact.format.name,
            });
        if (id == null)
          throw const PluginRuntimeException(
            'runtime_no_response',
            'No Android transfer ID.',
          );
        ids.add(id);
        var copied = 0;
        await for (final chunk in item.bytes) {
          copied += chunk.length;
          if (copied > artifact.bytes) {
            throw const PluginRuntimeException(
              'plugin_transfer_size_mismatch',
              'The artifact exceeded its size.',
            );
          }
          await _channel.invokeMethod<void>(
            'writePluginTransferChunk',
            <String, Object?>{'id': id, 'chunk': Uint8List.fromList(chunk)},
          );
        }
        if (copied != artifact.bytes) {
          throw const PluginRuntimeException(
            'plugin_transfer_size_mismatch',
            'The artifact was truncated.',
          );
        }
      }
      _restarting = true;
      await _channel.invokeMethod<void>(
        'finishPluginTransferBatch',
        <String, Object?>{'ids': ids},
      );
      await _reconnectAfterNativeRestart();
    } on Object {
      if (ids.isNotEmpty) {
        await _channel.invokeMethod<void>(
          'cancelPluginTransferBatch',
          <String, Object?>{'ids': ids},
        );
      }
      rethrow;
    } finally {
      _restarting = false;
    }
  }

  @override
  Future<PluginDevelopmentPackage> packageDevelopmentPlugin(
    String pluginId,
    String directoryPath,
  ) {
    throw const PluginRuntimeException(
      'unsupported',
      'Android has no development package builder.',
    );
  }

  @override
  Future<void> setDevelopmentDirectory(String path) {
    throw const PluginRuntimeException(
      'unsupported',
      'Android has no development directory.',
    );
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final connection = _connection;
    _connection = null;
    if (connection != null) {
      try {
        await connection.request(
          method: 'runtime.shutdown',
          params: const <String, Object?>{},
        );
      } on Object {}
      await connection.close();
    }
    await _channel.invokeMethod<void>('dispose');
    await _subscription.cancel();
    await _diagnosticController.close();
    await _progressController.close();
  }
}
