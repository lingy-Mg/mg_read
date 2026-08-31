part of mgread_plugin_runtime;

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
/// and application secrets cannot change Runtime behavior. Proxy variables and
/// the Windows manual proxy are exposed when the production Runtime inherits
/// the system route. Tests can still opt out to remain hermetic.
Map<String, String> _allowlistedEnvironment({
  required bool useEnvironmentProxy,
}) {
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
  if (useEnvironmentProxy) {
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
    _ensureLoopbackNoProxy(environment);
  }
  return environment;
}

String? _environmentValueIgnoringCase(
  Map<String, String> environment,
  String name,
) {
  final expected = name.toLowerCase();
  for (final entry in environment.entries) {
    if (entry.key.toLowerCase() == expected) return entry.value;
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
