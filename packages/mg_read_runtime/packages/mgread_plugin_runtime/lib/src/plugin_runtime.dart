part of mgread_plugin_runtime;

/// The Runtime-owned Flutter Facade.
///
/// The first [invoke] starts and verifies one Runtime child process. Concurrent
/// calls share that internal startup operation; no caller supplies a path,
/// database, port, callback or raw transport client. A production instance is
/// process-scoped: it keeps the same owned Runtime for the Flutter process
/// lifetime and does not silently relaunch it after a terminal failure.
abstract interface class _RuntimeSupervisor {
  Future<T> invoke<T>(PluginInvocation<T> invocation);

  Future<void> importLocalPlugin(String sourcePath);

  Future<bool> pickAndImportLocalPlugin();

  Future<Stream<List<int>>> exportPluginArtifact(
    PluginTransferArtifact artifact,
  );

  Future<PluginDevelopmentPackage> packageDevelopmentPlugin(
    String pluginId,
    String directoryPath,
  );

  Future<List<PluginTransferImportResult>> importPluginArtifacts(
    List<({PluginTransferArtifact artifact, Stream<List<int>> bytes})>
    artifacts,
  );

  Future<void> setDevelopmentDirectory(String path);

  Stream<RuntimeDiagnostic> get diagnostics;

  Stream<RuntimeInitializationProgress> get initialization;

  List<RuntimeDiagnostic> get latestDiagnostics;

  int get debugProcessStartCount;

  Future<void> dispose();
}

final class PluginRuntime {
  PluginRuntime._(this._supervisor);

  static PluginRuntime? _bundledInstance;
  static PluginRuntime? _androidInstance;

  /// Creates or returns the process-scoped production Facade.
  ///
  /// The Runtime package resolves its own desktop bundle layout. Android uses
  /// the package-owned Javet bridge; neither platform leaks its launcher or
  /// file-system details to the host application.
  factory PluginRuntime() {
    if (Platform.isAndroid) {
      return _androidInstance ??= PluginRuntime._(_AndroidRuntimeSupervisor());
    }
    if (!Platform.isWindows) {
      throw const PluginRuntimeException(
        'unsupported',
        'This Runtime package currently has no launcher for this platform.',
      );
    }
    return _bundledInstance ??= PluginRuntime._(
      _DesktopRuntimeSupervisor(_DesktopRuntimeBundle.fromApplicationPackage()),
    );
  }

  /// Selects an output directory and packages one Windows Debug development source.
  ///
  /// The project path, artifact bytes and destination path stay inside this
  /// Runtime package; the application receives only safe artifact metadata.
  Future<PluginDevelopmentPackage?> packageDevelopmentPlugin(
    String pluginId,
  ) async {
    if (!kDebugMode || !Platform.isWindows) {
      throw const PluginRuntimeException(
        'unsupported',
        'Development source packaging is available in Windows Debug only.',
      );
    }
    final directoryPath = await getDirectoryPath(confirmButtonText: '选择打包目录');
    if (directoryPath == null || directoryPath.isEmpty) return null;
    return _supervisor.packageDevelopmentPlugin(pluginId, directoryPath);
  }

  final _RuntimeSupervisor _supervisor;

  /// Invokes a typed Runtime capability.
  ///
  /// Runtime process creation, stdout ready parsing, HTTP readiness and
  /// WebSocket hello happen internally before this operation is dispatched.
  /// The returned [Future] completes with [PluginRuntimeException] only with a
  /// stable Runtime error code and safe diagnostics; it never exposes a PID,
  /// port, raw stderr, path, or WebSocket frame.
  Future<T> invoke<T>(PluginInvocation<T> invocation) {
    if (invocation is OpenRuntimePrivateDirectoryInvocation &&
        !Platform.isWindows) {
      throw const PluginRuntimeException(
        'unsupported',
        'Opening the Runtime private directory is available on Windows only.',
      );
    }
    return _supervisor.invoke(invocation);
  }

  /// Enables or disables the unauthenticated Debug inspector in Debug builds.
  ///
  /// The preference is Runtime-owned and restored by later Debug Runtime
  /// starts; callers only receive copyable page URLs, never internal control
  /// endpoints or resource tokens.
  Future<RuntimeDebugHttpStatus> setDebugHttpEnabled(bool enabled) {
    if (!kDebugMode) {
      throw const PluginRuntimeException(
        'unsupported',
        'Runtime Debug HTTP is available in Debug builds only.',
      );
    }
    return invoke(RuntimeDebugHttpInvocation(enabled: enabled));
  }

  /// Reads the Runtime-owned Debug inspector preference and live listener state.
  Future<RuntimeDebugHttpStatus> debugHttpStatus() {
    if (!kDebugMode) {
      throw const PluginRuntimeException(
        'unsupported',
        'Runtime Debug HTTP is available in Debug builds only.',
      );
    }
    return invoke(const RuntimeDebugHttpStatusInvocation());
  }

  /// Opens the platform file picker and imports one local MgRead source.
  ///
  /// The picker and the hand-off to the Runtime-owned inbox both live inside
  /// this package. The application receives only whether the user selected a
  /// file; it never receives or passes a filesystem path to Runtime code.
  Future<bool> importLocalPlugin() async {
    if (Platform.isAndroid) {
      return _supervisor.pickAndImportLocalPlugin();
    }
    final file = await openFile(
      acceptedTypeGroups: <XTypeGroup>[
        XTypeGroup(
          label: 'MgRead 数据来源',
          extensions: <String>['mgplugin.js', 'mgplugin'],
        ),
      ],
      confirmButtonText: '导入',
    );
    if (file == null) return false;
    final path = file.path;
    final lowerPath = path.toLowerCase();
    if (path.isEmpty ||
        (!lowerPath.endsWith('.mgplugin.js') &&
            !lowerPath.endsWith('.mgplugin'))) {
      throw const PluginRuntimeException(
        'invalid_request',
        'The selected file is not a MgRead plugin artifact.',
      );
    }
    await _supervisor.importLocalPlugin(path);
    return true;
  }

  /// Streams one Runtime-owned artifact without exposing a path, handle, port,
  /// or control-plane payload to the application.
  Future<Stream<List<int>>> exportPluginArtifact(
    PluginTransferArtifact artifact,
  ) => _supervisor.exportPluginArtifact(artifact);

  /// Accepts a bounded batch and performs one Runtime cold activation.
  Future<List<PluginTransferImportResult>> importPluginArtifacts(
    List<({PluginTransferArtifact artifact, Stream<List<int>> bytes})>
    artifacts,
  ) {
    if (artifacts.length > maxPluginTransferBatch) {
      throw const PluginRuntimeException(
        'plugin_transfer_batch_too_large',
        'The plugin transfer batch is too large.',
      );
    }
    return _supervisor.importPluginArtifacts(artifacts);
  }

  /// Selects a Windows Debug development-source directory.
  ///
  /// Android deliberately has no development-directory capability; Android
  /// sources must be imported as validated `.mgplugin.js` or `.mgplugin`
  /// artifacts.
  Future<bool> selectDevelopmentDirectory() async {
    if (!kDebugMode || !Platform.isWindows) {
      throw const PluginRuntimeException(
        'unsupported',
        'Development source directories are available on Windows only.',
      );
    }
    final path = await getDirectoryPath(confirmButtonText: '选择开发目录');
    if (path == null || path.isEmpty) return false;
    await _supervisor.setDevelopmentDirectory(path);
    return true;
  }

  /// Creates a desktop Facade only for package-owned automated tests.
  ///
  /// This is deliberately not a HostPort or a general application injection
  /// point: it accepts only the Runtime repository that contains the exact
  /// checked-in Node bundle and compiled Runtime entrypoint. The optional
  /// overrides exist solely to exercise package-owned broken-bundle and shell
  /// action fixtures.
  /// [runtimeDataRoot] is a Runtime-owned temporary testkit root used to stage
  /// standard plugin fixtures without touching real user data. Production
  /// callers cannot provide or observe this path.
  @visibleForTesting
  factory PluginRuntime.desktopForTesting({
    required Directory runtimeRepositoryRoot,
    File? entrypointOverride,
    File? nodeExecutableOverride,
    Directory? runtimeDataRoot,
    Directory? developmentPluginRoot,
    Future<void> Function(Directory directory)? directoryLauncher,
    Duration? testExitAfterReady,
  }) {
    return PluginRuntime._(
      _DesktopRuntimeSupervisor(
        _DesktopRuntimeBundle.fromRepositoryForTest(
          runtimeRepositoryRoot,
          entrypointOverride: entrypointOverride,
          nodeExecutableOverride: nodeExecutableOverride,
          runtimeDataRoot: runtimeDataRoot,
          developmentPluginDirectory: developmentPluginRoot,
          directoryLauncher: directoryLauncher,
          testExitAfterReady: testExitAfterReady,
        ),
      ),
    );
  }

  /// Emits bounded, redacted Runtime lifecycle diagnostics.
  ///
  /// This is intentionally not a raw stderr or transport stream. Consumers can
  /// show the stable code/message or retain it for their own UI diagnostics,
  /// while all process, port, and protocol handling remains Runtime-owned. The
  /// broadcast stream does not replay earlier records; use [latestDiagnostics]
  /// to obtain the current bounded snapshot before subscribing.
  Stream<RuntimeDiagnostic> get diagnostics => _supervisor.diagnostics;

  /// Emits a terminal Runtime diagnostic when the owned Node child cannot
  /// start or exits unexpectedly. The next explicit capability invocation is
  /// allowed to perform one orderly cold restart; this stream never exposes
  /// process, port, raw stderr, or filesystem details.
  Stream<RuntimeDiagnostic> get fatalDiagnostics =>
      diagnostics.where((diagnostic) => diagnostic.isFatal);

  /// Reports bounded Runtime-owned initialization progress when available.
  Stream<RuntimeInitializationProgress> get initialization =>
      _supervisor.initialization;

  /// Returns an immutable, oldest-to-newest snapshot of bounded diagnostics.
  List<RuntimeDiagnostic> get latestDiagnostics =>
      _supervisor.latestDiagnostics;

  /// Returns the number of child-process launch attempts for an owned test.
  ///
  /// This proves startup de-duplication in package tests and is not a process
  /// management capability for host applications.
  @visibleForTesting
  int get debugDesktopProcessStartCount => _supervisor.debugProcessStartCount;

  /// Closes the test-owned Runtime process and its internal connection.
  ///
  /// Production callers do not manage the Runtime's lifecycle: Windows Job
  /// Object ownership binds the child tree to the Flutter process instead.
  @visibleForTesting
  Future<void> debugDispose() async {
    // The Android bridge owns the native Runtime lifecycle. Local imports use
    // its controlled cold restart path; test disposal must not detach that
    // engine from the Flutter plugin.
    if (Platform.isAndroid) return;
    await _supervisor.dispose();
    if (identical(_bundledInstance, this)) {
      _bundledInstance = null;
    }
  }
}
