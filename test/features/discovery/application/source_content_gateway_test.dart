import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';

import '../../../core/diagnostics/diagnostics_testkit.dart';

void main() {
  test(
    'available source projection is cached for the process session',
    () async {
      final gateway = _CountingSourceGateway();
      final container = ProviderContainer(
        overrides: [sourceContentGatewayProvider.overrideWithValue(gateway)],
      );
      addTearDown(container.dispose);

      final first = await container.read(availablePluginSourcesProvider.future);
      final second = await container.read(
        availablePluginSourcesProvider.future,
      );

      expect(gateway.listCalls, 1);
      expect(identical(first, second), isTrue);
      expect(first.single.displayName, '缓存书源');
    },
  );

  test('source list waits for the shared Runtime readiness result', () async {
    final diagnostics = DiagnosticsTestkit();
    addTearDown(diagnostics.dispose);
    final readiness = Completer<PluginRuntimeConnection>();
    final container = ProviderContainer(
      overrides: [
        diagnosticsManagerProvider.overrideWithValue(diagnostics.manager),
        pluginRuntimeConnectionProvider.overrideWith((ref) => readiness.future),
      ],
    );
    addTearDown(container.dispose);

    var completed = false;
    final sources = container
        .read(sourceContentGatewayProvider)
        .listSources()
        .then((value) {
          completed = true;
          return value;
        });
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);

    readiness.complete(
      const PluginRuntimeConnection(
        isHealthy: true,
        nodeVersion: '24.16.0',
        runtimeVersion: '0.2.0-standard.2',
        plugins: <PluginRuntimePlugin>[
          PluginRuntimePlugin(
            activeVersion: '1.0.0',
            contentKinds: <String>['novel'],
            displayName: '已就绪书源',
            enabled: true,
            id: 'org.example.ready',
            name: 'ready',
            pendingVersion: null,
            status: 'active',
          ),
          PluginRuntimePlugin(
            activeVersion: null,
            contentKinds: <String>['manga'],
            displayName: '未激活书源',
            enabled: true,
            id: 'org.example.pending',
            name: 'pending',
            pendingVersion: '1.0.0',
            status: 'pendingActivation',
          ),
        ],
      ),
    );

    expect(await sources, hasLength(1));
    expect((await sources).single.id, 'org.example.ready');
  });
}

final class _CountingSourceGateway implements SourceContentGateway {
  int listCalls = 0;

  @override
  Future<List<PluginSourceDescriptor>> listSources() async {
    listCalls += 1;
    return <PluginSourceDescriptor>[
      PluginSourceDescriptor(
        id: 'source.cached',
        displayName: '缓存书源',
        contentKinds: const <PluginContentKind>[PluginContentKind.novel],
      ),
    ];
  }

  @override
  Future<PluginSearchResult> search({
    required String pluginId,
    required String query,
    String? cursor,
    int pageSize = 20,
  }) => throw UnsupportedError('Not used by source cache test.');

  @override
  Future<PluginSearchSuggestionsResult> searchSuggestions({
    required String pluginId,
    String? cursor,
    int pageSize = 20,
  }) => throw UnsupportedError('Not used by source cache test.');

  @override
  Future<PluginDiscoverResult> discover({
    required String pluginId,
    String? target,
    String? cursor,
    String? collectionId,
    int pageSize = 20,
  }) => throw UnsupportedError('Not used by source cache test.');

  @override
  Future<PluginContentDetail> getDetail({
    required String pluginId,
    required String id,
  }) => throw UnsupportedError('Not used by source cache test.');

  @override
  Future<PluginChaptersResult> getChapters({
    required String pluginId,
    required String id,
    String? cursor,
    int pageSize = 50,
  }) => throw UnsupportedError('Not used by source cache test.');

  @override
  Future<PluginChapterContent> getContent({
    required String pluginId,
    required String id,
    required String chapterId,
  }) => throw UnsupportedError('Not used by source cache test.');
}
