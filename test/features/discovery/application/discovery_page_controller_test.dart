import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/features/discovery/application/discovery_page_controller.dart';
import 'package:mg_read/features/discovery/application/discovery_page_state.dart';
import 'package:mg_read/features/discovery/application/discovery_source_selection_store.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

void main() {
  test(
    'restores a persisted discovery source when it remains available',
    () async {
      final gateway = _TreeGateway();
      final sourceSelection = _MemoryDiscoverySourceSelectionStore(
        _TreeGateway.alternatePluginId,
      );
      final container = ProviderContainer(
        overrides: [
          sourceContentGatewayProvider.overrideWithValue(gateway),
          discoverySourceSelectionStoreProvider.overrideWithValue(
            sourceSelection,
          ),
        ],
      );
      addTearDown(container.dispose);
      final listener = container.listen<DiscoveryPageState>(
        discoveryPageControllerProvider,
        (_, _) {},
        fireImmediately: true,
      );
      addTearDown(listener.close);

      await _waitUntil(
        () =>
            container.read(discoveryPageControllerProvider).status ==
            DiscoveryPageStatus.loaded,
      );

      final state = container.read(discoveryPageControllerProvider);
      expect(state.selectedSourceId, _TreeGateway.alternatePluginId);
      expect(gateway.documentPluginIds, <String>[
        _TreeGateway.alternatePluginId,
      ]);
    },
  );

  test('stores a valid source selection before loading its document', () async {
    final sourceSelection = _MemoryDiscoverySourceSelectionStore(null);
    final container = ProviderContainer(
      overrides: [
        sourceContentGatewayProvider.overrideWithValue(_TreeGateway()),
        discoverySourceSelectionStoreProvider.overrideWithValue(
          sourceSelection,
        ),
      ],
    );
    addTearDown(container.dispose);
    final listener = container.listen<DiscoveryPageState>(
      discoveryPageControllerProvider,
      (_, _) {},
      fireImmediately: true,
    );
    addTearDown(listener.close);
    await _waitUntil(
      () =>
          container.read(discoveryPageControllerProvider).status ==
          DiscoveryPageStatus.loaded,
    );

    await container
        .read(discoveryPageControllerProvider.notifier)
        .selectSource(_TreeGateway.alternatePluginId);

    expect(sourceSelection.selectedSourceId, _TreeGateway.alternatePluginId);
  });

  test(
    'retains the first loaded document after discovery stops listening',
    () async {
      final gateway = _TreeGateway();
      final container = ProviderContainer(
        overrides: [
          sourceContentGatewayProvider.overrideWithValue(gateway),
          discoverySourceSelectionStoreProvider.overrideWithValue(
            _MemoryDiscoverySourceSelectionStore(null),
          ),
        ],
      );
      addTearDown(container.dispose);

      final firstListener = container.listen<DiscoveryPageState>(
        discoveryPageControllerProvider,
        (_, _) {},
        fireImmediately: true,
      );
      await _waitUntil(
        () =>
            container.read(discoveryPageControllerProvider).status ==
            DiscoveryPageStatus.loaded,
      );
      firstListener.close();
      await Future<void>.delayed(Duration.zero);

      final secondListener = container.listen<DiscoveryPageState>(
        discoveryPageControllerProvider,
        (_, _) {},
        fireImmediately: true,
      );
      addTearDown(secondListener.close);

      final state = container.read(discoveryPageControllerProvider);
      expect(state.status, DiscoveryPageStatus.loaded);
      expect(_collection(state.result!).id, 'home-books');
      expect(gateway.documentRequestCount, 1);
    },
  );

  test(
    'keeps category documents on a stack and appends only its collection',
    () async {
      final container = ProviderContainer(
        overrides: [
          sourceContentGatewayProvider.overrideWithValue(_TreeGateway()),
          discoverySourceSelectionStoreProvider.overrideWithValue(
            _MemoryDiscoverySourceSelectionStore(null),
          ),
        ],
      );
      addTearDown(container.dispose);
      final listener = container.listen<DiscoveryPageState>(
        discoveryPageControllerProvider,
        (_, _) {},
        fireImmediately: true,
      );
      addTearDown(listener.close);

      await _waitUntil(
        () =>
            container.read(discoveryPageControllerProvider).status ==
            DiscoveryPageStatus.loaded,
      );
      final controller = container.read(
        discoveryPageControllerProvider.notifier,
      );
      await controller.openCategory('category:fantasy');

      var state = container.read(discoveryPageControllerProvider);
      expect(state.canNavigateBack, isTrue);
      final collection = _collection(state.result!);
      expect(collection.items, hasLength(1));

      await controller.loadMore(collection);
      state = container.read(discoveryPageControllerProvider);
      expect(
        _collection(state.result!).items.map((item) => item.content.id),
        <String>['fantasy:1', 'fantasy:2'],
      );

      controller.goBack();
      state = container.read(discoveryPageControllerProvider);
      expect(state.canNavigateBack, isFalse);
      expect(_collection(state.result!).id, 'home-books');
    },
  );
}

Future<void> _waitUntil(bool Function() predicate) async {
  for (var attempt = 0; attempt < 20; attempt += 1) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('Discovery page controller did not resolve.');
}

PluginDiscoveryContentCollectionComponent _collection(
  PluginDiscoveryDocumentResult result,
) =>
    result.document.components.single
        as PluginDiscoveryContentCollectionComponent;

final class _TreeGateway implements SourceContentGateway {
  static const _pluginId = 'org.mgread.tree-test';
  static const alternatePluginId = 'org.mgread.alternate-tree-test';
  int documentRequestCount = 0;
  final List<String> documentPluginIds = <String>[];

  @override
  Future<List<PluginSourceDescriptor>> listSources() async =>
      <PluginSourceDescriptor>[
        PluginSourceDescriptor(
          id: _pluginId,
          displayName: '树测试书源',
          contentKinds: const <PluginContentKind>[PluginContentKind.novel],
        ),
        PluginSourceDescriptor(
          id: alternatePluginId,
          displayName: '备用树测试书源',
          contentKinds: const <PluginContentKind>[PluginContentKind.novel],
        ),
      ];

  @override
  Future<PluginDiscoverResult> discover({
    required String pluginId,
    String? target,
    String? cursor,
    String? collectionId,
    int pageSize = 20,
  }) async {
    if (collectionId != null) {
      expect(collectionId, 'fantasy-books');
      expect(target, 'category:fantasy');
      expect(cursor, 'page:2');
      return PluginDiscoveryAppendResult(
        pluginId: pluginId,
        sourceName: '树测试书源',
        collectionId: collectionId,
        continuation: null,
        items: <PluginDiscoveryContentItem>[_item('fantasy:2')],
      );
    }
    documentRequestCount++;
    documentPluginIds.add(pluginId);
    final isCategory = target == 'category:fantasy';
    return PluginDiscoveryDocumentResult(
      pluginId: pluginId,
      sourceName: '树测试书源',
      document: PluginDiscoveryDocument(
        components: <PluginDiscoveryComponent>[
          PluginDiscoveryContentCollectionComponent(
            id: isCategory ? 'fantasy-books' : 'home-books',
            layout: PluginDiscoveryContentLayout.list,
            items: <PluginDiscoveryContentItem>[
              _item(isCategory ? 'fantasy:1' : 'home:1'),
            ],
            continuation: isCategory
                ? const PluginDiscoveryContinuation(
                    target: 'category:fantasy',
                    cursor: 'page:2',
                  )
                : null,
          ),
        ],
      ),
    );
  }

  @override
  Future<PluginSearchResult> search({
    required String pluginId,
    required String query,
    String? cursor,
    int pageSize = 20,
  }) => throw UnsupportedError('Not used by discovery tree test.');

  @override
  Future<PluginSearchSuggestionsResult> searchSuggestions({
    required String pluginId,
    String? cursor,
    int pageSize = 20,
  }) => throw UnsupportedError('Not used by discovery tree test.');

  @override
  Future<PluginContentDetail> getDetail({
    required String pluginId,
    required String id,
  }) => throw UnsupportedError('Not used by discovery tree test.');

  @override
  Future<PluginChaptersResult> getChapters({
    required String pluginId,
    required String id,
  }) => throw UnsupportedError('Not used by discovery tree test.');

  @override
  Future<PluginChapterContent> getContent({
    required String pluginId,
    required String id,
    required String chapterId,
  }) => throw UnsupportedError('Not used by discovery tree test.');
}

final class _MemoryDiscoverySourceSelectionStore
    implements DiscoverySourceSelectionStore {
  _MemoryDiscoverySourceSelectionStore(this.selectedSourceId);

  String? selectedSourceId;

  @override
  Future<String?> load() async => selectedSourceId;

  @override
  Future<void> save(String sourceId) async {
    selectedSourceId = sourceId;
  }
}

PluginDiscoveryContentItem _item(String id) => PluginDiscoveryContentItem(
  content: PluginContentSummary(
    id: id,
    title: id,
    contentKind: PluginContentKind.novel,
    author: null,
    url: null,
    coverUrl: null,
    description: null,
    language: null,
    status: PluginContentStatus.unknown,
    access: PluginAccessKind.unknown,
    wordCount: null,
    chapterCount: null,
    publishedAt: null,
    updatedAt: null,
    latestChapter: null,
    categories: const <String>[],
    tags: const <String>[],
    attributes: const <PluginContentAttribute>[],
  ),
  rank: null,
  metric: null,
  recommendation: null,
);
