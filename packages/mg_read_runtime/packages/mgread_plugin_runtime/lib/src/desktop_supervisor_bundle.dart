part of mgread_plugin_runtime;

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
