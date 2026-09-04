part of mgread_plugin_runtime;

final class _DesktopRuntimeBundle {
  const _DesktopRuntimeBundle({
    required this.dataRoot,
    required this.bundledPluginDirectory,
    required this.developmentPluginDirectory,
    required this.developmentNpmCli,
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

  /// User-selected workspace projects loaded directly without installation.
  final Directory? developmentPluginDirectory;

  /// Repository-pinned npm CLI used only by desktop development builds.
  final File? developmentNpmCli;

  /// Opens a Runtime-owned directory through the current desktop shell.
  final _DesktopDirectoryLauncher directoryLauncher;

  /// Compiled Node executable entrypoint that emits ready/diagnostic records.
  final File entrypoint;

  /// Exact packaged Node executable; never resolved from the ambient PATH.
  final File nodeExecutable;

  /// Test-only crash fixture delay; production bundles always leave this null.
  final Duration? testExitAfterReady;

  /// Bundle root used as the child process current working directory.
  final Directory workingDirectory;

  /// Resolves the fixed platform bundle staged into a Flutter application.
  factory _DesktopRuntimeBundle.fromApplicationPackage() {
    if (!Platform.isWindows && !Platform.isMacOS) {
      throw const PluginRuntimeException(
        'unsupported',
        'This Runtime package currently has no launcher for this platform.',
      );
    }

    final executableDirectory = File(Platform.resolvedExecutable).parent;
    final dataHome = Platform.isWindows
        ? Platform.environment['LOCALAPPDATA']
        : Platform.environment['HOME'];
    if (dataHome == null || dataHome.isEmpty) {
      throw const PluginRuntimeException(
        'runtime_data_root_unavailable',
        'The Runtime could not resolve its application data directory.',
      );
    }
    final platformAssetRoot = Platform.isWindows
        ? 'windows-x64'
        : 'macos-arm64';
    final flutterAssetRoot = Platform.isWindows
        ? _joinPath(<String>[
            executableDirectory.path,
            'data',
            'flutter_assets',
          ])
        : _joinPath(<String>[
            executableDirectory.parent.path,
            'Frameworks',
            'App.framework',
            'Resources',
            'flutter_assets',
          ]);
    final bundleRoot = Directory(
      _joinPath(<String>[
        flutterAssetRoot,
        'packages',
        'mgread_plugin_runtime',
        'assets',
        'runtime',
        platformAssetRoot,
      ]),
    );
    final dataRoot = Directory(
      Platform.isWindows
          ? _joinPath(<String>[dataHome, 'MgRead', 'runtime'])
          : _joinPath(<String>[
              dataHome,
              'Library',
              'Application Support',
              'MgRead',
              'runtime',
            ]),
    );
    final developmentStarts = <Directory>[
      Directory.current,
      executableDirectory,
    ];
    final developmentRuntimeRoot = kDebugMode
        ? _findDevelopmentRuntimeRepository(developmentStarts)
        : null;
    final developmentPluginDirectory = kDebugMode
        ? (_readConfiguredDevelopmentPluginDirectory(dataRoot) ??
              _findDevelopmentPluginDirectory(developmentStarts))
        : null;
    final runtimeRoot = developmentRuntimeRoot ?? bundleRoot;
    final platformToolchain = Platform.isWindows
        ? 'node-v24.16.0-win-x64'
        : 'node-v24.16.0-darwin-arm64';
    final developmentNpmCli = developmentRuntimeRoot == null
        ? null
        : File(
            _joinPath(<String>[
              developmentRuntimeRoot.path,
              'tools',
              platformToolchain,
              if (Platform.isMacOS) 'lib',
              'node_modules',
              'npm',
              'bin',
              'npm-cli.js',
            ]),
          );
    final entrypoint = File(
      _joinPath(<String>[runtimeRoot.path, 'dist', 'cli.js']),
    );
    final nodeExecutable = developmentRuntimeRoot == null
        ? File(
            _joinPath(<String>[
              runtimeRoot.path,
              'node',
              Platform.isWindows ? 'MgReadNode.exe' : 'MgReadNode',
            ]),
          )
        : File(
            _joinPath(<String>[
              developmentRuntimeRoot.path,
              'tools',
              platformToolchain,
              if (Platform.isMacOS) 'bin',
              Platform.isWindows ? 'node.exe' : 'node',
            ]),
          );
    return _DesktopRuntimeBundle(
      dataRoot: dataRoot,
      bundledPluginDirectory: null,
      developmentPluginDirectory: developmentPluginDirectory,
      developmentNpmCli: developmentNpmCli,
      directoryLauncher: Platform.isWindows
          ? _openWithWindowsExplorer
          : _openWithMacOSFinder,
      entrypoint: entrypoint,
      nodeExecutable: nodeExecutable,
      testExitAfterReady: null,
      workingDirectory: runtimeRoot,
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
    final platformToolchain = Platform.isMacOS
        ? 'node-v24.16.0-darwin-arm64'
        : 'node-v24.16.0-win-x64';
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
      developmentNpmCli: File(
        _joinPath(<String>[
          runtimeRepositoryRoot.path,
          'tools',
          platformToolchain,
          if (Platform.isMacOS) 'lib',
          'node_modules',
          'npm',
          'bin',
          'npm-cli.js',
        ]),
      ),
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
              platformToolchain,
              if (Platform.isMacOS) 'bin',
              Platform.isMacOS ? 'node' : 'node.exe',
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

/// Starts Finder from the Flutter owner, outside the Node child process.
Future<void> _openWithMacOSFinder(Directory directory) async {
  await directory.create(recursive: true);
  await Process.start(
    '/usr/bin/open',
    <String>[directory.path],
    mode: ProcessStartMode.detached,
    runInShell: false,
  );
}

/// Prevents package tests from opening a user-visible file manager by default.
Future<void> _discardDirectoryOpen(Directory _) async {}

/// Owns exactly one desktop Node child, platform process ownership, and its loopback link.
///
/// This is the sole location where process launch, ready parsing, HTTP health,
/// WebSocket setup, structured diagnostics, and hard-stop cleanup are joined.
/// The public Facade intentionally exposes only typed capability invocations.
