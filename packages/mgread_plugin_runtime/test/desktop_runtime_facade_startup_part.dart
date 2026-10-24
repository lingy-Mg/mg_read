/// Desktop Runtime Facade startup, transport, and capability tests.
part of 'desktop_runtime_facade_test.dart';

void _registerDesktopRuntimeStartupTests() {
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
    expect(status.nodeVersion, '26.10.0');
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
    'Flutter desktop Supervisor opens the retained artifact when installed code is missing',
    () async {
      final runtimeDataRoot = await _stageInstalledStandardPlugin();
      final openedDirectories = <String>[];
      final runtime = PluginRuntime.desktopForTesting(
        runtimeRepositoryRoot: nodeRuntimeRepositoryRoot,
        runtimeDataRoot: runtimeDataRoot,
        directoryLauncher: (Directory directory) async {
          openedDirectories.add(directory.path);
        },
      );
      addTearDown(() async {
        await runtime.debugDispose();
        await runtimeDataRoot.delete(recursive: true);
      });

      await runtime.invoke(const InstalledPluginsInvocation());
      final archiveRoot = Directory(
        <String>[
          runtimeDataRoot.path,
          'plugin-archives',
          'org.mgread.flutter.fixture',
        ].join(Platform.pathSeparator),
      );
      await archiveRoot.create(recursive: true);
      await File(
        <String>[
          archiveRoot.path,
          '1.0.0.mgplugin',
        ].join(Platform.pathSeparator),
      ).writeAsString('retained artifact');
      await Directory(
        <String>[
          runtimeDataRoot.path,
          'plugins',
          'org.mgread.flutter.fixture',
          'versions',
          '1.0.0',
        ].join(Platform.pathSeparator),
      ).delete(recursive: true);

      final kind = await runtime.invoke(
        const OpenPluginCodeDirectoryInvocation(
          pluginId: 'org.mgread.flutter.fixture',
        ),
      );
      expect(kind, PluginCodeDirectoryKind.archive);
      expect(openedDirectories, <String>[archiveRoot.path]);
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
      expect(plugins.single.r18, isTrue);
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
      expect(
        result.items.single.coverOrientation,
        PluginCoverOrientation.square,
      );
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
      await runtime.invoke(
        const UninstallPluginInvocation(pluginId: 'org.mgread.flutter.fixture'),
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
            'plugin_not_found',
          ),
        ),
      );
      await runtime.invoke(const UninstallAllPluginsInvocation());
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'caller cancellation ends a desktop source invocation without closing Runtime',
    () async {
      final runtimeDataRoot = await _stageInstalledStandardPlugin();
      addTearDown(() => runtimeDataRoot.delete(recursive: true));
      final runtime = PluginRuntime.desktopForTesting(
        runtimeRepositoryRoot: nodeRuntimeRepositoryRoot,
        runtimeDataRoot: runtimeDataRoot,
      );
      addTearDown(runtime.debugDispose);
      await runtime.invoke(const InstalledPluginsInvocation());

      final cancellation = PluginInvocationCancellation();
      final stopwatch = Stopwatch()..start();
      unawaited(
        Future<void>.delayed(
          const Duration(milliseconds: 100),
          cancellation.cancel,
        ),
      );

      await expectLater(
        runtime.invoke(
          const SourceDiscoverInvocation(
            pluginId: 'org.mgread.flutter.fixture',
            target: 'slow-nested',
          ),
          cancellation: cancellation,
        ),
        throwsA(
          isA<PluginRuntimeException>().having(
            (error) => error.code,
            'code',
            'cancelled',
          ),
        ),
      );
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
      expect(
        (await runtime.invoke(const RuntimePingInvocation())).isHealthy,
        isTrue,
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'bulk uninstall waits for an active source call beyond the control timeout',
    () async {
      final runtimeDataRoot = await _stageInstalledStandardPlugin();
      final runtime = PluginRuntime.desktopForTesting(
        runtimeRepositoryRoot: nodeRuntimeRepositoryRoot,
        runtimeDataRoot: runtimeDataRoot,
      );
      addTearDown(() async {
        await runtime.debugDispose();
        await runtimeDataRoot.delete(recursive: true);
      });

      final slowDiscovery = runtime.invoke(
        const SourceDiscoverInvocation(
          pluginId: 'org.mgread.flutter.fixture',
          target: 'slow-nested',
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await runtime.invoke(const UninstallAllPluginsInvocation());

      expect(await slowDiscovery, isA<PluginDiscoveryDocumentResult>());
      expect(await runtime.invoke(const InstalledPluginsInvocation()), isEmpty);
    },
    timeout: const Timeout(Duration(seconds: 20)),
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
  );
}
