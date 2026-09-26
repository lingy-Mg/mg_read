part of mgread_plugin_runtime;

/// Owns the Node-independent Rust host process and its authenticated loopback
/// control requests. On Windows this object owns the child and Job Object; on
/// Android the private service owns the process. The host owns plugin state and
/// installation metadata. Each initialized plugin owns HTTP, cache and resources.
/// Dart owns control-call lifetimes and confirmed worker restart boundaries.
final class _NativeRuntimeSupervisor implements _RuntimeSupervisor {
  _NativeRuntimeSupervisor._({
    required bool isAndroid,
    required Directory? dataRoot,
    required File? hostExecutable,
    required bool testMode,
    Uri? testControlUri,
    String? testToken,
  }) : _isAndroid = isAndroid,
       _dataRoot = dataRoot,
       _hostExecutable = hostExecutable,
       _testMode = testMode,
       _testControlUri = testControlUri,
       _testToken = testToken;

  static const MethodChannel _channel = MethodChannel('mgread/native_runtime');
  static const Duration _startupTimeout = Duration(seconds: 30);
  static const Duration _shutdownTimeout = Duration(seconds: 3);
  static const int _maxControlResponseBytes = 100 * 1024 * 1024;

  final bool _isAndroid;
  final Directory? _dataRoot;
  final File? _hostExecutable;
  final bool _testMode;
  final Uri? _testControlUri;
  final String? _testToken;
  late final _NativeRuntimeArtifactTransfer _artifactTransfer =
      _NativeRuntimeArtifactTransfer(this);

  final StreamController<RuntimeDiagnostic> _diagnosticController =
      StreamController<RuntimeDiagnostic>.broadcast();
  final StreamController<RuntimeInitializationProgress>
  _initializationController =
      StreamController<RuntimeInitializationProgress>.broadcast();
  final List<RuntimeDiagnostic> _diagnostics = <RuntimeDiagnostic>[];
  final Map<String, _NativeInFlight> _inFlight = <String, _NativeInFlight>{};

  final _resourceEndpoints = _NativeResourceEndpoints();
  final Map<String, Future<_NativePluginEndpoint>> _pluginInitializations = {};
  bool _stopUnconfirmed = false;
  _NativeRuntimeReady? _ready;
  Process? _process;
  WindowsJobObject? _jobObject;
  Uri? _pluginHttpProxy;
  bool _pluginHttpProxyConfigured = false;
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<dynamic>? _stderrSubscription;
  Future<_NativeRuntimeReady>? _startup;
  Future<void>? _cleanup;
  Future<void>? _disposeFuture;
  Future<void> _lifecycleAdmissionTail = Future<void>.value();
  Completer<void>? _inFlightDrained;
  int _activeInvocationLeases = 0;
  int _invocationSequence = 0;
  int _processStartCount = 0;
  bool _disposed = false;
  bool _intentionalStop = false;

  factory _NativeRuntimeSupervisor.forCurrentPlatform() {
    if (Platform.isAndroid) {
      return _NativeRuntimeSupervisor._(
        isAndroid: true,
        dataRoot: null,
        hostExecutable: null,
        testMode: false,
      );
    }
    if (Platform.isWindows) {
      final dataHome = Platform.environment['LOCALAPPDATA'];
      if (dataHome == null || dataHome.isEmpty) {
        throw const PluginRuntimeException(
          'runtime_data_root_unavailable',
          'The native Runtime could not resolve its application data directory.',
        );
      }
      final appDirectory = File(Platform.resolvedExecutable).parent;
      return _NativeRuntimeSupervisor._(
        isAndroid: false,
        dataRoot: Directory(
          _joinPath(<String>[dataHome, 'MgRead', 'native-runtime']),
        ),
        hostExecutable: File(
          _joinPath(<String>[
            appDirectory.path,
            'native',
            'mgread-native-host.exe',
          ]),
        ),
        testMode: false,
      );
    }
    throw const PluginRuntimeException(
      'unsupported',
      'The native Runtime is available on Windows and Android only.',
    );
  }

  factory _NativeRuntimeSupervisor.forTesting({
    required String executablePath,
    required String dataRoot,
    bool testMode = false,
    Uri? testControlUri,
    String? testToken,
  }) {
    if ((testControlUri == null) != (testToken == null)) {
      throw ArgumentError(
        'A native test control URI and token must be supplied together.',
      );
    }
    if (testControlUri != null &&
        (testControlUri.scheme != 'http' ||
            !const <String>{
              '127.0.0.1',
              'localhost',
              '::1',
            }.contains(testControlUri.host) ||
            !testControlUri.hasPort ||
            testControlUri.port < 1 ||
            testControlUri.port > 65535)) {
      throw ArgumentError.value(
        testControlUri,
        'testControlUri',
        'A loopback HTTP endpoint is required.',
      );
    }
    if (testToken != null && testToken.isEmpty) {
      throw ArgumentError.value(testToken, 'testToken');
    }
    return _NativeRuntimeSupervisor._(
      isAndroid: Platform.isAndroid,
      dataRoot: Directory(dataRoot),
      hostExecutable: File(executablePath),
      testMode: testMode,
      testControlUri: testControlUri,
      testToken: testToken,
    );
  }

  @override
  Stream<RuntimeDiagnostic> get diagnostics => _diagnosticController.stream;

  @override
  Stream<RuntimeInitializationProgress> get initialization =>
      _initializationController.stream;

  @override
  Stream<DevelopmentPluginChangeBatch> get developmentChanges =>
      const Stream<DevelopmentPluginChangeBatch>.empty();

  @override
  List<RuntimeDiagnostic> get latestDiagnostics =>
      List<RuntimeDiagnostic>.unmodifiable(_diagnostics);

  @override
  int get debugProcessStartCount => _processStartCount;

  @override
  Future<void> configureNodeEnvironmentProxy(bool enabled) async {
    _assertOpen();
  }

  @override
  Future<void> configurePluginHttpProxy(Uri? proxyUri) async {
    _assertOpen();
    if (_pluginHttpProxyConfigured && _pluginHttpProxy == proxyUri) return;
    _pluginHttpProxy = proxyUri;
    _pluginHttpProxyConfigured = true;
    await _runLifecycleTransition(() async {
      if (_ready == null) {
        await _ensureStarted();
      } else {
        await _restartAfterManagementChange();
      }
    });
  }

  @override
  Future<T> invoke<T>(
    PluginInvocation<T> invocation, {
    PluginInvocationCancellation? cancellation,
  }) async {
    _assertOpen();
    cancellation?._throwIfCancelled();
    if (invocation is OpenRuntimePrivateDirectoryInvocation) {
      await _openPrivateDirectory();
      return null as T;
    }

    if (const <String>{
      'plugins.uninstall.v1',
      'plugins.uninstallAll.v1',
      'plugins.setEnabled.v1',
      'plugins.cache.clear.v1',
      'plugins.cache.clearAll.v1',
    }.contains(invocation._wireMethod)) {
      return await _runLifecycleTransition<T>(() async {
        final clearCache = invocation._wireMethod.startsWith(
          'plugins.cache.clear',
        );
        if (clearCache) await _restartAfterManagementChange();
        try {
          final raw = await _invokeRpc(
            method: invocation._wireMethod,
            params: invocation._wireParams,
            timeout: invocation._timeout,
            cancellation: cancellation,
          );
          return invocation._decodeResult(raw);
        } finally {
          if (!clearCache) await _restartAfterManagementChange();
        }
      });
    }

    final lease = await _acquireInvocationLease();
    try {
      final raw = await _invokeRpc(
        method: invocation._wireMethod,
        params: invocation._wireParams,
        timeout: invocation._timeout,
        cancellation: cancellation,
      );
      return invocation._decodeResult(raw);
    } finally {
      lease.release();
    }
  }

  @override
  Future<void> importLocalPlugin(String sourcePath) async {
    _assertOpen();
    final lowerPath = sourcePath.toLowerCase();
    if (sourcePath.isEmpty ||
        !lowerPath.endsWith('.mgplugin') ||
        lowerPath.endsWith('.mgplugin.js')) {
      throw const PluginRuntimeException(
        'invalid_request',
        'The native Runtime accepts .mgplugin source packages only.',
      );
    }
    if (!await File(sourcePath).exists()) {
      throw const PluginRuntimeException(
        'not_found',
        'The selected native source package is unavailable.',
      );
    }
    await _runLifecycleTransition<void>(() async {
      final raw = await _invokeRpc(
        method: 'plugins.native.import.v1',
        params: <String, Object?>{'path': sourcePath},
        timeout: const Duration(minutes: 2),
      );
      _artifactTransfer.validateNativeImportResult(raw);
      await _restartAfterManagementChange();
    });
  }

  @override
  Future<bool> pickAndImportLocalPlugin() async {
    _assertOpen();
    if (!_isAndroid) {
      throw const PluginRuntimeException(
        'unsupported',
        'The native Android package picker is unavailable on desktop.',
      );
    }
    try {
      final raw = await _channel.invokeMethod<Object?>('pickPlugin');
      if (raw == null) return false;
      final result = _nativeObject(raw, 'Native package picker result');
      final path = result['path'];
      if (path is! String || path.isEmpty) {
        throw const PluginRuntimeException(
          'invalid_response',
          'The native package picker returned an invalid result.',
        );
      }
      await importLocalPlugin(path);
      return true;
    } on PlatformException catch (error) {
      throw PluginRuntimeException(
        error.code,
        'The native source package could not be selected.',
        diagnostics: latestDiagnostics,
      );
    }
  }

  @override
  Future<Stream<List<int>>> exportPluginArtifact(
    PluginTransferArtifact artifact,
  ) => _artifactTransfer.exportPluginArtifact(artifact);

  @override
  Future<MaterializedPluginArtifact> materializePluginArtifact(
    PluginTransferOffer offer,
  ) => _artifactTransfer.materializePluginArtifact(offer);

  @override
  Future<PluginDevelopmentPackage> packageDevelopmentPlugin(
    String pluginId,
    String directoryPath,
  ) => _artifactTransfer.packageDevelopmentPlugin(pluginId, directoryPath);

  @override
  Future<List<PluginTransferImportResult>> importPluginArtifacts(
    List<({PluginTransferArtifact artifact, Stream<List<int>> bytes})>
    artifacts, {
    Set<String> forceUpgradePluginIds = const <String>{},
  }) => _artifactTransfer.importPluginArtifacts(
    artifacts,
    forceUpgradePluginIds: forceUpgradePluginIds,
  );

  @override
  Future<void> setDevelopmentDirectory(String path) => Future<void>.error(
    _unsupported('Native source development directories are unavailable.'),
  );

  @override
  Future<void> dispose() => _disposeFuture ??= _disposeCore();

  void _assertOpen() {
    if (_disposed) {
      throw const PluginRuntimeException(
        'runtime_unavailable',
        'The native Runtime has been closed.',
      );
    }
  }

  PluginRuntimeException _unsupported(String message) => PluginRuntimeException(
    'unsupported',
    message,
    diagnostics: latestDiagnostics,
  );

  void _record(RuntimeDiagnostic diagnostic) {
    if (_diagnostics.length >= _maxDiagnosticEntries) {
      _diagnostics.removeAt(0);
    }
    _diagnostics.add(diagnostic);
    if (!_diagnosticController.isClosed) {
      _diagnosticController.add(diagnostic);
    }
  }

  Future<_NativeRuntimeReady> _ensureStarted() async {
    _assertOpen();
    final cleanup = _cleanup;
    if (cleanup != null) await cleanup;
    if (_stopUnconfirmed) await _stopWorker();
    return _startup ??= _start();
  }

  Future<_NativeRuntimeReady> _start() async {
    WindowsJobObject? candidateJob;
    Process? candidateProcess;
    try {
      final testingUri = _testControlUri;
      if (testingUri != null) {
        final ready = _NativeRuntimeReady(
          port: testingUri.port,
          token: _testToken!,
        );
        _ready = ready;
        _processStartCount += 1;
        if (_pluginHttpProxyConfigured) {
          await _invokeReadyRpc(
            ready,
            method: 'runtime.native.proxy.v1',
            params: <String, Object?>{'url': _pluginHttpProxy?.toString()},
            timeout: const Duration(seconds: 5),
          );
        }
        return ready;
      }

      final token = _newToken();
      late final _NativeRuntimeReady ready;
      if (_isAndroid) {
        final response = await _channel
            .invokeMethod<Object?>('start', <String, Object?>{
              'token': token,
              if (_testMode) 'testMode': true,
            })
            .timeout(_startupTimeout);
        ready = _NativeRuntimeReady.fromMap(response, expectedToken: token);
      } else {
        final executable = _hostExecutable!;
        final dataRoot = _dataRoot!;
        if (!await executable.exists()) {
          throw const PluginRuntimeException(
            'runtime_native_host_missing',
            'The packaged native Runtime host is unavailable.',
          );
        }
        await dataRoot.create(recursive: true);
        candidateJob = Platform.isWindows ? WindowsJobObject.create() : null;
        _jobObject = candidateJob;
        candidateProcess = await Process.start(
          executable.path,
          <String>[
            '--root',
            dataRoot.path,
            '--token',
            token,
            if (_testMode) '--test-mode',
          ],
          environment: _nativeChildEnvironment(),
          includeParentEnvironment: false,
          runInShell: false,
          workingDirectory: executable.parent.path,
        );
        _process = candidateProcess;
        _processStartCount += 1;
        candidateJob?.assignProcess(candidateProcess.pid);
        final readyLine = Completer<String>();
        _stdoutSubscription = candidateProcess.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen(
              (line) {
                if (!readyLine.isCompleted) readyLine.complete(line);
              },
              onError: (Object _) {
                if (!readyLine.isCompleted) {
                  readyLine.completeError(
                    const FormatException('Missing native host ready record.'),
                  );
                }
              },
            );
        _stderrSubscription = candidateProcess.stderr.listen((_) {});
        unawaited(
          candidateProcess.exitCode.then(
            (code) => _onProcessExit(candidateProcess!, code, readyLine),
          ),
        );
        final line = await readyLine.future.timeout(_startupTimeout);
        ready = _NativeRuntimeReady.fromJsonLine(line, expectedToken: token);
        if (!identical(_process, candidateProcess)) {
          throw const PluginRuntimeException(
            'runtime_process_exited',
            'The native Runtime host exited during startup.',
          );
        }
      }
      _ready = ready;
      if (_pluginHttpProxyConfigured) {
        await _invokeReadyRpc(
          ready,
          method: 'runtime.native.proxy.v1',
          params: <String, Object?>{'url': _pluginHttpProxy?.toString()},
          timeout: const Duration(seconds: 5),
        );
      }
      return ready;
    } on PluginRuntimeException catch (error) {
      _record(
        RuntimeDiagnostic(
          code: error.code,
          level: RuntimeDiagnosticLevel.fatal,
          message: error.message,
        ),
      );
      await _stopWorker();
      _startup = null;
      rethrow;
    } on PlatformException catch (error) {
      final failure = PluginRuntimeException(
        error.code,
        'The Android native Runtime service could not start.',
        diagnostics: latestDiagnostics,
      );
      _record(
        RuntimeDiagnostic(
          code: failure.code,
          level: RuntimeDiagnosticLevel.fatal,
          message: failure.message,
        ),
      );
      await _stopWorker();
      _startup = null;
      throw failure;
    } on TimeoutException {
      const failure = PluginRuntimeException(
        'runtime_start_timeout',
        'The native Runtime host did not become ready in time.',
      );
      _record(
        const RuntimeDiagnostic(
          code: 'runtime_start_timeout',
          level: RuntimeDiagnosticLevel.fatal,
          message: 'The native Runtime host did not become ready in time.',
        ),
      );
      await _stopWorker();
      _startup = null;
      throw PluginRuntimeException(
        failure.code,
        failure.message,
        diagnostics: latestDiagnostics,
      );
    } on WindowsJobObjectException catch (error) {
      _record(
        RuntimeDiagnostic(
          code: error.code,
          level: RuntimeDiagnosticLevel.fatal,
          message: error.message,
        ),
      );
      await _stopWorker();
      _startup = null;
      throw PluginRuntimeException(
        error.code,
        'The native Runtime host could not be started with process ownership.',
        diagnostics: latestDiagnostics,
      );
    } on ProcessException catch (error) {
      final failure = PluginRuntimeException(
        'runtime_process_launch_failed',
        'The packaged native Runtime host could not be launched '
            '(OS error ${error.errorCode}).',
        diagnostics: latestDiagnostics,
      );
      _record(
        RuntimeDiagnostic(
          code: failure.code,
          level: RuntimeDiagnosticLevel.fatal,
          message: failure.message,
        ),
      );
      await _stopWorker();
      _startup = null;
      throw failure;
    } on Object {
      await _stopWorker();
      _startup = null;
      const failure = PluginRuntimeException(
        'runtime_start_failed',
        'The native Runtime host failed during startup.',
      );
      _record(
        RuntimeDiagnostic(
          code: failure.code,
          level: RuntimeDiagnosticLevel.fatal,
          message: failure.message,
        ),
      );
      throw PluginRuntimeException(
        failure.code,
        failure.message,
        diagnostics: latestDiagnostics,
      );
    }
  }

  Future<void> _disposeCore() async {
    if (_disposed) return;
    await _runLifecycleTransition<void>(() async {
      final ready = _ready;
      if (ready != null) {
        try {
          await _invokeRpc(
            method: 'runtime.native.shutdown.v1',
            params: const <String, Object?>{},
            timeout: _shutdownTimeout,
          );
        } on Object {
          // Process ownership remains the cleanup authority.
        }
      }
      _disposed = true;
      await _stopWorker();
    });
    if (!_diagnosticController.isClosed) await _diagnosticController.close();
    if (!_initializationController.isClosed) {
      await _initializationController.close();
    }
  }

  Future<void> _openPrivateDirectory() async {
    if (!Platform.isWindows || _dataRoot == null) {
      throw _unsupported(
        'Opening the native Runtime private directory is available on Windows only.',
      );
    }
    final dataRoot = _dataRoot;
    await dataRoot.create(recursive: true);
    try {
      await Process.start(
        'explorer.exe',
        <String>[dataRoot.path],
        mode: ProcessStartMode.detached,
        runInShell: false,
      );
    } on Object {
      throw const PluginRuntimeException(
        'runtime_private_directory_open_failed',
        'The native Runtime private directory could not be opened.',
      );
    }
  }

  Future<T> _runLifecycleTransition<T>(Future<T> Function() action) async {
    final previous = _lifecycleAdmissionTail;
    final finished = Completer<void>();
    _lifecycleAdmissionTail = finished.future;
    await previous;
    try {
      final active = _activeInvocationLeases;
      if (active > 0) {
        _inFlightDrained ??= Completer<void>();
        try {
          await _inFlightDrained!.future.timeout(_shutdownTimeout);
        } on TimeoutException {
          await _breakWorker(
            const PluginRuntimeException(
              'runtime_restarting',
              'Native worker is restarting.',
            ),
          );
          await _inFlightDrained!.future.timeout(_shutdownTimeout);
        }
      }
      return await action();
    } finally {
      _inFlightDrained = null;
      finished.complete();
    }
  }

  Future<_NativeInvocationLease> _acquireInvocationLease() async {
    while (true) {
      final tail = _lifecycleAdmissionTail;
      await tail;
      if (!identical(tail, _lifecycleAdmissionTail)) continue;
      _activeInvocationLeases += 1;
      return _NativeInvocationLease(() {
        _activeInvocationLeases -= 1;
        if (_activeInvocationLeases == 0 &&
            _inFlightDrained != null &&
            !_inFlightDrained!.isCompleted) {
          _inFlightDrained!.complete();
        }
      });
    }
  }

  bool _closeJobObject() {
    final job = _jobObject;
    _jobObject = null;
    if (job == null) return true;
    try {
      job.close();
      return true;
    } on WindowsJobObjectException catch (error) {
      _record(
        RuntimeDiagnostic(
          code: error.code,
          level: RuntimeDiagnosticLevel.error,
          message: error.message,
        ),
      );
      return false;
    }
  }
}

final class _NativeInvocationLease {
  _NativeInvocationLease(this._release);

  final VoidCallback _release;
  bool _released = false;

  void release() {
    if (_released) return;
    _released = true;
    _release();
  }
}

final class _NativeInFlight {
  final Completer<PluginRuntimeException> failure =
      Completer<PluginRuntimeException>();
  HttpClientRequest? request;
}

final class _NativeRuntimeReady {
  const _NativeRuntimeReady({required this.port, required this.token});

  final int port;
  final String token;

  factory _NativeRuntimeReady.fromJsonLine(
    String line, {
    required String expectedToken,
  }) => _NativeRuntimeReady.fromMap(
    jsonDecode(line),
    expectedToken: expectedToken,
  );

  factory _NativeRuntimeReady.fromMap(
    Object? raw, {
    required String expectedToken,
  }) {
    final value = _nativeObject(raw, 'Native Runtime ready record');
    final port = value['port'];
    final token = value['token'];
    if (port is! int ||
        port < 1 ||
        port > 65535 ||
        token is! String ||
        token != expectedToken ||
        value['runtimeKind'] != 'native-rust') {
      throw const FormatException('Invalid native Runtime ready record.');
    }
    return _NativeRuntimeReady(port: port, token: token);
  }
}

Map<String, String> _nativeChildEnvironment() {
  const names = <String>['LOCALAPPDATA', 'SystemRoot', 'TEMP', 'TMP', 'WINDIR'];
  final inherited = Platform.environment;
  return <String, String>{
    for (final name in names)
      if (inherited[name] case final value?) name: value,
  };
}

Map<String, Object?> _nativeObject(Object? value, String context) {
  if (value is Map<String, Object?>) return value;
  if (value is Map<Object?, Object?> &&
      value.keys.every((Object? key) => key is String)) {
    return value.cast<String, Object?>();
  }
  throw PluginRuntimeException(
    'invalid_response',
    'The native Runtime returned an invalid $context.',
  );
}

String _newToken() {
  final bytes = List<int>.generate(32, (_) => Random.secure().nextInt(256));
  return base64Url.encode(bytes).replaceAll('=', '');
}

Stream<List<int>> _nativeByteStream(List<int> bytes) async* {
  const chunkSize = 64 * 1024;
  for (var offset = 0; offset < bytes.length; offset += chunkSize) {
    final end = offset + chunkSize < bytes.length
        ? offset + chunkSize
        : bytes.length;
    yield bytes.sublist(offset, end);
  }
}

final List<int> _nativeCrc32Table = List<int>.generate(256, (index) {
  var value = index;
  for (var bit = 0; bit < 8; bit += 1) {
    value = value.isOdd ? 0xedb88320 ^ (value >>> 1) : value >>> 1;
  }
  return value;
}, growable: false);

String _nativeCrc32(List<int> bytes) {
  var checksum = 0xffffffff;
  for (final byte in bytes) {
    checksum = _nativeCrc32Table[(checksum ^ byte) & 0xff] ^ (checksum >>> 8);
  }
  return ((checksum ^ 0xffffffff) & 0xffffffff)
      .toRadixString(16)
      .padLeft(8, '0');
}
