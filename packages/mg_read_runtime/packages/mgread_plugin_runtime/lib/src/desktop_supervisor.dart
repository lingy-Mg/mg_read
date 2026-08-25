part of mgread_plugin_runtime;

/// Exact Node version required by both the staged bundle and ready record.
const _expectedNodeVersion = '24.16.0';

/// Version of the internal Runtime control protocol negotiated during hello.
const _protocolVersion = '1.0';

/// Upper bound for child startup and readiness probes.
// A new release Runtime data root can install packaged defaults before ready;
// debug builds instead validate directly loaded workspace projects.
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
final class _DesktopRuntimeBundle {
  const _DesktopRuntimeBundle({
    required this.dataRoot,
    required this.bundledPluginDirectory,
    required this.developmentPluginDirectory,
    required this.directoryLauncher,
    required this.entrypoint,
    required this.nodeExecutable,
    required this.testExitAfterReady,
    required this.workingDirectory,
  });

  /// Runtime-owned writable root; never returned through the public Facade.
  final Directory dataRoot;

  /// Packaged first-run source archives, never visible to the main app.
  final Directory? bundledPluginDirectory;

  /// Debug-only workspace projects loaded directly without installation.
  final Directory? developmentPluginDirectory;

  /// Opens a Runtime-owned directory through the Flutter Windows shell layer.
  final _DesktopDirectoryLauncher directoryLauncher;

  /// Compiled Node executable entrypoint that emits ready/diagnostic records.
  final File entrypoint;

  /// Exact packaged Node executable; never resolved from the ambient PATH.
  final File nodeExecutable;

  /// Test-only crash fixture delay; production bundles always leave this null.
  final Duration? testExitAfterReady;

  /// Bundle root used as the child process current working directory.
  final Directory workingDirectory;

  /// Resolves the fixed Windows bundle staged into a Flutter application.
  factory _DesktopRuntimeBundle.fromApplicationPackage() {
    if (!Platform.isWindows) {
      throw const PluginRuntimeException(
        'unsupported',
        'This Runtime package currently has no launcher for this platform.',
      );
    }

    final appDirectory = File(Platform.resolvedExecutable).parent;
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData == null || localAppData.isEmpty) {
      throw const PluginRuntimeException(
        'runtime_data_root_unavailable',
        'The Runtime could not resolve its application data directory.',
      );
    }
    final bundleRoot = Directory(
      _joinPath(<String>[
        appDirectory.path,
        'data',
        'flutter_assets',
        'packages',
        'mgread_plugin_runtime',
        'assets',
        'runtime',
        'windows-x64',
      ]),
    );
    final dataRoot = Directory(
      _joinPath(<String>[localAppData, 'MgRead', 'runtime']),
    );
    final developmentPluginDirectory = kDebugMode
        ? _readConfiguredDevelopmentPluginDirectory(dataRoot) ??
              _findDevelopmentPluginDirectory(<Directory>[
                Directory.current,
                appDirectory,
              ])
        : null;
    return _DesktopRuntimeBundle(
      dataRoot: dataRoot,
      bundledPluginDirectory: null,
      developmentPluginDirectory: developmentPluginDirectory,
      directoryLauncher: _openWithWindowsExplorer,
      entrypoint: File(_joinPath(<String>[bundleRoot.path, 'dist', 'cli.js'])),
      nodeExecutable: File(
        _joinPath(<String>[bundleRoot.path, 'node', 'MgReadNode.exe']),
      ),
      testExitAfterReady: null,
      workingDirectory: bundleRoot,
    );
  }

  /// Resolves test-only files from this Runtime repository.
  ///
  /// Overrides are limited to deliberately broken package-owned fixtures (such
  /// as a missing Node executable); they never form a production injection API.
  factory _DesktopRuntimeBundle.fromRepositoryForTest(
    Directory runtimeRepositoryRoot, {
    File? entrypointOverride,
    File? nodeExecutableOverride,
    Directory? runtimeDataRoot,
    Directory? developmentPluginDirectory,
    _DesktopDirectoryLauncher? directoryLauncher,
    Duration? testExitAfterReady,
  }) {
    return _DesktopRuntimeBundle(
      dataRoot:
          runtimeDataRoot ??
          Directory(
            _joinPath(<String>[
              Directory.systemTemp.path,
              'mgread-runtime-tests',
              DateTime.now().microsecondsSinceEpoch.toString(),
            ]),
          ),
      bundledPluginDirectory: null,
      developmentPluginDirectory: developmentPluginDirectory,
      directoryLauncher: directoryLauncher ?? _discardDirectoryOpen,
      entrypoint:
          entrypointOverride ??
          File(
            _joinPath(<String>[runtimeRepositoryRoot.path, 'dist', 'cli.js']),
          ),
      nodeExecutable:
          nodeExecutableOverride ??
          File(
            _joinPath(<String>[
              runtimeRepositoryRoot.path,
              'tools',
              'node-v24.16.0-win-x64',
              'node.exe',
            ]),
          ),
      testExitAfterReady: testExitAfterReady,
      workingDirectory: runtimeRepositoryRoot,
    );
  }
}

/// Starts Explorer from the Flutter owner, outside the Node Job Object.
Future<void> _openWithWindowsExplorer(Directory directory) async {
  await directory.create(recursive: true);
  await Process.start(
    'explorer.exe',
    <String>[directory.path],
    mode: ProcessStartMode.detached,
    runInShell: false,
  );
}

/// Prevents package tests from opening a user-visible Explorer window by default.
Future<void> _discardDirectoryOpen(Directory _) async {}

/// Owns exactly one desktop Node child, its Windows Job, and its loopback link.
///
/// This is the sole location where process launch, ready parsing, HTTP health,
/// WebSocket setup, structured diagnostics, and hard-stop cleanup are joined.
/// The public Facade intentionally exposes only typed capability invocations.
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

  @override
  Future<bool> pickAndImportLocalPlugin() {
    throw const PluginRuntimeException(
      'unsupported',
      'The Android file picker is unavailable on desktop.',
    );
  }

  @override
  Future<void> importLocalPlugin(String sourcePath) async {
    if (_disposed) {
      throw const PluginRuntimeException(
        'runtime_unavailable',
        'The desktop Runtime has been closed.',
      );
    }
    final source = File(sourcePath);
    if (!await source.exists()) {
      throw const PluginRuntimeException(
        'not_found',
        'The selected plugin archive is unavailable.',
      );
    }
    final inbox = Directory(
      _joinPath(<String>[_bundle.dataRoot.path, 'import-inbox']),
    );
    await inbox.create(recursive: true);
    final target = File(
      _joinPath(<String>[
        inbox.path,
        'import-${DateTime.now().microsecondsSinceEpoch}.mgplugin',
      ]),
    );
    final temporary = File('${target.path}.part');
    _controlledRestarting = true;
    try {
      final totalBytes = await source.length();
      _emitInitializationProgress(
        completedBytes: 0,
        stage: 'plugin_copying',
        totalBytes: totalBytes,
      );
      await source.copy(temporary.path);
      _emitInitializationProgress(
        completedBytes: totalBytes,
        stage: 'plugin_copied',
        totalBytes: totalBytes,
      );
      await temporary.rename(target.path);
      _emitInitializationProgress(
        completedBytes: 0,
        stage: 'plugin_installing',
        totalBytes: 0,
      );
      await _restartForPluginImport();
      await _ensureStarted();
      _emitInitializationProgress(
        completedBytes: 1,
        stage: 'ready',
        totalBytes: 1,
      );
    } on FileSystemException {
      try {
        await temporary.delete();
      } on FileSystemException {
        // The temporary file may not have been created before the failure.
      }
      throw const PluginRuntimeException(
        'disk_full',
        'The selected plugin archive could not be imported.',
      );
    } finally {
      _controlledRestarting = false;
    }
  }

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
  /// Every failure tears down the partial child tree before a safe Facade error
  /// is exposed to Flutter.
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
      final connection = await _WireConnection.connect(ready);
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
final class _RuntimeChildMonitor {
  _RuntimeChildMonitor(
    this._process, {
    required _RuntimeDiagnosticSink onDiagnostic,
    required _RuntimeInitializationSink onProgress,
    required _RuntimeProcessExitSink onExit,
    required _RuntimePreBootFatalSink onPreBootFatal,
    required _RuntimeStartupFailureFactory startupFailure,
  }) : _onDiagnostic = onDiagnostic,
       _onProgress = onProgress,
       _onExit = onExit,
       _onPreBootFatal = onPreBootFatal,
       _startupFailure = startupFailure {
    _stdoutSubscription = _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          _onStdoutLine,
          onError: (Object _, StackTrace __) {
            _failStartup(
              'runtime_startup_channel_failed',
              'The desktop Runtime startup channel failed.',
            );
          },
        );
    _stderrSubscription = _process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          _onStderrLine,
          onError: (Object _, StackTrace __) {
            _record(
              const RuntimeDiagnostic(
                code: 'runtime_stderr_channel_failed',
                level: RuntimeDiagnosticLevel.warning,
                message: 'The desktop Runtime diagnostic channel failed.',
              ),
            );
          },
        );
    unawaited(_process.exitCode.then(_onProcessExit));
  }

  /// Safe diagnostic sink owned by the supervisor, never the Flutter host.
  final _RuntimeDiagnosticSink _onDiagnostic;

  /// Safe progress sink owned by the supervisor, never the Flutter host.
  final _RuntimeInitializationSink _onProgress;

  /// Informs the supervisor whether exit occurred before or after readiness.
  final _RuntimeProcessExitSink _onExit;

  /// Records privacy-safe fallback evidence while no Core TXT store exists.
  final _RuntimePreBootFatalSink _onPreBootFatal;

  /// Owned direct child whose stdout, stderr, and exit state are monitored.
  final Process _process;

  /// Adds the supervisor's bounded diagnostics to a startup failure.
  final _RuntimeStartupFailureFactory _startupFailure;

  /// Completes only once with the validated stdout ready identity.
  final Completer<_RuntimeReady> _ready = Completer<_RuntimeReady>();

  /// Child stderr subscription used solely for structured diagnostics.
  late final StreamSubscription<String> _stderrSubscription;

  /// Child stdout subscription used for ready plus structured diagnostics.
  late final StreamSubscription<String> _stdoutSubscription;

  /// Stops callbacks after supervisor cleanup has begun.
  bool _disposed = false;

  /// Distinguishes the first stdout record from all post-ready lifecycle data.
  bool _readyReceived = false;

  /// Waits for ready until the shared startup deadline or a safe failure.
  Future<_RuntimeReady> waitForReady() {
    final timeout = Timer(_startupTimeout, () {
      _failStartup(
        'runtime_ready_timeout',
        'The desktop Runtime did not become ready in time.',
      );
    });
    return _ready.future.whenComplete(timeout.cancel);
  }

  /// Cancels both stream subscriptions; process ownership remains with supervisor.
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await _stdoutSubscription.cancel();
    await _stderrSubscription.cancel();
  }

  /// Accepts exactly one ready record before reducing stdout to diagnostics.
  void _onStdoutLine(String line) {
    if (_disposed) {
      return;
    }
    if (!_readyReceived) {
      try {
        final ready = _RuntimeReady.parse(line);
        _readyReceived = true;
        if (!_ready.isCompleted) {
          _ready.complete(ready);
        }
      } on Object {
        final diagnostic = _parseStructuredDiagnostic(line);
        if (diagnostic != null) {
          _record(diagnostic.diagnostic);
          if (diagnostic.isFatal) {
            _onPreBootFatal(diagnostic.diagnostic.code, 'startup');
            _failStartup(
              'runtime_start_failed',
              'The desktop Runtime reported a startup failure.',
            );
          }
          return;
        }
        _record(
          const RuntimeDiagnostic(
            code: 'runtime_invalid_ready_signal',
            level: RuntimeDiagnosticLevel.error,
            message: 'The desktop Runtime emitted an invalid ready signal.',
          ),
        );
        _failStartup(
          'runtime_invalid_ready_signal',
          'The desktop Runtime emitted an invalid ready signal.',
        );
      }
      return;
    }

    final diagnostic = _parseStructuredDiagnostic(line);
    _record(
      diagnostic?.diagnostic ??
          const RuntimeDiagnostic(
            code: 'runtime_unexpected_stdout',
            level: RuntimeDiagnosticLevel.warning,
            message:
                'The desktop Runtime emitted an unexpected lifecycle record.',
          ),
    );
  }

  /// Accepts only structured diagnostics from stderr and redacts all other text.
  void _onStderrLine(String line) {
    if (_disposed) {
      return;
    }
    final progress = _parseStructuredProgress(line);
    if (progress != null) {
      _onProgress(progress);
      return;
    }
    final diagnostic = _parseStructuredDiagnostic(line);
    if (diagnostic == null) {
      _record(
        const RuntimeDiagnostic(
          code: 'runtime_unstructured_stderr',
          level: RuntimeDiagnosticLevel.warning,
          message:
              'The desktop Runtime emitted an unstructured diagnostic record.',
        ),
      );
      return;
    }
    _record(diagnostic.diagnostic);
    if (!_readyReceived && diagnostic.isFatal) {
      _onPreBootFatal(diagnostic.diagnostic.code, 'startup');
      _failStartup(
        'runtime_start_failed',
        'The desktop Runtime reported a startup failure.',
      );
    }
  }

  /// Fails startup if the child exits first, then informs the supervisor.
  void _onProcessExit(int exitCode) {
    if (_disposed) {
      return;
    }
    if (!_readyReceived) {
      _record(
        RuntimeDiagnostic(
          code: 'runtime_exited_before_ready',
          level: RuntimeDiagnosticLevel.fatal,
          message:
              'The desktop Runtime exited before it became ready (exit code $exitCode).',
        ),
      );
      _failStartup(
        'runtime_exited_before_ready',
        'The desktop Runtime exited before it became ready.',
      );
      _onPreBootFatal('runtime_exited_before_ready', 'startup');
    }
    _onExit(exitCode, _readyReceived);
  }

  /// Completes the ready future once with a safe, diagnostic-bearing failure.
  void _failStartup(String code, String message) {
    if (!_ready.isCompleted) {
      _ready.completeError(_startupFailure(code, message));
    }
  }

  /// Forwards a value that was already validated/redacted by this monitor.
  void _record(RuntimeDiagnostic diagnostic) => _onDiagnostic(diagnostic);
}

RuntimeInitializationProgress? _parseStructuredProgress(String line) {
  try {
    final value = _jsonObject(jsonDecode(line), 'Runtime progress record');
    if (value['type'] != 'progress') return null;
    final completedBytes = value['completedBytes'];
    final totalBytes = value['totalBytes'];
    final stage = value['stage'];
    final detail = value['detail'];
    if (completedBytes is! int ||
        totalBytes is! int ||
        stage is! String ||
        (detail != null && detail is! String) ||
        completedBytes < 0 ||
        totalBytes < 0 ||
        (totalBytes > 0 && completedBytes > totalBytes)) {
      return null;
    }
    return RuntimeInitializationProgress.fromPlatform(
      completedBytes: completedBytes,
      detail: detail as String?,
      stage: stage,
      totalBytes: totalBytes,
    );
  } on Object {
    return null;
  }
}

/// Validated child diagnostic together with its lifecycle terminality.
final class _StructuredDiagnostic {
  const _StructuredDiagnostic(this.diagnostic, {required this.isFatal});

  /// Safe projection exposed to the supervisor diagnostic buffer.
  final RuntimeDiagnostic diagnostic;

  /// Whether this record must fail startup if readiness has not occurred.
  final bool isFatal;
}

///
/// Parses only the child diagnostic subset that is safe to project to Flutter.
///
/// Invalid JSON, an unknown record type, unapproved code syntax, or oversized
/// text all become `null`. Callers replace them with a fixed diagnostic instead
/// of preserving untrusted child output.
_StructuredDiagnostic? _parseStructuredDiagnostic(String line) {
  try {
    final value = _jsonObject(jsonDecode(line), 'Runtime diagnostic record');
    final type = value['type'];
    if (type != 'diagnostic' && type != 'fatal') {
      return null;
    }
    final code = value['code'];
    final message = value['message'];
    if (code is! String ||
        !_diagnosticCodePattern.hasMatch(code) ||
        message is! String ||
        message.isEmpty ||
        message.length > _maxStructuredDiagnosticMessageLength) {
      return null;
    }
    final fatal = type == 'fatal';
    final level = fatal
        ? RuntimeDiagnosticLevel.fatal
        : switch (value['level']) {
            'info' => RuntimeDiagnosticLevel.info,
            'warning' => RuntimeDiagnosticLevel.warning,
            'error' => RuntimeDiagnosticLevel.error,
            _ => null,
          };
    if (level == null) {
      return null;
    }
    return _StructuredDiagnostic(
      RuntimeDiagnostic(code: code, level: level, message: message),
      isFatal: fatal,
    );
  } on Object {
    return null;
  }
}

/// Stable syntax accepted for child-provided diagnostic codes.
final RegExp _diagnosticCodePattern = RegExp(r'^[a-z0-9_]{1,64}$');

///
/// Returns the minimal Windows environment required to start the staged Node
/// binary. Parent environment inheritance stays disabled so PATH, Node options
/// and application secrets cannot change Runtime behavior. System proxy values
/// are the narrow exception required by Node's `--use-env-proxy` mode.
Map<String, String> _allowlistedEnvironment() {
  const allowedNames = <String>[
    'ComSpec',
    'SystemRoot',
    'TEMP',
    'TMP',
    'WINDIR',
  ];
  final inherited = Platform.environment;
  final environment = <String, String>{
    for (final name in allowedNames)
      if (inherited[name] case final value?) name: value,
  };
  for (final name in const <String>['HTTP_PROXY', 'HTTPS_PROXY', 'NO_PROXY']) {
    final value = _environmentValueIgnoringCase(inherited, name);
    if (value != null && value.isNotEmpty) environment[name] = value;
  }
  for (final entry in _WindowsSystemProxy.environment().entries) {
    environment.putIfAbsent(entry.key, () => entry.value);
  }
  return environment;
}

/// Windows environment names are case-insensitive even when Dart's map is not.
String? _environmentValueIgnoringCase(
  Map<String, String> environment,
  String name,
) {
  for (final entry in environment.entries) {
    if (entry.key.toUpperCase() == name) return entry.value;
  }
  return null;
}

/// Joins package-owned path segments without relying on the host application's CWD.
String _joinPath(List<String> parts) => parts.join(Platform.pathSeparator);

Directory? _findDevelopmentPluginDirectory(List<Directory> starts) {
  for (final start in starts) {
    var current = start.absolute;
    for (var depth = 0; depth < 12; depth += 1) {
      final sources = Directory(
        _joinPath(<String>[current.path, 'plugins', 'sources']),
      );
      final runtimePackage = File(
        _joinPath(<String>[
          current.path,
          'packages',
          'mg_read_runtime',
          'package.json',
        ]),
      );
      if (sources.existsSync() && runtimePackage.existsSync()) return sources;
      final parent = current.parent;
      if (parent.path == current.path) break;
      current = parent;
    }
  }
  return null;
}

Directory? _readConfiguredDevelopmentPluginDirectory(Directory dataRoot) {
  final file = File(
    _joinPath(<String>[dataRoot.path, 'development-directory.txt']),
  );
  try {
    final path = file.readAsStringSync().trim();
    if (path.isEmpty) return null;
    final directory = Directory(path);
    return directory.existsSync() ? directory : null;
  } on Object {
    return null;
  }
}

Future<void> _writeConfiguredDevelopmentPluginDirectory(
  Directory dataRoot,
  String path,
) async {
  await dataRoot.create(recursive: true);
  final file = File(
    _joinPath(<String>[dataRoot.path, 'development-directory.txt']),
  );
  final temporary = File('${file.path}.next');
  await temporary.writeAsString('$path\n', flush: true);
  await temporary.rename(file.path);
}

Future<String> _fingerprintDevelopmentPlugins(Directory root) async {
  final rootPath = root.absolute.path;
  final files = <File>[];
  await for (final entity in root.list(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    final relativePath = entity.path
        .substring(rootPath.length)
        .replaceAll('\\', '/')
        .replaceFirst(RegExp('^/+'), '');
    final segments = relativePath.split('/');
    if (segments.length < 2) continue;
    final projectPath = segments.sublist(1);
    if (projectPath.length == 1 &&
        (projectPath.single == 'package.json' ||
            projectPath.single == 'package-lock.json')) {
      files.add(entity);
    } else if (projectPath.length > 1 &&
        const <String>{
          'dist',
          'assets',
          'packages',
        }.contains(projectPath.first)) {
      files.add(entity);
    }
  }
  files.sort((left, right) => left.path.compareTo(right.path));
  if (files.length > 4096) {
    throw const PluginRuntimeException(
      'runtime_development_plugin_budget_exceeded',
      'The Windows development source tree exceeds its file budget.',
    );
  }
  var hash = 0xcbf29ce484222325;
  var totalBytes = 0;
  for (final file in files) {
    final bytes = await file.readAsBytes();
    totalBytes += bytes.length;
    if (totalBytes > 32 * 1024 * 1024) {
      throw const PluginRuntimeException(
        'runtime_development_plugin_budget_exceeded',
        'The Windows development source tree exceeds its byte budget.',
      );
    }
    for (final value in <int>[...utf8.encode(file.path), 0, ...bytes, 0]) {
      hash ^= value;
      hash = (hash * 0x100000001b3) & 0xffffffffffffffff;
    }
  }
  return hash.toRadixString(16).padLeft(16, '0');
}

/// Validated subset of the child stdout ready record required by the supervisor.
final class _RuntimeReady {
  const _RuntimeReady({
    required this.bootId,
    required this.host,
    required this.port,
  });

  /// Per-process identity reused by the HTTP probe and WebSocket handshake.
  final String bootId;

  /// Required loopback host, validated to reject accidental network exposure.
  final String host;

  /// Validated ephemeral TCP port in the unsigned 16-bit TCP range.
  final int port;

  /// Parses and validates the fixed ready-record schema from child stdout.
  factory _RuntimeReady.parse(String line) {
    final value = _jsonObject(jsonDecode(line), 'Runtime ready signal');
    final type = value['type'];
    final bootId = value['bootId'];
    final host = value['host'];
    final port = value['port'];
    final nodeVersion = value['nodeVersion'];
    final protocolVersion = value['protocolVersion'];
    if (type != 'ready' ||
        bootId is! String ||
        bootId.isEmpty ||
        host is! String ||
        host != '127.0.0.1' ||
        port is! int ||
        port <= 0 ||
        port > 65535 ||
        nodeVersion != _expectedNodeVersion ||
        protocolVersion != _protocolVersion) {
      throw const FormatException('Invalid Runtime ready signal.');
    }

    return _RuntimeReady(bootId: bootId, host: host, port: port);
  }
}
