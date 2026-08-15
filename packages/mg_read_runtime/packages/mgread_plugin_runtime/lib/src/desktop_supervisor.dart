part of mgread_plugin_runtime;

/// Exact Node version required by both the staged bundle and ready record.
const _expectedNodeVersion = '24.16.0';

/// Version of the internal Runtime control protocol negotiated during hello.
const _protocolVersion = '1.0';

/// Upper bound for child startup and readiness probes.
// A new Runtime data root installs the packaged default source before emitting
// ready. Materialising its verified dependency tree can take roughly 14
// seconds on Windows, so the first launch needs a bounded but realistic
// budget. Later starts normally complete much sooner.
const _startupTimeout = Duration(seconds: 20);

/// Upper bound for a single already-connected control request.
const _controlTimeout = Duration(seconds: 5);

/// Bounded count of safe diagnostics retained for Flutter error presentation.
const _maxDiagnosticEntries = 32;

/// Maximum accepted message length from a structured child diagnostic record.
const _maxStructuredDiagnosticMessageLength = 256;

/// Receives a safe diagnostic after the monitor validates the child record.
typedef _RuntimeDiagnosticSink = void Function(RuntimeDiagnostic diagnostic);

/// Reports child termination together with whether readiness was already seen.
typedef _RuntimeProcessExitSink = void Function(int exitCode, bool wasReady);

/// Creates a Facade-safe startup exception with the current diagnostic snapshot.
typedef _RuntimeStartupFailureFactory =
    PluginRuntimeException Function(String code, String message);

/// Immutable locations of the Runtime files owned and launched by this package.
///
/// The values are never supplied by the host application. Production resolves
/// a staged package bundle; test construction is intentionally isolated below.
final class _DesktopRuntimeBundle {
  const _DesktopRuntimeBundle({
    required this.dataRoot,
    required this.bundledPluginDirectory,
    required this.entrypoint,
    required this.nodeExecutable,
    required this.workingDirectory,
  });

  /// Runtime-owned writable root; never returned through the public Facade.
  final Directory dataRoot;

  /// Packaged first-run source archives, never visible to the main app.
  final Directory? bundledPluginDirectory;

  /// Compiled Node executable entrypoint that emits ready/diagnostic records.
  final File entrypoint;

  /// Exact packaged Node executable; never resolved from the ambient PATH.
  final File nodeExecutable;

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
    return _DesktopRuntimeBundle(
      dataRoot: Directory(
        _joinPath(<String>[localAppData, 'MgRead', 'runtime']),
      ),
      bundledPluginDirectory: Directory(
        _joinPath(<String>[bundleRoot.path, 'default-plugins']),
      ),
      entrypoint: File(_joinPath(<String>[bundleRoot.path, 'dist', 'cli.js'])),
      nodeExecutable: File(
        _joinPath(<String>[bundleRoot.path, 'node', 'node.exe']),
      ),
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
      workingDirectory: runtimeRepositoryRoot,
    );
  }
}

/// Owns exactly one desktop Node child, its Windows Job, and its loopback link.
///
/// This is the sole location where process launch, ready parsing, HTTP health,
/// WebSocket setup, structured diagnostics, and hard-stop cleanup are joined.
/// The public Facade intentionally exposes only typed capability invocations.
final class _DesktopRuntimeSupervisor {
  _DesktopRuntimeSupervisor(this._bundle);

  /// Immutable package-owned inputs used for the only allowed child launch.
  final _DesktopRuntimeBundle _bundle;

  /// Broadcasts already-redacted diagnostics; it is closed during dispose.
  final StreamController<RuntimeDiagnostic> _diagnosticController =
      StreamController<RuntimeDiagnostic>.broadcast();

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

  /// Package-test-only child launch count; not a public process handle.
  int get debugProcessStartCount => _processStartCount;

  /// Stream of safe lifecycle diagnostics emitted after subscription.
  Stream<RuntimeDiagnostic> get diagnostics => _diagnosticController.stream;

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

    final connection = await _ensureStarted();
    final result = await connection.request(
      method: invocation._wireMethod,
      params: invocation._wireParams,
    );
    return invocation._decodeResult(result);
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
        onExit: _handleProcessExit,
        startupFailure: _failure,
      );
      _monitor = monitor;

      final ready = await monitor.waitForReady();
      await _probeHttpReady(ready);
      final connection = await _WireConnection.connect(ready);
      await connection.hello();
      _connection = connection;
      return connection;
    } on PluginRuntimeException {
      await _stopFailedStart();
      rethrow;
    } on WindowsJobObjectException catch (error) {
      _recordDiagnostic(
        RuntimeDiagnostic(
          code: error.code,
          level: RuntimeDiagnosticLevel.error,
          message: error.message,
        ),
      );
      await _stopFailedStart();
      throw _failure(
        error.code,
        'The desktop Runtime could not be started with required process ownership.',
      );
    } on ProcessException {
      _recordDiagnostic(
        const RuntimeDiagnostic(
          code: 'runtime_process_launch_failed',
          level: RuntimeDiagnosticLevel.error,
          message:
              'The packaged desktop Runtime process could not be launched.',
        ),
      );
      await _stopFailedStart();
      throw _failure(
        'runtime_process_launch_failed',
        'The packaged desktop Runtime process could not be launched.',
      );
    } on Object {
      _recordDiagnostic(
        const RuntimeDiagnostic(
          code: 'runtime_start_failed',
          level: RuntimeDiagnosticLevel.error,
          message: 'The desktop Runtime failed during startup.',
        ),
      );
      await _stopFailedStart();
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
  }

  /// Converts a post-ready child exit into a safe transport failure/diagnostic.
  void _handleProcessExit(int exitCode, bool wasReady) {
    if (!wasReady) {
      return;
    }
    _connection?.markProcessExited();
    if (!_disposed) {
      _recordDiagnostic(
        RuntimeDiagnostic(
          code: 'runtime_process_exited',
          level: RuntimeDiagnosticLevel.error,
          message:
              'The desktop Runtime process exited unexpectedly (exit code $exitCode).',
        ),
      );
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
}

/// Converts the owned child's stdout/stderr/exit events into safe lifecycle data.
///
/// Stdout has one special pre-ready record. All other accepted child output must
/// be a bounded structured diagnostic; raw text is never forwarded to Flutter.
final class _RuntimeChildMonitor {
  _RuntimeChildMonitor(
    this._process, {
    required _RuntimeDiagnosticSink onDiagnostic,
    required _RuntimeProcessExitSink onExit,
    required _RuntimeStartupFailureFactory startupFailure,
  }) : _onDiagnostic = onDiagnostic,
       _onExit = onExit,
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

  /// Informs the supervisor whether exit occurred before or after readiness.
  final _RuntimeProcessExitSink _onExit;

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
          level: RuntimeDiagnosticLevel.error,
          message:
              'The desktop Runtime exited before it became ready (exit code $exitCode).',
        ),
      );
      _failStartup(
        'runtime_exited_before_ready',
        'The desktop Runtime exited before it became ready.',
      );
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
        ? RuntimeDiagnosticLevel.error
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
  for (final name in const <String>[
    'HTTP_PROXY',
    'HTTPS_PROXY',
    'NO_PROXY',
  ]) {
    final value = _environmentValueIgnoringCase(inherited, name);
    if (value != null && value.isNotEmpty) environment[name] = value;
  }
  for (final entry in _WindowsSystemProxy.environment().entries) {
    environment.putIfAbsent(entry.key, () => entry.value);
  }
  return environment;
}

/// Windows environment names are case-insensitive even when Dart's map is not.
String? _environmentValueIgnoringCase(Map<String, String> environment, String name) {
  for (final entry in environment.entries) {
    if (entry.key.toUpperCase() == name) return entry.value;
  }
  return null;
}

/// Joins package-owned path segments without relying on the host application's CWD.
String _joinPath(List<String> parts) => parts.join(Platform.pathSeparator);

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
