import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'test_paths.dart';

void main() {
  test('production Facade construction is process-wide singleton', () {
    expect(identical(PluginRuntime(), PluginRuntime()), isTrue);
  });

  test(
    'Flutter Facade starts one bundled desktop Node Runtime and shares the WS bridge',
    () async {
      final repositoryRoot = nodeRuntimeRepositoryRoot;
      final fixture = await _desktopFixture(repositoryRoot);
      final runtime = PluginRuntime.desktopForTesting(
        runtimeRepositoryRoot: repositoryRoot,
      );
      addTearDown(runtime.debugDispose);

      // Exercise the same 128-call connection bound advertised by hello. All
      // callers must share one child startup and one internal WebSocket bridge.
      final results = await Future.wait<RuntimePingResult>(
        List<Future<RuntimePingResult>>.generate(
          128,
          (_) => runtime.invoke(const RuntimePingInvocation()),
        ),
      );

      expect(runtime.debugDesktopProcessStartCount, 1);
      for (final result in results) {
        expect(result.isHealthy, isTrue);
        expect(result.nodeVersion, fixture['nodeVersion']);
        expect(result.runtimeVersion, fixture['runtimeVersion']);
      }
    },
  );

  test('Flutter Facade decodes the Runtime status snapshot', () async {
    final repositoryRoot = nodeRuntimeRepositoryRoot;
    final runtime = PluginRuntime.desktopForTesting(
      runtimeRepositoryRoot: repositoryRoot,
    );
    addTearDown(runtime.debugDispose);

    final status = await runtime.invoke(const RuntimeStatusInvocation());

    expect(status.isHealthy, isTrue);
    expect(status.nodeVersion, '24.16.0');
    expect(status.runtimeKind, 'desktop-node');
    expect(status.uptimeMs, greaterThanOrEqualTo(0));
    expect(status.memory.rss, greaterThan(0));
    expect(
      status.memory.heapTotal,
      greaterThanOrEqualTo(status.memory.heapUsed),
    );
    expect(status.plugins, isA<List<InstalledPlugin>>());
  });

  test(
    'Flutter Facade enables and disables the transient Debug inspector',
    () async {
      final runtime = PluginRuntime.desktopForTesting(
        runtimeRepositoryRoot: nodeRuntimeRepositoryRoot,
      );
      addTearDown(runtime.debugDispose);

      final enabled = await runtime.setDebugHttpEnabled(true);
      expect(enabled.enabled, isTrue);
      expect(enabled.endpoints, isNotEmpty);
      expect(
        enabled.usingTemporaryPort,
        Uri.parse(enabled.endpoints.first).port != 52173,
      );
      final page = await HttpClient().getUrl(
        Uri.parse(enabled.endpoints.first),
      );
      final response = await page.close();
      expect(response.statusCode, 200);
      await response.drain();

      final disabled = await runtime.setDebugHttpEnabled(false);
      expect(disabled.enabled, isFalse);
      expect(disabled.endpoints, isEmpty);
      expect(disabled.usingTemporaryPort, isFalse);
    },
  );

  test(
    'Flutter Facade decodes an empty one-shot plugin recovery summary',
    () async {
      final runtime = PluginRuntime.desktopForTesting(
        runtimeRepositoryRoot: nodeRuntimeRepositoryRoot,
      );
      addTearDown(runtime.debugDispose);

      final first = await runtime.invoke(
        const PluginStartupRecoveryInvocation(),
      );
      final second = await runtime.invoke(
        const PluginStartupRecoveryInvocation(),
      );

      expect(first.quarantinedCount, 0);
      expect(second.quarantinedCount, 0);
    },
  );

  test(
    'Flutter desktop Supervisor opens the private Runtime directory outside Node',
    () async {
      final repositoryRoot = nodeRuntimeRepositoryRoot;
      final runtimeDataRoot = await Directory.systemTemp.createTemp(
        'mgread-runtime-private-directory-',
      );
      final openedDirectories = <String>[];
      final runtime = PluginRuntime.desktopForTesting(
        runtimeRepositoryRoot: repositoryRoot,
        runtimeDataRoot: runtimeDataRoot,
        directoryLauncher: (Directory directory) async {
          openedDirectories.add(directory.path);
        },
      );
      addTearDown(() async {
        await runtime.debugDispose();
        await runtimeDataRoot.delete(recursive: true);
      });

      await runtime.invoke(const OpenRuntimePrivateDirectoryInvocation());

      expect(openedDirectories, <String>[runtimeDataRoot.path]);
      expect(runtime.debugDesktopProcessStartCount, 0);
    },
  );

  test(
    'private Runtime directory shell failures stay safe and diagnosable',
    () async {
      final runtime = PluginRuntime.desktopForTesting(
        runtimeRepositoryRoot: nodeRuntimeRepositoryRoot,
        directoryLauncher: (Directory _) async {
          throw StateError('test-only shell failure');
        },
      );
      addTearDown(runtime.debugDispose);

      final error = await _captureRuntimeFailure(
        runtime.invoke(const OpenRuntimePrivateDirectoryInvocation()),
      );

      expect(error.code, 'runtime_private_directory_open_failed');
      expect(
        error.diagnostics.map(
          (RuntimeDiagnostic diagnostic) => diagnostic.code,
        ),
        contains('runtime_private_directory_open_failed'),
      );
      expect(
        error.diagnostics.map(
          (RuntimeDiagnostic diagnostic) => diagnostic.message,
        ),
        isNot(contains('test-only shell failure')),
      );
    },
  );

  test(
    'Flutter desktop Supervisor opens a source directory outside Node',
    () async {
      final repositoryRoot = nodeRuntimeRepositoryRoot;
      final runtimeDataRoot = await _stageInstalledStandardPlugin();
      final openedDirectories = <String>[];
      final runtime = PluginRuntime.desktopForTesting(
        runtimeRepositoryRoot: repositoryRoot,
        runtimeDataRoot: runtimeDataRoot,
        directoryLauncher: (Directory directory) async {
          openedDirectories.add(directory.path);
        },
      );
      addTearDown(() async {
        await runtime.debugDispose();
        await runtimeDataRoot.delete(recursive: true);
      });

      final kind = await runtime.invoke(
        const OpenPluginCodeDirectoryInvocation(
          pluginId: 'org.mgread.flutter.fixture',
        ),
      );

      if (Platform.isWindows || Platform.isMacOS) {
        expect(kind, PluginCodeDirectoryKind.installed);
        expect(openedDirectories, hasLength(1));
        expect(
          openedDirectories.single,
          endsWith(
            <String>[
              'plugins',
              'org.mgread.flutter.fixture',
              'versions',
              '1.0.0',
            ].join(Platform.pathSeparator),
          ),
        );
      } else {
        fail('Source-directory opening is only supported on desktop.');
      }
    },
  );

  test(
    'Flutter Facade lists and searches an installed standard Node plugin',
    () async {
      final repositoryRoot = nodeRuntimeRepositoryRoot;
      final runtimeDataRoot = await _stageInstalledStandardPlugin();
      addTearDown(() => runtimeDataRoot.delete(recursive: true));
      final runtime = PluginRuntime.desktopForTesting(
        runtimeRepositoryRoot: repositoryRoot,
        runtimeDataRoot: runtimeDataRoot,
      );
      final diagnostics = <RuntimeDiagnostic>[];
      final subscription = runtime.diagnostics.listen(diagnostics.add);
      addTearDown(() async {
        await subscription.cancel();
        await runtime.debugDispose();
      });

      final plugins = await runtime.invoke(const InstalledPluginsInvocation());
      final artifacts = await runtime.invoke(
        const PluginTransferListInvocation(),
      );
      expect(artifacts, hasLength(1));
      expect(artifacts.single.pluginId, 'org.mgread.flutter.fixture');
      expect(artifacts.single.version, '1.0.0');
      expect(artifacts.single.format, PluginArtifactFormat.singleFile);
      final plan = await runtime.invoke(
        PluginTransferPlanInvocation(artifacts: artifacts),
      );
      expect(plan.single.action, PluginTransferPlanAction.same);
      final exported = await runtime.exportPluginArtifact(artifacts.single);
      final exportedBytes = await exported.expand((chunk) => chunk).toList();
      expect(
        utf8.decode(exportedBytes),
        '/* MgRead test single-file artifact. */\n',
      );
      final cacheFile = File(
        <String>[
          runtimeDataRoot.path,
          'plugin-cache',
          'org.mgread.flutter.fixture',
          'cache.txt',
        ].join(Platform.pathSeparator),
      );
      await cacheFile.parent.create(recursive: true);
      await cacheFile.writeAsString('cached');
      final cacheUsage = await runtime.invoke(
        const PluginCacheUsageInvocation(),
      );
      expect(cacheUsage, hasLength(1));
      expect(cacheUsage.single.pluginId, 'org.mgread.flutter.fixture');
      expect(cacheUsage.single.bytes, 6);
      final singleCacheUsage = await runtime.invoke(
        const PluginCacheUsageInvocation(
          pluginId: 'org.mgread.flutter.fixture',
        ),
      );
      expect(singleCacheUsage, hasLength(1));
      expect(singleCacheUsage.single.pluginId, 'org.mgread.flutter.fixture');
      expect(singleCacheUsage.single.bytes, 6);
      final cacheClear = await runtime.invoke(
        const ClearPluginCacheInvocation(
          pluginId: 'org.mgread.flutter.fixture',
        ),
      );
      expect(cacheClear.items.single.status, PluginCacheClearStatus.cleared);
      expect(cacheClear.items.single.bytesBefore, 6);
      expect(cacheClear.items.single.bytesRemaining, 0);
      expect(await cacheFile.exists(), isFalse);
      final disabled = await runtime.invoke(
        const SetPluginEnabledInvocation(
          pluginId: 'org.mgread.flutter.fixture',
          enabled: false,
        ),
      );
      await expectLater(
        runtime.invoke(
          const SourceSearchInvocation(
            pluginId: 'org.mgread.flutter.fixture',
            query: 'Flutter',
          ),
        ),
        throwsA(
          isA<PluginRuntimeException>().having(
            (error) => error.code,
            'code',
            'plugin_disabled',
          ),
        ),
      );
      final enabled = await runtime.invoke(
        const SetPluginEnabledInvocation(
          pluginId: 'org.mgread.flutter.fixture',
          enabled: true,
        ),
      );
      await runtime.invoke(
        const SchedulePluginUninstallInvocation(
          pluginId: 'org.mgread.flutter.fixture',
        ),
      );
      final result = await runtime.invoke(
        const SourceSearchInvocation(
          pluginId: 'org.mgread.flutter.fixture',
          query: 'Flutter',
        ),
      );
      final suggestions = await runtime.invoke(
        const SourceSearchSuggestionsInvocation(
          pluginId: 'org.mgread.flutter.fixture',
        ),
      );
      final discovery = await runtime.invoke(
        const SourceDiscoverInvocation(pluginId: 'org.mgread.flutter.fixture'),
      );
      final slowNestedDiscovery = await runtime.invoke(
        const SourceDiscoverInvocation(
          pluginId: 'org.mgread.flutter.fixture',
          target: 'slow-nested',
        ),
      );
      expect(suggestions.items, isEmpty);
      expect(slowNestedDiscovery, isA<PluginDiscoveryDocumentResult>());
      final detail = await runtime.invoke(
        SourceDetailInvocation(
          pluginId: 'org.mgread.flutter.fixture',
          id: result.items.single.id,
        ),
      );
      final chapters = await runtime.invoke(
        SourceChaptersInvocation(
          pluginId: 'org.mgread.flutter.fixture',
          id: result.items.single.id,
        ),
      );
      final largeChapters = await runtime.invoke(
        const SourceChaptersInvocation(
          pluginId: 'org.mgread.flutter.fixture',
          id: 'flutter:large-catalog',
        ),
      );
      final content = await runtime.invoke(
        SourceContentInvocation(
          pluginId: 'org.mgread.flutter.fixture',
          id: result.items.single.id,
          chapterId: chapters.items.single.id,
        ),
      );
      final mangaContent = await runtime.invoke(
        SourceContentInvocation(
          pluginId: 'org.mgread.flutter.fixture',
          id: result.items.single.id,
          chapterId: 'manga',
        ),
      );
      await _waitForDiagnosticCodes(diagnostics, const <String>[
        'plugin_load_started',
        'plugin_load_completed',
        'plugin_runtime_initialized',
        'plugin_invocation_started',
        'plugin_invocation_completed',
      ]);
      expect(
        diagnostics.map((diagnostic) => diagnostic.code),
        isNot(contains('plugin_log_emitted')),
      );

      expect(plugins, hasLength(1));
      expect(plugins.single.id, 'org.mgread.flutter.fixture');
      expect(plugins.single.displayName, 'Flutter 标准测试数据源');
      expect(plugins.single.activeVersion, '1.0.0');
      expect(plugins.single.iconUrl, isNull);
      expect(disabled.enabled, isFalse);
      expect(disabled.status, 'disabled');
      expect(enabled.enabled, isTrue);
      expect(enabled.status, 'active');
      expect(result.pluginId, 'org.mgread.flutter.fixture');
      expect(result.items.single.id, 'flutter:Flutter');
      expect(result.items.single.title, '标准 Node：Flutter');
      expect(result.items.single.author, 'org.mgread.flutter.fixture');
      expect(result.items.single.wordCount, 123456);
      expect(result.items.single.coverUrl, isNull);
      expect(result.items.single.tags, isEmpty);
      expect(result.totalCount, 1);
      expect(discovery, isA<PluginDiscoveryDocumentResult>());
      final document = discovery as PluginDiscoveryDocumentResult;
      expect(
        document.document.components
            .whereType<PluginDiscoverySectionComponent>(),
        isNotEmpty,
      );
      final discoverySection = document.document.components
          .whereType<PluginDiscoverySectionComponent>()
          .single;
      expect(discoverySection.icon, PluginDiscoveryIcon.recommendation);
      expect(
        discoverySection.children
            .whereType<PluginDiscoveryContentCollectionComponent>()
            .map((component) => component.layout),
        containsAll(<PluginDiscoveryContentLayout>[
          PluginDiscoveryContentLayout.featured,
          PluginDiscoveryContentLayout.coverGrid,
          PluginDiscoveryContentLayout.shelf,
          PluginDiscoveryContentLayout.compact,
        ]),
      );
      expect(
        discoverySection.children
            .whereType<PluginDiscoveryCategoryCollectionComponent>()
            .single
            .layout,
        PluginDiscoveryCategoryLayout.chips,
      );
      expect(
        discoverySection.children
            .whereType<PluginDiscoveryCategoryCollectionComponent>()
            .single
            .categories
            .single
            .icon,
        PluginDiscoveryIcon.video,
      );
      expect(detail.catalogUrl, isNull);
      expect(chapters.items.single.order, 0);
      expect(largeChapters.items, hasLength(733));
      expect(largeChapters.items.last.order, 732);
      expect(content.contentKind, PluginContentKind.novel);
      expect(content.text, 'Flutter 标准正文。');
      expect(mangaContent.contentKind, PluginContentKind.manga);
      expect(
        mangaContent.pages.single.resourcePolicy,
        PluginMangaPageResourcePolicy.sessionOnly,
      );
      expect(mangaContent.pages.single.expiresAt, isNull);
      final largerDiscovery = await runtime.invoke(
        const SourceDiscoverInvocation(
          pluginId: 'org.mgread.flutter.fixture',
          pageSize: 50,
        ),
      );
      // The browser fixture uses its full host deadline; Node tests cover the Runtime timeout.
      expect(largerDiscovery, isA<PluginDiscoveryDocumentResult>());
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'desktop development source changes build and hot reload without restarting Runtime',
    () async {
      final repositoryRoot = nodeRuntimeRepositoryRoot;
      final root = await Directory.systemTemp.createTemp(
        'mgread-flutter-development-source-',
      );
      final developmentRoot = Directory(
        <String>[root.path, 'sources'].join(Platform.pathSeparator),
      );
      final runtimeDataRoot = Directory(
        <String>[root.path, 'runtime-data'].join(Platform.pathSeparator),
      );
      addTearDown(() => root.delete(recursive: true));
      await _writeDevelopmentPlugin(developmentRoot, '第一版');
      final runtime = PluginRuntime.desktopForTesting(
        runtimeRepositoryRoot: repositoryRoot,
        runtimeDataRoot: runtimeDataRoot,
        developmentPluginRoot: developmentRoot,
      );
      addTearDown(runtime.debugDispose);

      final plugins = await runtime.invoke(const InstalledPluginsInvocation());
      final first = await runtime.invoke(
        const SourceSearchInvocation(
          pluginId: 'org.example.flutter-live',
          query: '测试',
        ),
      );
      expect(plugins.single.status, 'development');
      expect(first.items.single.title, '第一版：测试');
      expect(runtime.debugDesktopProcessStartCount, 1);

      final changed = runtime.developmentChanges.firstWhere(
        (batch) => batch.changes.any(
          (change) =>
              change.kind == DevelopmentPluginChangeKind.updated &&
              change.pluginId == 'org.example.flutter-live',
        ),
      );
      await _writeDevelopmentPlugin(developmentRoot, '第二版');
      await changed.timeout(const Duration(seconds: 15));
      final second = await runtime.invoke(
        const SourceSearchInvocation(
          pluginId: 'org.example.flutter-live',
          query: '测试',
        ),
      );
      expect(second.items.single.title, '第二版：测试');
      expect(runtime.debugDesktopProcessStartCount, 1);
      expect(
        Directory(
          <String>[
            runtimeDataRoot.path,
            'plugins',
            'org.example.flutter-live',
          ].join(Platform.pathSeparator),
        ).existsSync(),
        isFalse,
      );
    },
    skip: Platform.isMacOS,
  );

  test('closed test Runtime rejects another Facade capability call', () async {
    final runtime = PluginRuntime.desktopForTesting(
      runtimeRepositoryRoot: nodeRuntimeRepositoryRoot,
    );
    addTearDown(runtime.debugDispose);

    await runtime.invoke(const RuntimePingInvocation());
    await runtime.debugDispose();

    await expectLater(
      runtime.invoke(const RuntimePingInvocation()),
      throwsA(
        isA<PluginRuntimeException>().having(
          (error) => error.code,
          'code',
          'runtime_unavailable',
        ),
      ),
    );
  });

  test(
    'Facade reports a missing packaged Node executable with a stable reason',
    () async {
      final repositoryRoot = nodeRuntimeRepositoryRoot;
      final runtime = PluginRuntime.desktopForTesting(
        runtimeRepositoryRoot: repositoryRoot,
        nodeExecutableOverride: File(
          <String>[
            repositoryRoot.path,
            'missing-node.exe',
          ].join(Platform.pathSeparator),
        ),
      );
      final diagnostics = <RuntimeDiagnostic>[];
      final subscription = runtime.diagnostics.listen(diagnostics.add);
      addTearDown(() async {
        await subscription.cancel();
        await runtime.debugDispose();
      });

      late PluginRuntimeException error;
      for (var attempt = 0; attempt < 96; attempt += 1) {
        error = await _captureRuntimeFailure(
          runtime.invoke(const RuntimePingInvocation()),
        );
      }
      await Future<void>.delayed(Duration.zero);

      expect(error.code, 'runtime_node_executable_missing');
      expect(
        error.diagnostics.map((diagnostic) => diagnostic.code),
        contains('runtime_node_executable_missing'),
      );
      expect(
        diagnostics.map((diagnostic) => diagnostic.code),
        contains('runtime_node_executable_missing'),
      );
    },
  );

  test(
    'Facade reports a missing packaged main script with a stable reason',
    () async {
      final repositoryRoot = nodeRuntimeRepositoryRoot;
      final runtime = PluginRuntime.desktopForTesting(
        runtimeRepositoryRoot: repositoryRoot,
        entrypointOverride: File(
          <String>[
            repositoryRoot.path,
            'missing-runtime-main.mjs',
          ].join(Platform.pathSeparator),
        ),
      );
      addTearDown(runtime.debugDispose);

      final error = await _captureRuntimeFailure(
        runtime.invoke(const RuntimePingInvocation()),
      );

      expect(error.code, 'runtime_entrypoint_missing');
      expect(
        error.diagnostics.map((diagnostic) => diagnostic.code),
        contains('runtime_entrypoint_missing'),
      );
    },
  );

  test(
    'Facade preserves a structured Node startup failure diagnostic',
    () async {
      final repositoryRoot = nodeRuntimeRepositoryRoot;
      final runtime = PluginRuntime.desktopForTesting(
        runtimeRepositoryRoot: repositoryRoot,
        entrypointOverride: File(
          <String>[
            repositoryRoot.path,
            'test',
            'fixtures',
            'fatal-before-ready.mjs',
          ].join(Platform.pathSeparator),
        ),
      );
      addTearDown(runtime.debugDispose);

      final error = await _captureRuntimeFailure(
        runtime.invoke(const RuntimePingInvocation()),
      );

      expect(error.code, 'runtime_start_failed');
      expect(
        error.diagnostics.map((diagnostic) => diagnostic.code),
        contains('test_startup_failure'),
      );
    },
  );

  test(
    'a child exit before ready becomes a fatal Facade diagnostic and bounded fallback TXT',
    () async {
      final repositoryRoot = nodeRuntimeRepositoryRoot;
      final runtimeDataRoot = await Directory.systemTemp.createTemp(
        'mgread-runtime-preboot-fallback-',
      );
      final runtime = PluginRuntime.desktopForTesting(
        runtimeRepositoryRoot: repositoryRoot,
        runtimeDataRoot: runtimeDataRoot,
        entrypointOverride: File(
          <String>[
            pluginRuntimeRepositoryRoot.path,
            'test',
            'fixtures',
            'exit-before-ready.mjs',
          ].join(Platform.pathSeparator),
        ),
      );
      addTearDown(() async {
        await runtime.debugDispose();
        await runtimeDataRoot.delete(recursive: true);
      });

      final error = await _captureRuntimeFailure(
        runtime.invoke(const RuntimePingInvocation()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final fallback = File(
        <String>[
          runtimeDataRoot.path,
          'diagnostics',
          'desktop-fatal-fallback.txt',
        ].join(Platform.pathSeparator),
      );
      final contents = await fallback.readAsString();

      expect(error.code, 'runtime_exited_before_ready');
      expect(
        error.diagnostics
            .singleWhere((item) => item.code == error.code)
            .isFatal,
        isTrue,
      );
      expect(contents, contains('"code":"runtime_exited_before_ready"'));
      expect(contents, contains('"phase":"startup"'));
      expect(contents, contains('"fingerprint":'));
      expect(contents, isNot(contains(runtimeDataRoot.path)));
      expect(contents, isNot(contains('exit-before-ready.mjs')));
      expect((await fallback.length()), lessThanOrEqualTo(16 * 1024));
    },
  );

  test(
    'a post-ready child exit emits a fatal diagnostic and only restarts on the next invocation',
    () async {
      final runtime = PluginRuntime.desktopForTesting(
        runtimeRepositoryRoot: nodeRuntimeRepositoryRoot,
        testExitAfterReady: const Duration(milliseconds: 250),
      );
      final fatalDiagnostics = <RuntimeDiagnostic>[];
      final subscription = runtime.fatalDiagnostics.listen(
        fatalDiagnostics.add,
      );
      addTearDown(() async {
        await subscription.cancel();
        await runtime.debugDispose();
      });

      await runtime.invoke(const RuntimePingInvocation());
      await _waitForDiagnosticCodes(fatalDiagnostics, const <String>[
        'runtime_process_exited',
      ]);
      expect(fatalDiagnostics.single.isFatal, isTrue);
      expect(runtime.debugDesktopProcessStartCount, 1);

      await runtime.invoke(const RuntimePingInvocation());
      expect(runtime.debugDesktopProcessStartCount, 2);
    },
  );
}

/// Captures the Facade's safe exception while failing tests that unexpectedly pass.
Future<PluginRuntimeException> _captureRuntimeFailure(
  Future<Object?> future,
) async {
  try {
    await future;
  } on PluginRuntimeException catch (error) {
    return error;
  }
  fail('Expected the Runtime operation to fail.');
}

/// Reads the checked-in cross-language desktop fixture through a typed JSON boundary.
Future<Map<String, Object?>> _desktopFixture(Directory repositoryRoot) async {
  final fixtureFile = File(
    <String>[
      repositoryRoot.path,
      'protocol',
      'fixtures',
      'standard-node-plugin-v1.json',
    ].join(Platform.pathSeparator),
  );
  final Object? decoded = jsonDecode(await fixtureFile.readAsString());
  expect(decoded, isA<Map<Object?, Object?>>());
  return <String, Object?>{
    for (final MapEntry<Object?, Object?> entry
        in (decoded as Map<Object?, Object?>).entries)
      if (entry.key case final String key) key: entry.value,
  };
}

/// Waits only for child stderr delivery; it never retries a Runtime operation.
Future<void> _waitForDiagnosticCodes(
  List<RuntimeDiagnostic> diagnostics,
  List<String> requiredCodes,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 1));
  while (DateTime.now().isBefore(deadline)) {
    final observedCodes = diagnostics
        .map((diagnostic) => diagnostic.code)
        .toSet();
    if (requiredCodes.every(observedCodes.contains)) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  fail(
    'Timed out waiting for Runtime diagnostics. Observed: '
    '${diagnostics.map((diagnostic) => diagnostic.code).join(', ')}',
  );
}

Future<Directory> _stageInstalledStandardPlugin() async {
  final root = await Directory.systemTemp.createTemp(
    'mgread-flutter-plugin-runtime-',
  );
  final pluginRoot = Directory(
    <String>[
      root.path,
      'plugins',
      'org.mgread.flutter.fixture',
    ].join(Platform.pathSeparator),
  );
  final versionRoot = Directory(
    <String>[pluginRoot.path, 'versions', '1.0.0'].join(Platform.pathSeparator),
  );
  final dist = Directory(
    <String>[versionRoot.path, 'dist'].join(Platform.pathSeparator),
  );
  await dist.create(recursive: true);
  await File(
    <String>[versionRoot.path, 'package.json'].join(Platform.pathSeparator),
  ).writeAsString('''
{
  "name": "@mgread-plugin/flutter-fixture",
  "version": "1.0.0",
  "type": "module",
  "main": "dist/index.mjs",
  "engines": { "node": ">=24 <25" },
  "mgread": {
    "schemaVersion": 1,
    "id": "org.mgread.flutter.fixture",
    "displayName": "Flutter 标准测试数据源",
    "pluginApi": 1,
    "contentKinds": ["novel"]
  }
}

''');
  await File(
    <String>[
      versionRoot.path,
      'package-lock.json',
    ].join(Platform.pathSeparator),
  ).writeAsString('''
{
  "name": "@mgread-plugin/flutter-fixture",
  "version": "1.0.0",
  "lockfileVersion": 3,
  "requires": true,
  "packages": {
    "": {
      "name": "@mgread-plugin/flutter-fixture",
      "version": "1.0.0"
    }
  }
}
''');
  await File(
    <String>[dist.path, 'index.mjs'].join(Platform.pathSeparator),
  ).writeAsString('''
let context;
export async function activate(nextContext) {
  context = nextContext;
  context.log.info('flutter_fixture_activated');
}
function summary(query) {
  const id = `flutter:\${query}`;
  return {
    id,
    title: `标准 Node：\${query}`,
    contentKind: 'novel', coverOrientation: 'landscape',
    author: context.plugin.id,
    url: null,
    coverUrl: null,
    description: null,
    language: 'zh-CN',
    status: 'ongoing',
    access: 'free',
    wordCount: 123456,
    chapterCount: 1,
    publishedAt: null,
    updatedAt: '2026-08-15T00:00:00Z',
    latestChapter: {
      id: `\${id}:chapter-1`,
      title: '第一章',
      url: null,
      updatedAt: '2026-08-15T00:00:00Z',
    },
    categories: [],
    tags: [],
    attributes: [],
  };
}
export async function discover(request) {
  if (request.target === 'slow-nested' || (request.target === null && request.pageSize === 50)) {
    await new Promise((resolve) => setTimeout(resolve, 5500));
  }
  return {
    kind: 'document',
    document: { components: [{
      type: 'section',
      id: 'featured-section',
      title: '精选',
      subtitle: null,
      icon: 'recommendation',
      children: [{
        type: 'contentCollection',
        id: 'featured',
        layout: 'featured',
        continuation: null,
        items: [{
          content: summary('发现'),
          rank: null,
          metric: null,
          recommendation: null,
        }],
      }, ...['coverGrid', 'shelf', 'compact'].map((layout) => ({
        type: 'contentCollection',
        id: `layout-\${layout}`,
        layout,
        continuation: null,
        items: [{
          content: summary(layout),
          rank: layout === 'compact' ? 1 : null,
          metric: null,
          recommendation: null,
        }],
      })), {
        type: 'categoryCollection',
        id: 'category-chips',
        layout: 'chips',
        categories: [{ id: 'video', title: '视频', target: 'video', count: null, url: null, icon: 'video' }],
      }],
    }] },
  };
}
export async function search(request) {
  return { items: [summary(request.query)], nextCursor: null, totalCount: 1 };
}
export async function getDetail(request) {
  return {
    ...summary(request.id),
    id: request.id,
    aliases: [],
    catalogUrl: null,
  };
}
export async function getChapters(request) {
  const count = request.id === 'flutter:large-catalog' ? 733 : 1;
  return {
    items: Array.from({ length: count }, (_, index) => ({
      id: `\${request.id}:chapter-\${index + 1}`,
      title: `第\${index + 1}章\${'大'.repeat(60)}`,
      order: index,
      url: null,
      volumeTitle: null,
      wordCount: 12,
      updatedAt: null,
      isLocked: false,
      attributes: [],
    })),
  };
}
export async function getContent(request) {
  if (request.chapterId === 'manga') return { contentKind: 'manga', chapterId: request.chapterId, title: null, updatedAt: null, text: null, pages: [{ id: 'page:0', index: 0, url: 'https://example.invalid/page/0', mimeType: null, width: null, height: null }] };
  return {
    contentKind: 'novel',
    chapterId: request.chapterId,
    title: '第一章',
    updatedAt: null,
    text: 'Flutter 标准正文。',
    pages: [],
  };
}
''');
  await File(
    <String>[pluginRoot.path, 'pending'].join(Platform.pathSeparator),
  ).writeAsString('1.0.0\n');
  final artifactRoot = Directory(
    <String>[
      root.path,
      'plugin-archives',
      'org.mgread.flutter.fixture',
    ].join(Platform.pathSeparator),
  );
  await artifactRoot.create(recursive: true);
  await File(
    <String>[
      artifactRoot.path,
      '1.0.0.mgplugin.js',
    ].join(Platform.pathSeparator),
  ).writeAsString('/* MgRead test single-file artifact. */\n');
  return root;
}

Future<void> _writeDevelopmentPlugin(
  Directory developmentRoot,
  String prefix,
) async {
  final projectRoot = Directory(
    <String>[developmentRoot.path, 'live-source'].join(Platform.pathSeparator),
  );
  final dist = Directory(
    <String>[projectRoot.path, 'dist'].join(Platform.pathSeparator),
  );
  final src = Directory(
    <String>[projectRoot.path, 'src'].join(Platform.pathSeparator),
  );
  await Future.wait(<Future<void>>[
    dist.create(recursive: true),
    src.create(recursive: true),
  ]);
  const packageName = '@mgread-plugin/flutter-live';
  const version = '0.1.0';
  await File(
    <String>[projectRoot.path, 'package.json'].join(Platform.pathSeparator),
  ).writeAsString(
    '${jsonEncode(<String, Object?>{
      'name': packageName,
      'version': version,
      'type': 'module',
      'main': 'dist/index.mjs',
      'scripts': <String, String>{'build': 'node build.mjs'},
      'engines': <String, String>{'node': '>=24 <25'},
      'mgread': <String, Object?>{
        'schemaVersion': 1,
        'id': 'org.example.flutter-live',
        'displayName': 'Flutter Live',
        'pluginApi': 1,
        'contentKinds': <String>['novel'],
      },
    })}\n',
  );
  await File(
    <String>[
      projectRoot.path,
      'package-lock.json',
    ].join(Platform.pathSeparator),
  ).writeAsString(
    '${jsonEncode(<String, Object?>{
      'name': packageName,
      'version': version,
      'lockfileVersion': 3,
      'requires': true,
      'packages': <String, Object?>{
        '': <String, String>{'name': packageName, 'version': version},
      },
    })}\n',
  );
  await File(
    <String>[projectRoot.path, 'build.mjs'].join(Platform.pathSeparator),
  ).writeAsString(
    "import { copyFile } from 'node:fs/promises';\n"
    "await copyFile(new URL('./src/index.mjs', import.meta.url), "
    "new URL('./dist/index.mjs', import.meta.url));\n",
  );
  final source =
      '''
export function activate() {} const summary = (query) => ({
  id: 'live:' + query,
  title: ${jsonEncode(prefix)} + '：' + query,
  contentKind: 'novel', author: null, url: null, coverUrl: null, description: null, language: null, status: 'unknown', access: 'unknown',
  wordCount: null, chapterCount: 0, publishedAt: null, updatedAt: null, latestChapter: null, categories: [], tags: [], attributes: [],
});
export function discover() { return { kind: 'document', document: { components: [] } }; } export function search(request) { return { items: [summary(request.query)], nextCursor: null, totalCount: 1 }; }
export function getDetail(request) { return { ...summary(request.id), id: request.id, aliases: [], catalogUrl: null }; } export function getChapters() { return { items: [], nextCursor: null, totalCount: 0 }; }
export function getContent(request) { return { contentKind: 'novel', chapterId: request.chapterId, title: null, updatedAt: null, text: 'text', pages: [] }; }
''';
  await File(
    <String>[src.path, 'index.mjs'].join(Platform.pathSeparator),
  ).writeAsString(source);
  if (!await File(
    <String>[dist.path, 'index.mjs'].join(Platform.pathSeparator),
  ).exists()) {
    await File(
      <String>[dist.path, 'index.mjs'].join(Platform.pathSeparator),
    ).writeAsString(source);
  }
}
