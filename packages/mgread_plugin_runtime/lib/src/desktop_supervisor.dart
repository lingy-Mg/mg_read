part of mgread_plugin_runtime;

/// Exact Node version required by the current desktop bundle and ready record.
final String _expectedNodeVersion = Platform.isMacOS ? '24.16.0' : '26.10.0';

/// Version of the internal Runtime control protocol negotiated during hello.
const _protocolVersion = '1.2';

/// Upper bound for child startup and readiness probes.
// Release and Debug validate the selected workspace before reporting ready.
const _startupTimeout = Duration(seconds: 20);

/// Upper bound for a single already-connected control request.
const _controlTimeout = Duration(seconds: 5);

/// Bounded count of diagnostics retained for Flutter error presentation.
const _maxDiagnosticEntries = 32;

/// Maximum accepted message length from a structured child diagnostic record.
const _maxStructuredDiagnosticMessageLength = 256;

/// Hard cap for the pre-boot, Runtime-owned fallback evidence channel.
const _maxPreBootFallbackBytes = 16 * 1024;

/// Receives a diagnostic after the monitor validates the child record.
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
  _DesktopRuntimeSupervisor(this._bundle, {bool useEnvironmentProxy = false})
    : _developmentPluginDirectory = _bundle.developmentPluginDirectory,
      _useEnvironmentProxy = useEnvironmentProxy;

  /// Immutable package-owned inputs used for the only allowed child launch.
  final _DesktopRuntimeBundle _bundle;

  /// Broadcasts diagnostics; it is closed during dispose.
  final StreamController<RuntimeDiagnostic> _diagnosticController =
      StreamController<RuntimeDiagnostic>.broadcast();

  /// Broadcasts bounded import/startup progress without exposing paths.
  final StreamController<RuntimeInitializationProgress>
  _initializationController =
      StreamController<RuntimeInitializationProgress>.broadcast();

  final StreamController<DevelopmentPluginChangeBatch>
  _developmentChangeController =
      StreamController<DevelopmentPluginChangeBatch>.broadcast();

  /// Oldest-to-newest bounded snapshot used when constructing safe failures.
  final List<RuntimeDiagnostic> _diagnostics = <RuntimeDiagnostic>[];

  /// Negotiated connection after ready, HTTP probe, and hello all succeed.
  _WireConnection? _connection;
  Uri? _pluginHttpProxy;
  bool _useEnvironmentProxy;

  /// Prevents new work after cleanup starts and makes disposal idempotent.
  bool _disposed = false;

  /// Runtime-owned Windows lifetime handle for the child process tree.
  /// macOS owns the direct process and also enables the Node parent watchdog.
  WindowsJobObject? _jobObject;

  /// Parses the child's lifecycle streams and observes child exit.
  _RuntimeChildMonitor? _monitor;

  /// Test-only observable proof that concurrent calls share one launch.
  int _processStartCount = 0;

  /// Direct child handle retained only for orderly fallback cleanup.
  Process? _process;

  /// Memoized startup operation; concurrent invokes must await this one future.
  Future<_WireConnection>? _startup;

  /// Memoized cleanup operation; repeated dispose calls await one transition.
  Future<void>? _disposeFuture;

  /// Admission queue for lifecycle transitions. Ordinary calls only hold an
  /// invocation lease, so they remain concurrent inside one stable generation;
  /// a transition waits for those leases before advancing the generation.
  Future<void> _lifecycleAdmissionTail = Future<void>.value();
  int _activeInvocationLeases = 0;
  Completer<void>? _invocationsDrained;
  int _generation = 0;

  /// Monotonic timestamp for bounded, pre-boot failure timing evidence.
  DateTime? _startupStartedAt;

  /// Serializes bounded fallback appends without introducing another service.
  Future<void> _preBootFallbackWrites = Future<void>.value();

  bool _controlledRestarting = false;
  Directory? _developmentPluginDirectory;
  late final _DesktopPluginArtifactIo _pluginArtifactIo =
      _DesktopPluginArtifactIo(this);

  /// Package-test-only child launch count; not a public process handle.
  int get debugProcessStartCount => _processStartCount;

  @override
  Future<void> configureNodeEnvironmentProxy(bool enabled) async {
    if (_disposed) {
      throw const PluginRuntimeException(
        'runtime_unavailable',
        'The desktop Runtime has been closed.',
      );
    }
    await _runLifecycleTransition(() async {
      _useEnvironmentProxy = enabled;
      if (_process == null && _startup == null) return;
      final connection = _connection;
      if (connection != null) {
        try {
          await connection
              .request(
                method: 'runtime.shutdown',
                params: const <String, Object?>{},
                idempotencyKey: 'node-environment-proxy-change',
              )
              .timeout(_startupTimeout);
        } on Object {
          // Platform process ownership remains the bounded cleanup authority.
        }
        await connection.close();
        _connection = null;
      }
      await _terminateOwnedProcessTree();
      await _disposeMonitor();
      _startup = null;
      _recordDiagnostic(
        const RuntimeDiagnostic(
          code: 'runtime_node_environment_proxy_rebound',
          level: RuntimeDiagnosticLevel.info,
          message: 'The desktop Node environment proxy preference was rebound.',
        ),
      );
    }, shouldTransition: () => _useEnvironmentProxy != enabled);
  }

  @override
  Future<void> configurePluginHttpProxy(Uri? proxyUri) async {
    if (_pluginHttpProxy == proxyUri) return;
    _pluginHttpProxy = proxyUri;
    final connection = _connection;
    if (connection != null) await _applyPluginHttpProxy(connection);
  }

  Future<void> _applyPluginHttpProxy(_WireConnection connection) async {
    final result = _jsonObject(
      await connection.request(
        method: 'runtime.pluginHttpProxy.configure.v1',
        params: <String, Object?>{'proxyUrl': _pluginHttpProxy?.toString()},
      ),
      'Plugin HTTP proxy configuration result',
    );
    if (result.length != 1 || result['enabled'] != (_pluginHttpProxy != null)) {
      throw const PluginRuntimeException(
        'invalid_response',
        'The Runtime returned an invalid plugin HTTP proxy result.',
      );
    }
  }

  /// Stream of safe lifecycle diagnostics emitted after subscription.
  Stream<RuntimeDiagnostic> get diagnostics => _diagnosticController.stream;

  @override
  Stream<RuntimeInitializationProgress> get initialization =>
      _initializationController.stream;

  @override
  Stream<DevelopmentPluginChangeBatch> get developmentChanges =>
      _developmentChangeController.stream;

  /// Immutable copy of all currently retained diagnostics, oldest first.
  List<RuntimeDiagnostic> get latestDiagnostics =>
      List<RuntimeDiagnostic>.unmodifiable(_diagnostics);

  /// Starts the Runtime on demand and projects a typed capability result.
  Future<T> invoke<T>(
    PluginInvocation<T> invocation, {
    PluginInvocationCancellation? cancellation,
  }) async {
    if (_disposed) {
      throw const PluginRuntimeException(
        'runtime_unavailable',
        'The Runtime has been closed.',
      );
    }

    if (invocation is OpenPluginCodeDirectoryInvocation) {
      final lease = await _acquireInvocationLease();
      try {
        return await _openPluginCodeDirectory(
              invocation as OpenPluginCodeDirectoryInvocation,
            )
            as T;
      } finally {
        lease.release();
      }
    }

    if (invocation is OpenRuntimePrivateDirectoryInvocation) {
      await _openRuntimePrivateDirectory();
      return null as T;
    }

    final lease = await _acquireInvocationLease();
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
      // Source/capability errors must not restart the healthy singleton. A
      // disconnected bridge is terminal and can restart only on a later call.
      if (error.code == 'transport_disconnected') {
        _connection = null;
        _startup = null;
      }
      rethrow;
    } finally {
      lease.release();
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
  Future<MaterializedPluginArtifact> materializePluginArtifact(
    PluginTransferOffer offer,
  ) => _pluginArtifactIo.materializeArtifact(offer);

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
    artifacts, {
    Set<String> forceUpgradePluginIds = const <String>{},
  }) => _pluginArtifactIo.importArtifacts(
    artifacts,
    forceUpgradePluginIds: forceUpgradePluginIds,
  );

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
    await _restartForDevelopmentDirectoryChange();
  }

  Future<void> _restartForPluginImport() async {
    await _runLifecycleTransition(() async {
      await _restartForPluginImportCore();
      await _ensureStarted();
    });
  }

  Future<void> _restartForPluginImportCore() async {
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
  Future<void> dispose() => _disposeFuture ??= _disposeCore();

  Future<void> _disposeCore() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _generation += 1;
    await _runLifecycleTransition(() async {
      final connection = _connection;
      if (connection != null) {
        try {
          await connection
              .request(
                method: 'runtime.shutdown',
                params: const <String, Object?>{},
                idempotencyKey: 'facade-close',
              )
              .timeout(_controlTimeout);
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

      await _terminateOwnedProcessTree(force: true);
      await _disposeMonitor();
    }, allowDisposed: true);
    await _preBootFallbackWrites;
    await _diagnosticController.close();
    await _initializationController.close();
    await _developmentChangeController.close();
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

  void _recordDevelopmentChange(DevelopmentPluginChangeBatch change) {
    if (!_developmentChangeController.isClosed) {
      _developmentChangeController.add(change);
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
  /// 2. establish platform process ownership and launch Node;
  /// 3. parse the structured ready record and probe loopback HTTP; and
  /// 4. connect the internal WebSocket and validate `runtime.hello`.
  ///
  /// Every failure tears down partial state before exposing a safe error.
  Future<_WireConnection> _start() async {
    final generation = _generation;
    _WireConnection? candidateConnection;
    _startupStartedAt = DateTime.now();
    try {
      await _assertBundleAvailable();
      _assertStartupGeneration(generation);

      // The Job handle remains owned by this supervisor for the entire Flutter
      // process lifetime. If Flutter exits without executing dispose(), Windows
      // closes this handle and terminates the assigned Runtime process tree.
      final jobObject = Platform.isWindows ? WindowsJobObject.create() : null;
      _jobObject = jobObject;
      final process = await Process.start(
        _bundle.nodeExecutable.path,
        <String>[
          if (_developmentPluginDirectory != null) '--preserve-symlinks',
          if (_useEnvironmentProxy) '--use-env-proxy',
          _bundle.entrypoint.path,
          '--data-root=${_bundle.dataRoot.path}',
          if (Platform.isMacOS) '--parent-pid=$pid',
          // Keep the opt-in Runtime inspector available in release builds.
          // The listener remains disabled until the Runtime-owned preference
          // is explicitly enabled from the application.
          '--debug-http-enabled=1',
          if (_bundle.bundledPluginDirectory != null)
            '--bundled-plugin-root=${_bundle.bundledPluginDirectory!.path}',
          if (_developmentPluginDirectory != null)
            '--development-plugin-root=${_developmentPluginDirectory!.path}',
          if (_developmentPluginDirectory != null)
            '--development-npm-cli=${_bundle.developmentNpmCli!.path}',
          if (_bundle.testExitAfterReady != null)
            '--test-exit-after-ready-millis='
                '${_bundle.testExitAfterReady!.inMilliseconds}',
        ],
        environment: _allowlistedEnvironment(
          useEnvironmentProxy: _useEnvironmentProxy,
        ),
        includeParentEnvironment: false,
        runInShell: false,
        workingDirectory: _bundle.workingDirectory.path,
      );
      _process = process;
      _processStartCount += 1;
      _assertStartupGeneration(generation);

      // Windows development builds may spawn the pinned npm child. Assign the
      // Core first so every Windows descendant belongs to the same Job. macOS
      // binds the same child tree through the parent watchdog.
      jobObject?.assignProcess(process.pid);

      final monitor = _RuntimeChildMonitor(
        process,
        onDiagnostic: _recordDiagnostic,
        onProgress: _recordInitializationProgress,
        onExit: _handleProcessExit,
        onPreBootFatal: _recordPreBootFatal,
        startupFailure: _failure,
      );
      _monitor = monitor;

      final startupDeadline = _startupStartedAt!.add(_startupTimeout);
      final ready = await monitor.waitForReady(startupDeadline);
      _assertStartupGeneration(generation);
      await _probeHttpReady(ready, deadline: startupDeadline);
      _assertStartupGeneration(generation);
      final connection = await _WireConnection.connect(
        ready,
        dataRoot: _bundle.dataRoot,
        onDevelopmentChange: _recordDevelopmentChange,
      );
      candidateConnection = connection;
      await connection.hello();
      _assertStartupGeneration(generation);
      await _applyPluginHttpProxy(connection);
      _assertStartupGeneration(generation);
      _connection = connection;
      candidateConnection = null;
      return connection;
    } on PluginRuntimeException catch (error) {
      if (!_diagnostics.any(
        (diagnostic) => diagnostic.code == error.code && diagnostic.isFatal,
      )) {
        _recordFatal(error.code, error.message);
      }
      _recordPreBootFatal(error.code, 'startup');
      await _stopFailedStart(candidateConnection);
      _startup = null;
      throw _failure(error.code, error.message);
    } on WindowsJobObjectException catch (error) {
      _recordFatal(error.code, error.message);
      await _stopFailedStart(candidateConnection);
      _startup = null;
      _recordPreBootFatal(error.code, 'processOwnership');
      throw _failure(
        error.code,
        'The desktop Runtime could not be started with required process ownership.',
      );
    } on ProcessException catch (error) {
      final osErrorCode = error.errorCode;
      _recordFatal(
        'runtime_process_launch_failed',
        'The packaged desktop Runtime process could not be launched '
            '(OS error $osErrorCode).',
      );
      await _stopFailedStart(candidateConnection);
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
      await _stopFailedStart(candidateConnection);
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
        'The desktop development source directory is unavailable.',
      );
    }
    final developmentNpmCli = _bundle.developmentNpmCli;
    if (developmentPluginDirectory != null &&
        (developmentNpmCli == null || !await developmentNpmCli.exists())) {
      throw _failure(
        'runtime_development_build_tool_missing',
        'The pinned desktop development build tool is unavailable.',
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
    if (!_disposed && !_controlledRestarting) {
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

  /// Closes any partial transport and child tree after a failed startup phase.
  Future<void> _stopFailedStart([_WireConnection? candidateConnection]) async {
    if (candidateConnection != null &&
        !identical(candidateConnection, _connection)) {
      try {
        await candidateConnection.close();
      } on Object {
        // Process ownership cleanup below remains authoritative.
      }
    }
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

    // The Runtime control response is sent before Core shutdown completes.
    // On macOS, SIGTERM enters the same idempotent Node cleanup path and also
    // clears the parent watchdog so graceful disposal does not wait on it.
    if (!force && Platform.isMacOS) {
      process.kill(ProcessSignal.sigterm);
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
    if (!closedJob || !Platform.isWindows) {
      process.kill();
    }
    if (!await _waitForProcessExit(process)) {
      process.kill();
      await _waitForProcessExit(process);
    }
    _process = null;
  }

  /// Releases the Job handle and records a diagnostic if that fails.
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

  /// Retains and broadcasts one diagnostic without unbounded growth.
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
