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
  /// The Runtime package resolves its own desktop bundle layout. Android and
  /// package-native launchers are future Runtime implementations, not Flutter
  /// application responsibilities.
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

  final _RuntimeSupervisor _supervisor;

  /// Invokes a typed Runtime capability.
  ///
  /// Runtime process creation, stdout ready parsing, HTTP readiness and
  /// WebSocket hello happen internally before this operation is dispatched.
  /// The returned [Future] completes with [PluginRuntimeException] only with a
  /// stable Runtime error code and safe diagnostics; it never exposes a PID,
  /// port, raw stderr, path, or WebSocket frame.
  Future<T> invoke<T>(PluginInvocation<T> invocation) {
    return _supervisor.invoke(invocation);
  }

  /// Creates a desktop Facade only for package-owned automated tests.
  ///
  /// This is deliberately not a HostPort or a general application injection
  /// point: it accepts only the Runtime repository that contains the exact
  /// checked-in Node bundle and compiled Runtime entrypoint. The optional
  /// overrides exist solely to exercise package-owned broken-bundle fixtures.
  /// [runtimeDataRoot] is a Runtime-owned temporary testkit root used to stage
  /// standard plugin fixtures without touching real user data. Production
  /// callers cannot provide or observe this path.
  @visibleForTesting
  factory PluginRuntime.desktopForTesting({
    required Directory runtimeRepositoryRoot,
    File? entrypointOverride,
    File? nodeExecutableOverride,
    Directory? runtimeDataRoot,
  }) {
    return PluginRuntime._(
      _DesktopRuntimeSupervisor(
        _DesktopRuntimeBundle.fromRepositoryForTest(
          runtimeRepositoryRoot,
          entrypointOverride: entrypointOverride,
          nodeExecutableOverride: nodeExecutableOverride,
          runtimeDataRoot: runtimeDataRoot,
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
  Future<void> debugDispose() => _supervisor.dispose();
}
