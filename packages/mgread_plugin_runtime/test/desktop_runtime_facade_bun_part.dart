/// Real child-process tests: engine identity, shared data and cold recovery.
part of 'desktop_runtime_facade_test.dart';

void _registerBunRuntimeTests() {
  test('Node Bun Node roundtrip retains installed sources and content', () async {
    final root = await _stageInstalledStandardPlugin();
    addTearDown(() => root.delete(recursive: true));
    final manifest = File(
      '${root.path}/plugins/org.mgread.flutter.fixture/versions/1.0.0/package.json',
    );
    final metadata =
        jsonDecode(await manifest.readAsString()) as Map<String, dynamic>;
    metadata['engines'] = {'node': '>=24'};
    await manifest.writeAsString(jsonEncode(metadata));
    for (final backend in [
      DesktopRuntimeBackend.node,
      DesktopRuntimeBackend.bun,
      DesktopRuntimeBackend.node,
    ]) {
      final runtime = PluginRuntime.desktopForTesting(
        runtimeRepositoryRoot: nodeRuntimeRepositoryRoot,
        runtimeDataRoot: root,
        backend: backend,
      );
      try {
        final status = await runtime.invoke(const RuntimeStatusInvocation());
        expect(
          status.runtimeKind,
          backend == DesktopRuntimeBackend.bun ? 'desktop-bun' : 'desktop-node',
        );
        expect(
          status.bunVersion,
          backend == DesktopRuntimeBackend.bun
              ? DesktopRuntimeSettings.bunVersion
              : null,
        );
        expect(status.memory.rss, greaterThan(0));
        final sources = await runtime.invoke(
          const InstalledPluginsInvocation(),
        );
        expect(sources.single.id, 'org.mgread.flutter.fixture');
        expect(
          await runtime.invoke(
            const SourceDiscoverInvocation(
              pluginId: 'org.mgread.flutter.fixture',
            ),
          ),
          isA<PluginDiscoveryDocumentResult>(),
        );
        final search = await runtime.invoke(
          const SourceSearchInvocation(
            pluginId: 'org.mgread.flutter.fixture',
            query: 'Bun',
          ),
        );
        final id = search.items.single.id;
        final detail = await runtime.invoke(
          SourceDetailInvocation(pluginId: sources.single.id, id: id),
        );
        expect(detail.summary.id, id);
        final chapters = await runtime.invoke(
          SourceChaptersInvocation(pluginId: sources.single.id, id: id),
        );
        final content = await runtime.invoke(
          SourceContentInvocation(
            pluginId: sources.single.id,
            id: id,
            chapterId: chapters.items.single.id,
          ),
        );
        expect(content, isNotNull);
        final artifacts = await runtime.invoke(
          const PluginTransferListInvocation(),
        );
        expect(artifacts.single.pluginId, sources.single.id);
        expect(
          await (await runtime.exportPluginArtifact(
            artifacts.single,
          )).expand((chunk) => chunk).toList(),
          isNotEmpty,
        );
        await runtime.configureNodeEnvironmentProxy(true);
        expect(
          (await runtime.invoke(const RuntimePingInvocation())).isHealthy,
          isTrue,
        );
        expect(runtime.debugDesktopProcessStartCount, 2);
      } finally {
        await runtime.debugDispose();
      }
    }
  }, timeout: const Timeout(Duration(seconds: 90)));

  test(
    'Bun starts once for concurrent callers and disposes its process',
    () async {
      final runtime = PluginRuntime.desktopForTesting(
        runtimeRepositoryRoot: nodeRuntimeRepositoryRoot,
        backend: DesktopRuntimeBackend.bun,
      );
      addTearDown(runtime.debugDispose);
      final results = await Future.wait(
        List.generate(
          128,
          (_) => runtime.invoke(const RuntimePingInvocation()),
        ),
      );
      expect(results.every((result) => result.isHealthy), isTrue);
      expect(runtime.debugDesktopProcessStartCount, 1);
      await runtime.debugDispose();
    },
  );

  test(
    'Bun selection rejects a Node helper without weakening version checks',
    () async {
      final node = File.fromUri(
        nodeRuntimeRepositoryRoot.uri.resolve(
          Platform.isMacOS
              ? 'tools/node-v26.10.0-darwin-arm64/bin/node'
              : 'tools/node-v26.10.0-win-x64/node.exe',
        ),
      );
      // Node cannot accept Bun-specific flags, so a wrong binary must fail closed.
      final runtime = PluginRuntime.desktopForTesting(
        runtimeRepositoryRoot: nodeRuntimeRepositoryRoot,
        backend: DesktopRuntimeBackend.bun,
        nodeExecutableOverride: node,
      );
      addTearDown(runtime.debugDispose);
      await expectLater(
        runtime.invoke(const RuntimePingInvocation()),
        throwsA(isA<PluginRuntimeException>()),
      );
    },
  );

  test(
    'missing Bun executable produces an actionable typed startup error',
    () async {
      final runtime = PluginRuntime.desktopForTesting(
        runtimeRepositoryRoot: nodeRuntimeRepositoryRoot,
        backend: DesktopRuntimeBackend.bun,
        nodeExecutableOverride: File('missing-bun.exe'),
      );
      addTearDown(runtime.debugDispose);
      await expectLater(
        runtime.invoke(const RuntimePingInvocation()),
        throwsA(
          isA<PluginRuntimeException>().having(
            (error) => error.code,
            'code',
            'runtime_bun_executable_missing',
          ),
        ),
      );
    },
  );
}
