part of mgread_plugin_runtime;

/// Exact Node version required by both the staged bundle and ready record.
const _expectedNodeVersion = '24.16.0';

/// Version of the internal Runtime control protocol negotiated during hello.
const _protocolVersion = '1.1';

/// Upper bound for child startup and readiness probes.
// Release may install defaults before ready; Debug validates workspace projects.
const _startupTimeout = Duration(seconds: 20);

/// Upper bound for a single already-connected control request.
const _controlTimeout = Duration(seconds: 5);

/// Bounded count of safe diagnostics retained for Flutter error presentation.
const _maxDiagnosticEntries = 32;

/// Maximum accepted message length from a structured child diagnostic record.
const _maxStructuredDiagnosticMessageLength = 256;

/// Hard cap for the pre-boot, Runtime-owned fallback evidence channel.
const _maxPreBootFallbackBytes = 16 * 1024;

/// Receives a safe diagnostic after the monitor validates the child record.
typedef _RuntimeDiagnosticSink = void Function(RuntimeDiagnostic diagnostic);

/// Receives a bounded, already-safe Runtime progress event.
typedef _RuntimeInitializationSink =
    void Function(RuntimeInitializationProgress progress);

/// Reports child termination together with whether readiness was already seen.
typedef _RuntimeProcessExitSink = void Function(int exitCode, bool wasReady);

/// Reports a startup terminal before the Node diagnostics service exists.
typedef _RuntimePreBootFatalSink = void Function(String code, String phase);

/// Creates a Facade-safe startup exception with the current diagnostic snapshot.
typedef _RuntimeStartupFailureFactory =
    PluginRuntimeException Function(String code, String message);

/// Testable Runtime-package-owned Windows shell action.
typedef _DesktopDirectoryLauncher = Future<void> Function(Directory directory);

/// Immutable locations of the Runtime files owned and launched by this package.
///
/// The values are never supplied by the host application. Production resolves
/// a staged package bundle; test construction is intentionally isolated below.
final class _DesktopRuntimeSupervisor implements _RuntimeSupervisor {
  _DesktopRuntimeSupervisor(this._bundle)
    : _developmentPluginDirectory = _bundle.developmentPluginDirectory;

  /// Immutable package-owned inputs used for the only allowed child launch.
  final _DesktopRuntimeBundle _bundle;

  /// Broadcasts already-redacted diagnostics; it is closed during dispose.
  final StreamController<RuntimeDiagnostic> _diagnosticController =
      StreamController<RuntimeDiagnostic>.broadcast();

  /// Broadcasts bounded import/startup progress without exposing paths.
  final StreamController<RuntimeInitializationProgress>
  _initializationController =
      StreamController<RuntimeInitializationProgress>.broadcast();

  /// Oldest-to-newest bounded snapshot used when constructing safe failures.
  final List<RuntimeDiagnostic> _diagnostics = <RuntimeDiagnostic>[];

  /// Negotiated connection after ready, HTTP probe, and hello all succeed.
  _WireConnection? _connection;

  /// Prevents new work after cleanup starts and makes disposal idempotent.
  bool _disposed = false;

  /// Runtime-owned Windows lifetime handle for the child process tree.
  WindowsJobObject? _jobObject;

  /// Parses the child's lifecycle streams and observes child exit.
  _RuntimeChildMonitor? _monitor;

  /// Test-only observable proof that concurrent calls share one launch.
  int _processStartCount = 0;

  /// Direct child handle retained only for orderly fallback cleanup.
  Process? _process;

  /// Memoized startup operation; concurrent invokes must await this one future.
  Future<_WireConnection>? _startup;

  /// Monotonic timestamp for bounded, pre-boot failure timing evidence.
  DateTime? _startupStartedAt;

  /// Serializes bounded fallback appends without introducing another service.
  Future<void> _preBootFallbackWrites = Future<void>.value();

  /// Serializes debug fingerprint checks and clean one-VM-at-a-time restarts.
  Future<void> _developmentSynchronization = Future<void>.value();
  String? _developmentFingerprint;
  bool _developmentRestarting = false;
  bool _controlledRestarting = false;
  Directory? _developmentPluginDirectory;
  late final _DesktopPluginArtifactIo _pluginArtifactIo =
      _DesktopPluginArtifactIo(this);

  /// Package-test-only child launch count; not a public process handle.
  int get debugProcessStartCount => _processStartCount;

  /// Stream of safe lifecycle diagnostics emitted after subscription.
  Stream<RuntimeDiagnostic> get diagnostics => _diagnosticController.stream;

  @override
  Stream<RuntimeInitializationProgress> get initialization =>
      _initializationController.stream;

  /// Immutable copy of all currently retained diagnostics, oldest first.
  List<RuntimeDiagnostic> get latestDiagnostics =>
      List<RuntimeDiagnostic>.unmodifiable(_diagnostics);

  /// Starts the Runtime on demand and projects a typed capability result.
  Future<T> invoke<T>(PluginInvocation<T> invocation) async {
    if (_disposed) {
      throw const PluginRuntimeException(
        'runtime_unavailable',
        'The Runtime has been closed.',
      );
    }

    if (invocation is OpenPluginCodeDirectoryInvocation) {
      return await _openPluginCodeDirectory(
            invocation as OpenPluginCodeDirectoryInvocation,
          )
          as T;
    }

    if (invocation is OpenRuntimePrivateDirectoryInvocation) {
      await _openRuntimePrivateDirectory();
      return null as T;
    }

    await _synchronizeDevelopmentRuntime();
    try {
      final connection = await _ensureStarted();
      final result = await connection.request(
        method: invocation._wireMethod,
        params: invocation._wireParams,
        timeout: invocation._timeout,
      );
      return invocation._decodeResult(result);
    } on PluginRuntimeException catch (error) {
      // Source/capability errors must not restart the healthy singleton. A
      // disconnected bridge is terminal and can restart only on a later call.
      if (error.code == 'transport_disconnected') {
        _connection = null;
        _startup = null;
      }
      rethrow;
    }
  }

  /// Opens the private root without routing a shell action through the Node child.
  Future<void> _openRuntimePrivateDirectory() async {
    try {
      await _bundle.directoryLauncher(_bundle.dataRoot);
    } on Object {
      const diagnostic = RuntimeDiagnostic(
        code: 'runtime_private_directory_open_failed',
        level: RuntimeDiagnosticLevel.error,
        message: 'The Runtime private directory could not be opened.',
      );
      _recordDiagnostic(diagnostic);
      throw _failure(diagnostic.code, diagnostic.message);
    }
  }

  /// Resolves the source directory in Node, then launches Explorer from the
  /// Flutter owner so it is outside the Node Windows Job Object.
  Future<PluginCodeDirectoryKind> _openPluginCodeDirectory(
    OpenPluginCodeDirectoryInvocation invocation,
  ) async {
    await _synchronizeDevelopmentRuntime();
    final connection = await _ensureStarted();
    final raw = await connection.request(
      method: invocation._wireMethod,
      params: invocation._wireParams,
      timeout: invocation._timeout,
    );
    final result = _jsonObject(raw, 'Plugin code directory result');
    final directory = result['directory'];
    final kind = switch (result['kind']) {
      'development' => PluginCodeDirectoryKind.development,
      'installed' => PluginCodeDirectoryKind.installed,
      _ => null,
    };
    if (directory is! String || directory.isEmpty || kind == null) {
      throw const PluginRuntimeException(
        'invalid_response',
        'The Runtime returned an invalid plugin code directory result.',
      );
    }
    try {
      await _bundle.directoryLauncher(Directory(directory));
    } on Object {
      const diagnostic = RuntimeDiagnostic(
        code: 'plugin_code_directory_open_failed',
        level: RuntimeDiagnosticLevel.error,
        message: 'The plugin code directory could not be opened.',
      );
      _recordDiagnostic(diagnostic);
      throw _failure(diagnostic.code, diagnostic.message);
    }
    return kind;
  }

  @override
  Future<bool> pickAndImportLocalPlugin() {
    throw const PluginRuntimeException(
      'unsupported',
      'The Android file picker is unavailable on desktop.',
    );
  }

  @override
  Future<Stream<List<int>>> exportPluginArtifact(
    PluginTransferArtifact artifact,
  ) => _pluginArtifactIo.exportArtifact(artifact);

  @override
  Future<PluginDevelopmentPackage> packageDevelopmentPlugin(
    String pluginId,
    String directoryPath,
  ) => _pluginArtifactIo.packageDevelopmentPlugin(
    pluginId,
    Directory(directoryPath),
  );

  @override
  Future<List<PluginTransferImportResult>> importPluginArtifacts(
    List<({PluginTransferArtifact artifact, Stream<List<int>> bytes})>
    artifacts,
  ) => _pluginArtifactIo.importArtifacts(artifacts);

  @override
  Future<void> importLocalPlugin(String sourcePath) =>
      _pluginArtifactIo.importLocalArtifact(sourcePath);

  @override
  Future<void> setDevelopmentDirectory(String path) async {
    if (_disposed) {
      throw const PluginRuntimeException(
        'runtime_unavailable',
        'The desktop Runtime has been closed.',
      );
    }
    if (!kDebugMode) {
      throw const PluginRuntimeException(
        'unsupported',
        'Development source directories are available in Windows Debug only.',
      );
    }
    final directory = Directory(path);
    if (!await directory.exists()) {
      throw const PluginRuntimeException(
        'not_found',
        'The selected development directory is unavailable.',
      );
    }
    try {
      await _writeConfiguredDevelopmentPluginDirectory(
        _bundle.dataRoot,
        directory.path,
      );
    } on FileSystemException {
      throw const PluginRuntimeException(
        'disk_full',
        'The development directory could not be saved.',
      );
    }
    _developmentPluginDirectory = directory;
    _developmentFingerprint = null;
    await _restartForDevelopmentChange();
  }

  Future<void> _restartForPluginImport() async {
    final connection = _connection;
    if (connection == null) return;
    try {
      await connection
          .request(
            method: 'runtime.shutdown',
            params: const <String, Object?>{},
            idempotencyKey: 'local-plugin-import',
          )
          .timeout(_startupTimeout);
    } on Object {
      // The owned Job Object remains the authoritative cleanup path.
    }
    await connection.close();
    _connection = null;
    await _terminateOwnedProcessTree();
    await _disposeMonitor();
    _startup = null;
  }

  ///
  /// Gracefully asks the Core to stop, then guarantees child-tree cleanup.
  ///
  /// A graceful acknowledgement is useful but never required for ownership
  /// cleanup: closing the Job Object is the authoritative Windows hard stop.
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;

    final connection = _connection;
    if (connection != null) {
      try {
        await connection
            .request(
              method: 'runtime.shutdown',
              params: const <String, Object?>{},
              idempotencyKey: 'facade-close',
            )
            .timeout(_startupTimeout);
      } on Object {
        _recordDiagnostic(
          const RuntimeDiagnostic(
            code: 'runtime_shutdown_request_failed',
            level: RuntimeDiagnosticLevel.warning,
            message:
                'The Runtime did not acknowledge its graceful shutdown request.',
          ),
        );
      }
      await connection.close();
      _connection = null;
    }

    await _terminateOwnedProcessTree();
    await _disposeMonitor();
    await _diagnosticController.close();
    await _initializationController.close();
  }

  void _emitInitializationProgress({
    required int completedBytes,
    required String stage,
    required int totalBytes,
  }) {
    final progress = RuntimeInitializationProgress.fromPlatform(
      completedBytes: completedBytes,
      stage: stage,
      totalBytes: totalBytes,
    );
    if (progress != null && !_initializationController.isClosed) {
      _initializationController.add(progress);
    }
  }

  void _recordInitializationProgress(RuntimeInitializationProgress progress) {
    if (!_initializationController.isClosed) {
      _initializationController.add(progress);
    }
  }

  /// Returns the shared startup future, preventing concurrent duplicate cores.
  Future<_WireConnection> _ensureStarted() {
    return _startup ??= _start();
  }

  ///
  /// Performs the fixed startup sequence:
  ///
  /// 1. verify package-owned Node and entrypoint files;
  /// 2. create a kill-on-close Windows Job and launch Node into it;
  /// 3. parse the structured ready record and probe loopback HTTP; and
  /// 4. connect the internal WebSocket and validate `runtime.hello`.
  ///
  /// Every failure tears down partial state before exposing a safe error.
  Future<_WireConnection> _start() async {
    _startupStartedAt = DateTime.now();
    try {
      await _assertBundleAvailable();

      // The Job handle remains owned by this supervisor for the entire Flutter
      // process lifetime. If Flutter exits without executing dispose(), Windows
      // closes this handle and terminates the assigned Runtime process tree.
      final jobObject = WindowsJobObject.create();
      _jobObject = jobObject;
      final process = await Process.start(
        _bundle.nodeExecutable.path,
        <String>[
          '--use-env-proxy',
          _bundle.entrypoint.path,
          '--data-root=${_bundle.dataRoot.path}',
          if (kDebugMode) '--debug-http-enabled=1',
          if (_bundle.bundledPluginDirectory != null)
            '--bundled-plugin-root=${_bundle.bundledPluginDirectory!.path}',
          if (_developmentPluginDirectory != null)
            '--development-plugin-root=${_developmentPluginDirectory!.path}',
          if (_bundle.testExitAfterReady != null)
            '--test-exit-after-ready-millis='
                '${_bundle.testExitAfterReady!.inMilliseconds}',
        ],
        environment: _allowlistedEnvironment(),
        includeParentEnvironment: false,
        runInShell: false,
        workingDirectory: _bundle.workingDirectory.path,
      );
      _process = process;
      _processStartCount += 1;

      // The Core is forbidden from spawning child processes. Assign it before
      // consuming startup output so every permitted later descendant belongs to
      // the Job and is kernel-terminated with the Flutter owner.
      jobObject.assignProcess(process.pid);

      final monitor = _RuntimeChildMonitor(
        process,
        onDiagnostic: _recordDiagnostic,
        onProgress: _recordInitializationProgress,
        onExit: _handleProcessExit,
        onPreBootFatal: _recordPreBootFatal,
        startupFailure: _failure,
      );
      _monitor = monitor;

      final ready = await monitor.waitForReady();
      await _probeHttpReady(ready);
      final connection = await _WireConnection.connect(
        ready,
        dataRoot: _bundle.dataRoot,
      );
      await connection.hello();
      _connection = connection;
      return connection;
    } on PluginRuntimeException catch (error) {
      if (!_diagnostics.any(
        (diagnostic) => diagnostic.code == error.code && diagnostic.isFatal,
      )) {
        _recordFatal(error.code, error.message);
      }
      _recordPreBootFatal(error.code, 'startup');
      await _stopFailedStart();
      _startup = null;
      throw _failure(error.code, error.message);
    } on WindowsJobObjectException catch (error) {
      _recordFatal(error.code, error.message);
      await _stopFailedStart();
      _startup = null;
      _recordPreBootFatal(error.code, 'processOwnership');
      throw _failure(
        error.code,
        'The desktop Runtime could not be started with required process ownership.',
      );
    } on ProcessException {
      _recordFatal(
        'runtime_process_launch_failed',
        'The packaged desktop Runtime process could not be launched.',
      );
      await _stopFailedStart();
      _startup = null;
      _recordPreBootFatal('runtime_process_launch_failed', 'launch');
      throw _failure(
        'runtime_process_launch_failed',
        'The packaged desktop Runtime process could not be launched.',
      );
    } on Object {
      _recordFatal(
        'runtime_start_failed',
        'The desktop Runtime failed during startup.',
      );
      await _stopFailedStart();
      _startup = null;
      _recordPreBootFatal('runtime_start_failed', 'startup');
      throw _failure(
        'runtime_start_failed',
        'The desktop Runtime could not be started.',
      );
    }
  }

  /// Checks only package-owned launch files before any child process exists.
  Future<void> _assertBundleAvailable() async {
    if (!await _bundle.nodeExecutable.exists()) {
      _recordDiagnostic(
        const RuntimeDiagnostic(
          code: 'runtime_node_executable_missing',
          level: RuntimeDiagnosticLevel.error,
          message: 'The packaged desktop Node executable is missing.',
        ),
      );
      throw _failure(
        'runtime_node_executable_missing',
        'The packaged desktop Node executable is unavailable.',
      );
    }
    if (!await _bundle.entrypoint.exists()) {
      _recordDiagnostic(
        const RuntimeDiagnostic(
          code: 'runtime_entrypoint_missing',
          level: RuntimeDiagnosticLevel.error,
          message: 'The packaged desktop Runtime main script is missing.',
        ),
      );
      throw _failure(
        'runtime_entrypoint_missing',
        'The packaged desktop Runtime main script is unavailable.',
      );
    }
    final bundledPluginDirectory = _bundle.bundledPluginDirectory;
    if (bundledPluginDirectory != null &&
        !await bundledPluginDirectory.exists()) {
      _recordDiagnostic(
        const RuntimeDiagnostic(
          code: 'runtime_bundled_plugin_assets_missing',
          level: RuntimeDiagnosticLevel.error,
          message: 'The packaged default source assets are missing.',
        ),
      );
      throw _failure(
        'runtime_bundled_plugin_assets_missing',
        'The packaged default source assets are unavailable.',
      );
    }
    final developmentPluginDirectory = _developmentPluginDirectory;
    if (developmentPluginDirectory != null &&
        !await developmentPluginDirectory.exists()) {
      throw _failure(
        'runtime_development_plugin_root_missing',
        'The Windows development source directory is unavailable.',
      );
    }
  }

  /// Converts a post-ready child exit into a safe transport failure/diagnostic.
  void _handleProcessExit(int exitCode, bool wasReady) {
    if (!wasReady) return;
    _connection?.markProcessExited();
    _connection = null;
    _startup = null;
    _process = null;
    _closeJobObject();
    if (!_disposed && !_developmentRestarting && !_controlledRestarting) {
      _recordFatal(
        'runtime_process_exited',
        'The desktop Runtime process exited unexpectedly.',
      );
    }
  }

  /// Appends only bounded, safe startup evidence before Node diagnostics opens.
  ///
  /// This channel deliberately has no exception, stderr, path, request, or
  /// plugin fields. A write failure is observational and cannot alter startup.
  void _recordPreBootFatal(String code, String phase) {
    final startedAt = _startupStartedAt;
    final elapsedMillis = startedAt == null
        ? 0
        : DateTime.now().difference(startedAt).inMilliseconds.clamp(0, 60000);
    final fingerprint =
        '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
        '-${Random.secure().nextInt(1 << 32).toRadixString(36)}';
    final line = jsonEncode(<String, Object?>{
      'v': 1,
      'code': code,
      'phase': phase,
      'fingerprint': fingerprint,
      'elapsedMillis': elapsedMillis,
    });
    final previous = _preBootFallbackWrites;
    _preBootFallbackWrites = previous.then((_) => _appendPreBootFallback(line));
    unawaited(_preBootFallbackWrites);
  }

  Future<void> _appendPreBootFallback(String line) async {
    try {
      final directory = Directory(
        _joinPath(<String>[_bundle.dataRoot.path, 'diagnostics']),
      );
      await directory.create(recursive: true);
      final file = File(
        _joinPath(<String>[directory.path, 'desktop-fatal-fallback.txt']),
      );
      final bytes = utf8.encode('$line\n');
      if (bytes.length > _maxPreBootFallbackBytes) return;
      final length = await file.exists() ? await file.length() : 0;
      if (length + bytes.length > _maxPreBootFallbackBytes) {
        await file.writeAsBytes(bytes, flush: true);
      } else {
        await file.writeAsBytes(bytes, mode: FileMode.append, flush: true);
      }
    } on Object {
      // The fallback channel is strictly best effort and must not recurse.
    }
  }

  ///
  /// Confirms that stdout-ready, HTTP, and version identity all belong to one
  /// Runtime Core before the WebSocket is trusted.
  ///
  /// The short retry exists solely for the child-internal race between writing
  /// stdout and accepting loopback HTTP. It does not retry a failed launch.
  Future<void> _probeHttpReady(_RuntimeReady ready) async {
    final client = HttpClient();
    final deadline = DateTime.now().add(_startupTimeout);
    try {
      while (DateTime.now().isBefore(deadline)) {
        try {
          final request = await client.getUrl(
            Uri(
              scheme: 'http',
              host: ready.host,
              port: ready.port,
              path: '/health/ready',
            ),
          );
          final response = await request.close();
          final body = await utf8.decoder.bind(response).join();
          if (response.statusCode == HttpStatus.ok) {
            final decoded = _jsonObject(
              jsonDecode(body),
              'Runtime health response',
            );
            if (decoded['status'] == 'ready' &&
                decoded['bootId'] == ready.bootId &&
                decoded['nodeVersion'] == _expectedNodeVersion &&
                decoded['protocolVersion'] == _protocolVersion) {
              return;
            }
          }
        } on Object {
          // The ready signal and HTTP server race only inside the owned Runtime.
        }
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    } finally {
      client.close(force: true);
    }

    _recordDiagnostic(
      const RuntimeDiagnostic(
        code: 'runtime_http_readiness_failed',
        level: RuntimeDiagnosticLevel.error,
        message: 'The desktop Runtime did not pass its HTTP readiness check.',
      ),
    );
    throw _failure(
      'runtime_not_ready',
      'The desktop Runtime did not pass its readiness check.',
    );
  }

  /// Closes any partial transport and child tree after a failed startup phase.
  Future<void> _stopFailedStart() async {
    final connection = _connection;
    if (connection != null) {
      await connection.close();
      _connection = null;
    }
    await _terminateOwnedProcessTree(force: true);
    await _disposeMonitor();
  }

  ///
  /// Stops the directly launched child and all of its descendants.
  ///
  /// The normal path first gives the graceful shutdown request time to exit.
  /// Forced startup cleanup closes the Job immediately. If Windows refuses the
  /// Job close, the direct child is still killed as a narrow fallback.
  Future<void> _terminateOwnedProcessTree({bool force = false}) async {
    final process = _process;
    if (process == null) {
      _closeJobObject();
      return;
    }

    if (!force && await _waitForProcessExit(process)) {
      _process = null;
      _closeJobObject();
      return;
    }

    final closedJob = _closeJobObject();

    // Closing the Job is the primary hard-stop mechanism. Retain a direct
    // owned-child fallback if Windows rejected a close or an unexpected host
    // policy prevented Job cleanup.
    if (!closedJob) {
      process.kill();
    }
    if (!await _waitForProcessExit(process)) {
      process.kill();
      await _waitForProcessExit(process);
    }
    _process = null;
  }

  /// Releases the Job handle and records a safe diagnostic if that fails.
  bool _closeJobObject() {
    final jobObject = _jobObject;
    _jobObject = null;
    if (jobObject == null) {
      return true;
    }
    try {
      jobObject.close();
      return true;
    } on WindowsJobObjectException catch (error) {
      _recordDiagnostic(
        RuntimeDiagnostic(
          code: error.code,
          level: RuntimeDiagnosticLevel.error,
          message: error.message,
        ),
      );
      return false;
    }
  }

  /// Waits only for the shared bounded timeout and never throws a timeout.
  Future<bool> _waitForProcessExit(Process process) async {
    try {
      await process.exitCode.timeout(_startupTimeout);
      return true;
    } on TimeoutException {
      return false;
    }
  }

  /// Stops consuming child stdout/stderr once no more lifecycle data is useful.
  Future<void> _disposeMonitor() async {
    final monitor = _monitor;
    _monitor = null;
    if (monitor != null) {
      await monitor.dispose();
    }
  }

  /// Builds a stable Facade exception with an immutable diagnostic copy.
  PluginRuntimeException _failure(String code, String message) {
    return PluginRuntimeException(
      code,
      message,
      diagnostics: latestDiagnostics,
    );
  }

  /// Retains and broadcasts one already-safe diagnostic without unbounded growth.
  void _recordDiagnostic(RuntimeDiagnostic diagnostic) {
    if (_diagnostics.length == _maxDiagnosticEntries) {
      _diagnostics.removeAt(0);
    }
    _diagnostics.add(diagnostic);
    if (!_diagnosticController.isClosed) {
      _diagnosticController.add(diagnostic);
    }
  }

  void _recordFatal(String code, String message) {
    _recordDiagnostic(
      RuntimeDiagnostic(
        code: code,
        level: RuntimeDiagnosticLevel.fatal,
        message: message,
      ),
    );
  }
}

/// Converts the owned child's stdout/stderr/exit events into safe lifecycle data.
///
/// Stdout has one special pre-ready record. All other accepted child output must
/// be a bounded structured diagnostic; raw text is never forwarded to Flutter.
