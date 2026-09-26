part of mgread_plugin_runtime;

/// The Runtime-owned Flutter Facade.
///
/// The first [invoke] starts and verifies one Runtime child process. Concurrent
/// calls share that internal startup operation; no caller supplies a path,
/// database, port, callback or raw transport client. A production instance is
/// process-scoped: it keeps the same owned Runtime for the Flutter process
/// lifetime and does not silently relaunch it after a terminal failure.
abstract interface class _RuntimeSupervisor {
  Future<T> invoke<T>(
    PluginInvocation<T> invocation, {
    PluginInvocationCancellation? cancellation,
  });

  Future<void> importLocalPlugin(String sourcePath);

  Future<bool> pickAndImportLocalPlugin();

  Future<Stream<List<int>>> exportPluginArtifact(
    PluginTransferArtifact artifact,
  );

  Future<MaterializedPluginArtifact> materializePluginArtifact(
    PluginTransferOffer offer,
  );

  Future<PluginDevelopmentPackage> packageDevelopmentPlugin(
    String pluginId,
    String directoryPath,
  );

  Future<List<PluginTransferImportResult>> importPluginArtifacts(
    List<({PluginTransferArtifact artifact, Stream<List<int>> bytes})>
    artifacts, {
    Set<String> forceUpgradePluginIds = const <String>{},
  });

  Future<void> setDevelopmentDirectory(String path);

  Stream<RuntimeDiagnostic> get diagnostics;

  Stream<RuntimeInitializationProgress> get initialization;

  Stream<DevelopmentPluginChangeBatch> get developmentChanges;

  List<RuntimeDiagnostic> get latestDiagnostics;

  int get debugProcessStartCount;

  Future<void> configureNodeEnvironmentProxy(bool enabled);

  Future<void> configurePluginHttpProxy(Uri? proxyUri);

  Future<void> dispose();
}

final class PluginRuntime {
  PluginRuntime._(this._supervisor);

  static PluginRuntime? _bundledInstance;
  static PluginRuntime? _androidInstance;
  static PluginRuntime? _nativeInstance;

  /// Whether this Facade can install and execute native binary sources.
  bool get supportsNativeSources =>
      _supervisor is _HybridRuntimeSupervisor ||
      _supervisor is _NativeRuntimeSupervisor;

  /// Creates or returns the process-scoped production Facade.
  ///
  /// The Runtime package resolves its own desktop bundle layout. Windows and
  /// Android own both Node and native backends. The native-only
  /// define remains available for isolation and package acceptance builds.
  factory PluginRuntime() {
    if (const bool.fromEnvironment('MGREAD_NATIVE_RUNTIME')) {
      return _nativeInstance ??= PluginRuntime._(
        _NativeRuntimeSupervisor.forCurrentPlatform(),
      );
    }
    if (Platform.isAndroid) {
      return _androidInstance ??= PluginRuntime._(
        const bool.fromEnvironment('MGREAD_NODE_ONLY')
            ? (AndroidNodeRuntimeSettings.instance.active ==
                      AndroidNodeBackend.nodeProcess
                  ? _AndroidNodeProcessSupervisor()
                  : _AndroidRuntimeSupervisor())
            : _HybridRuntimeSupervisor(
                AndroidNodeRuntimeSettings.instance.active ==
                        AndroidNodeBackend.nodeProcess
                    ? _AndroidNodeProcessSupervisor()
                    : _AndroidRuntimeSupervisor(),
                _NativeRuntimeSupervisor.forCurrentPlatform(),
              ),
      );
    }
    if (!Platform.isWindows && !Platform.isMacOS) {
      throw const PluginRuntimeException(
        'unsupported',
        'This Runtime package currently has no launcher for this platform.',
      );
    }
    return _bundledInstance ??= PluginRuntime._(
      Platform.isWindows
          ? const bool.fromEnvironment('MGREAD_NODE_ONLY')
                ? _DesktopRuntimeSupervisor(
                    _DesktopRuntimeBundle.fromApplicationPackage(),
                    useEnvironmentProxy: true,
                  )
                : _HybridRuntimeSupervisor(
                    _DesktopRuntimeSupervisor(
                      _DesktopRuntimeBundle.fromApplicationPackage(),
                      useEnvironmentProxy: true,
                    ),
                    _NativeRuntimeSupervisor.forCurrentPlatform(),
                  )
          : _DesktopRuntimeSupervisor(
              _DesktopRuntimeBundle.fromApplicationPackage(),
              useEnvironmentProxy: true,
            ),
    );
  }

  /// Selects an output directory and packages one Windows desktop development source.
  ///
  /// The project path, artifact bytes and destination path are handled by this
  /// Runtime package; the application receives the resulting package metadata.
  Future<PluginDevelopmentPackage?> packageDevelopmentPlugin(
    String pluginId,
  ) async {
    if (!Platform.isWindows) {
      throw const PluginRuntimeException(
        'unsupported',
        'Development source packaging is available on Windows desktop only.',
      );
    }
    final directoryPath = await getDirectoryPath(confirmButtonText: '选择打包目录');
    if (directoryPath == null || directoryPath.isEmpty) return null;
    return _supervisor.packageDevelopmentPlugin(pluginId, directoryPath);
  }

  final _RuntimeSupervisor _supervisor;

  /// Emits desktop development-source build and activation changes.
  ///
  /// Android returns an empty stream and never starts a directory watcher or
  /// development build chain.
  Stream<DevelopmentPluginChangeBatch> get developmentChanges =>
      _supervisor.developmentChanges;

  /// Controls Node's ambient environment-proxy support on Windows.
  ///
  /// Production starts with this enabled so an absent explicit source proxy
  /// follows the process or Windows manual proxy. Changing it restarts an
  /// already-running desktop Runtime with or without
  /// `--use-env-proxy` and exposes only HTTP_PROXY, HTTPS_PROXY and NO_PROXY
  /// (falling back to the Windows manual proxy). Android intentionally ignores
  /// this Windows-only startup preference. The explicit source HTTP dispatcher
  /// configured by [configurePluginHttpProxy] remains independent.
  Future<void> configureNodeEnvironmentProxy(bool enabled) =>
      _supervisor.configureNodeEnvironmentProxy(enabled);

  /// Routes only data-source `ctx.http.fetch` requests through [proxyUri].
  ///
  /// Runtime source resources share this direct upstream route. Runtime control
  /// traffic, WebView and ambient Node.js requests
  /// keep their existing routing behavior.
  Future<void> configurePluginHttpProxy(Uri? proxyUri) {
    if (proxyUri != null &&
        (!const <String>{'http', 'https', 'socks5'}.contains(proxyUri.scheme) ||
            proxyUri.host.isEmpty ||
            !proxyUri.hasPort ||
            proxyUri.userInfo.isNotEmpty ||
            proxyUri.path.isNotEmpty && proxyUri.path != '/' ||
            proxyUri.hasQuery ||
            proxyUri.hasFragment)) {
      throw ArgumentError.value(
        proxyUri,
        'proxyUri',
        'An HTTP, HTTPS or SOCKS5 proxy endpoint is required.',
      );
    }
    return _supervisor.configurePluginHttpProxy(proxyUri);
  }

  /// Invokes a typed Runtime capability.
  ///
  /// Runtime process creation, stdout ready parsing, HTTP readiness and
  /// WebSocket hello happen internally before this operation is dispatched.
  /// The returned [Future] completes with [PluginRuntimeException] containing
  /// a stable Runtime error code and diagnostics.
  Future<T> invoke<T>(
    PluginInvocation<T> invocation, {
    PluginInvocationCancellation? cancellation,
  }) {
    if (invocation is OpenRuntimePrivateDirectoryInvocation &&
        !Platform.isWindows &&
        !Platform.isMacOS) {
      throw const PluginRuntimeException(
        'unsupported',
        'Opening the Runtime private directory is available on desktop only.',
      );
    }
    cancellation?._throwIfCancelled();
    return _supervisor.invoke(invocation, cancellation: cancellation);
  }

  /// Enables or disables the unauthenticated Runtime inspector.
  ///
  /// The preference is Runtime-owned and restored by later Runtime
  /// starts; callers only receive copyable page URLs, never internal control
  /// endpoints or resource tokens.
  Future<RuntimeDebugHttpStatus> setDebugHttpEnabled(bool enabled) {
    return invoke(RuntimeDebugHttpInvocation(enabled: enabled));
  }

  /// Reads the Runtime-owned Debug inspector preference and live listener state.
  Future<RuntimeDebugHttpStatus> debugHttpStatus() {
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
          label: 'MgRead 数据源',
          extensions: const bool.fromEnvironment('MGREAD_NATIVE_RUNTIME')
              ? <String>['mgplugin']
              : <String>['mgplugin.js', 'mgplugin'],
        ),
      ],
      confirmButtonText: '导入',
    );
    if (file == null) return false;
    final path = file.path;
    final lowerPath = path.toLowerCase();
    final nativeRuntime = const bool.fromEnvironment('MGREAD_NATIVE_RUNTIME');
    if (path.isEmpty ||
        (nativeRuntime
            ? !lowerPath.endsWith('.mgplugin') ||
                  lowerPath.endsWith('.mgplugin.js')
            : !lowerPath.endsWith('.mgplugin.js') &&
                  !lowerPath.endsWith('.mgplugin'))) {
      throw const PluginRuntimeException(
        'invalid_request',
        'The selected file is not a MgRead plugin artifact.',
      );
    }
    await _supervisor.importLocalPlugin(path);
    return true;
  }

  /// Imports a native binary source through the selected platform picker.
  Future<bool> importNativeLocalPlugin() {
    final supervisor = _supervisor;
    if (supervisor is _HybridRuntimeSupervisor) {
      return supervisor.importNativeLocalPlugin();
    }
    if (supervisor is _NativeRuntimeSupervisor) {
      return Platform.isAndroid
          ? supervisor.pickAndImportLocalPlugin()
          : importLocalPlugin();
    }
    throw const PluginRuntimeException(
      'unsupported',
      'Native source packages are unavailable on this platform.',
    );
  }

  /// Imports a package-owned fixture by path for Runtime integration tests.
  ///
  /// Product flows keep path selection inside this package; only package
  /// acceptance tests use this helper to exercise the production Supervisor.
  @visibleForTesting
  Future<void> importLocalPluginForTesting(String sourcePath) {
    if (const bool.fromEnvironment('MGREAD_TEST_DIRECT_IMPORTS') &&
        _supervisor is _HybridRuntimeSupervisor) {
      return _supervisor.importLocalPluginForTesting(sourcePath);
    }
    if (!const bool.fromEnvironment('MGREAD_NATIVE_RUNTIME')) {
      throw const PluginRuntimeException(
        'unsupported',
        'Direct-path plugin imports are available to native Runtime tests only.',
      );
    }
    return _supervisor.importLocalPlugin(sourcePath);
  }

  /// Streams one Runtime-owned artifact without exposing a path, handle, port,
  /// or control-plane payload to the application.
  Future<Stream<List<int>>> exportPluginArtifact(
    PluginTransferArtifact artifact,
  ) => _supervisor.exportPluginArtifact(artifact);

  /// Materializes one selected transfer offer and streams its bytes.
  ///
  /// Development sources are packaged here, after the receiver has selected
  /// this exact source. Listing and planning offers never build every active
  /// development project.
  Future<MaterializedPluginArtifact> materializePluginArtifact(
    PluginTransferOffer offer,
  ) => _supervisor.materializePluginArtifact(offer);

  /// Accepts a byte-bounded batch and performs bounded Runtime cold activations.
  ///
  /// Android divides large selections into native-safe sub-batches; callers
  /// still receive one ordered result list for the complete selection.
  Future<List<PluginTransferImportResult>> importPluginArtifacts(
    List<({PluginTransferArtifact artifact, Stream<List<int>> bytes})>
    artifacts, {
    Set<String> forceUpgradePluginIds = const <String>{},
  }) {
    if (!supportsNativeSources &&
        artifacts.any((item) => item.artifact.engine == PluginEngine.native)) {
      throw const PluginRuntimeException(
        'unsupported',
        'Native source packages are unavailable on this platform.',
      );
    }
    return _supervisor.importPluginArtifacts(
      artifacts,
      forceUpgradePluginIds: forceUpgradePluginIds,
    );
  }

  /// Selects a desktop development-source directory.
  ///
  /// Android deliberately has no development-directory capability; Android
  /// sources must be imported as validated `.mgplugin.js` or `.mgplugin`
  /// artifacts.
  Future<bool> selectDevelopmentDirectory() async {
    if (!Platform.isWindows && !Platform.isMacOS) {
      throw const PluginRuntimeException(
        'unsupported',
        'Development source directories are available on desktop only.',
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

  /// Creates a native Rust Facade for package-owned tests.
  ///
  /// Tests may use an isolated fake control endpoint or launch a package-owned
  /// helper executable from an isolated data root. Production applications
  /// cannot inject either value.
  @visibleForTesting
  factory PluginRuntime.nativeForTesting({
    required String executablePath,
    required String dataRoot,
    bool testMode = false,
    Uri? testControlUri,
    String? testToken,
  }) {
    return PluginRuntime._(
      _NativeRuntimeSupervisor.forTesting(
        executablePath: executablePath,
        dataRoot: dataRoot,
        testMode: testMode,
        testControlUri: testControlUri,
        testToken: testToken,
      ),
    );
  }

  /// Combines isolated package test Facades without exposing either transport.
  @visibleForTesting
  factory PluginRuntime.hybridForTesting({
    required PluginRuntime nodeRuntime,
    required PluginRuntime nativeRuntime,
  }) {
    final native = nativeRuntime._supervisor;
    if (native is! _NativeRuntimeSupervisor ||
        nodeRuntime._supervisor is _NativeRuntimeSupervisor) {
      throw ArgumentError(
        'Hybrid tests require one Node and one native Facade.',
      );
    }
    return PluginRuntime._(
      _HybridRuntimeSupervisor(nodeRuntime._supervisor, native),
    );
  }

  /// Emits bounded Runtime lifecycle diagnostics.
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

  /// Reports bounded Runtime-owned lifecycle progress when available.
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
  /// Production callers do not manage the Runtime's lifecycle: the desktop
  /// supervisor owns its child and Android owns the selected backend.
  @visibleForTesting
  Future<void> debugDispose() async {
    if (const bool.fromEnvironment('MGREAD_NATIVE_RUNTIME')) {
      await _supervisor.dispose();
      if (identical(_nativeInstance, this)) _nativeInstance = null;
      return;
    }
    // The Android bridge owns the native Runtime lifecycle. Local imports use
    // its controlled cold restart path; test disposal must not detach the
    // selected backend from the Flutter plugin.
    if (Platform.isAndroid) return;
    await _supervisor.dispose();
    if (identical(_bundledInstance, this)) {
      _bundledInstance = null;
    }
  }
}
