/// 发现页导航栈与请求世代测试。
///
/// 职责：
/// - 验证连续进入、逐级返回、失败重试和过期结果丢弃。
/// - 验证导航加载诊断不包含数据源 target 等内容标识。
///
/// 注意：
/// - 测试 gateway 仅产生受控不可变文档，不接入 Runtime。
///
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/features/discovery/application/discovery_page_controller.dart';
import 'package:mg_read/features/discovery/application/discovery_page_state.dart';
import 'package:mg_read/features/discovery/application/discovery_source_selection_store.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import '../../../core/diagnostics/diagnostics_testkit.dart';

void main() {
  test('restores a persisted discovery source when it remains available', () async {
    final gateway = _TreeGateway();
    final sourceSelection = _MemoryDiscoverySourceSelectionStore(_TreeGateway.alternatePluginId);
    final container = ProviderContainer(
      overrides: [
        sourceContentGatewayProvider.overrideWithValue(gateway),
        discoverySourceSelectionStoreProvider.overrideWithValue(sourceSelection),
      ],
    );
    addTearDown(container.dispose);
    final listener = container.listen<DiscoveryPageState>(discoveryPageControllerProvider, (_, _) {}, fireImmediately: true);
    addTearDown(listener.close);

    await _waitUntil(() => container.read(discoveryPageControllerProvider).status == DiscoveryPageStatus.loaded);

    final state = container.read(discoveryPageControllerProvider);
    expect(state.selectedSourceId, _TreeGateway.alternatePluginId);
    expect(gateway.documentPluginIds, <String>[_TreeGateway.alternatePluginId]);
  });

  test('stores a valid source selection before loading its document', () async {
    final sourceSelection = _MemoryDiscoverySourceSelectionStore(null);
    final container = ProviderContainer(
      overrides: [
        sourceContentGatewayProvider.overrideWithValue(_TreeGateway()),
        discoverySourceSelectionStoreProvider.overrideWithValue(sourceSelection),
      ],
    );
    addTearDown(container.dispose);
    final listener = container.listen<DiscoveryPageState>(discoveryPageControllerProvider, (_, _) {}, fireImmediately: true);
    addTearDown(listener.close);
    await _waitUntil(() => container.read(discoveryPageControllerProvider).status == DiscoveryPageStatus.loaded);

    await container.read(discoveryPageControllerProvider.notifier).selectSource(_TreeGateway.alternatePluginId);

    expect(sourceSelection.selectedSourceId, _TreeGateway.alternatePluginId);
  });

  test('retains the first loaded document after discovery stops listening', () async {
    final gateway = _TreeGateway();
    final container = ProviderContainer(
      overrides: [
        sourceContentGatewayProvider.overrideWithValue(gateway),
        discoverySourceSelectionStoreProvider.overrideWithValue(_MemoryDiscoverySourceSelectionStore(null)),
      ],
    );
    addTearDown(container.dispose);

    final firstListener = container.listen<DiscoveryPageState>(discoveryPageControllerProvider, (_, _) {}, fireImmediately: true);
    await _waitUntil(() => container.read(discoveryPageControllerProvider).status == DiscoveryPageStatus.loaded);
    firstListener.close();
    await Future<void>.delayed(Duration.zero);

    final secondListener = container.listen<DiscoveryPageState>(discoveryPageControllerProvider, (_, _) {}, fireImmediately: true);
    addTearDown(secondListener.close);

    final state = container.read(discoveryPageControllerProvider);
    expect(state.status, DiscoveryPageStatus.loaded);
    expect(_collection(state.result!).id, 'home-books');
    expect(gateway.documentRequestCount, 1);
  });

  test('keeps category documents on a stack and appends only its collection', () async {
    final container = ProviderContainer(
      overrides: [
        sourceContentGatewayProvider.overrideWithValue(_TreeGateway()),
        discoverySourceSelectionStoreProvider.overrideWithValue(_MemoryDiscoverySourceSelectionStore(null)),
      ],
    );
    addTearDown(container.dispose);
    final listener = container.listen<DiscoveryPageState>(discoveryPageControllerProvider, (_, _) {}, fireImmediately: true);
    addTearDown(listener.close);

    await _waitUntil(() => container.read(discoveryPageControllerProvider).status == DiscoveryPageStatus.loaded);
    final controller = container.read(discoveryPageControllerProvider.notifier);
    await controller.openCategory('category:fantasy');

    var state = container.read(discoveryPageControllerProvider);
    expect(state.canNavigateBack, isTrue);
    final collection = _collection(state.result!);
    expect(collection.items, hasLength(1));

    await controller.loadMore(collection);
    state = container.read(discoveryPageControllerProvider);
    expect(_collection(state.result!).items.map((item) => item.content.id), <String>['fantasy:1', 'fantasy:2']);

    controller.goBack();
    state = container.read(discoveryPageControllerProvider);
    expect(state.canNavigateBack, isFalse);
    expect(_collection(state.result!).id, 'home-books');
  });

  test('returns to the parent while discarding a pending category request', () async {
    final diagnostics = DiagnosticsTestkit();
    addTearDown(diagnostics.dispose);
    final gateway = _TreeGateway()..categoryGate = Completer<void>();
    final container = ProviderContainer(
      overrides: [
        sourceContentGatewayProvider.overrideWithValue(gateway),
        discoverySourceSelectionStoreProvider.overrideWithValue(_MemoryDiscoverySourceSelectionStore(null)),
        diagnosticsManagerProvider.overrideWithValue(diagnostics.manager),
      ],
    );
    addTearDown(container.dispose);
    final listener = container.listen<DiscoveryPageState>(discoveryPageControllerProvider, (_, _) {}, fireImmediately: true);
    addTearDown(listener.close);

    await _waitUntil(() => container.read(discoveryPageControllerProvider).status == DiscoveryPageStatus.loaded);
    final controller = container.read(discoveryPageControllerProvider.notifier);
    final pending = controller.openCategory('category:fantasy');
    await _waitUntil(() => container.read(discoveryPageControllerProvider).status == DiscoveryPageStatus.loadingContent);

    var state = container.read(discoveryPageControllerProvider);
    expect(state.canNavigateBack, isTrue);
    expect(_collection(state.previousResult!).id, 'home-books');
    controller.goBack();
    state = container.read(discoveryPageControllerProvider);
    expect(state.status, DiscoveryPageStatus.loaded);
    expect(state.canNavigateBack, isFalse);
    expect(_collection(state.result!).id, 'home-books');
    expect(diagnostics.sink.events.map((event) => event.eventName), contains('discovery.navigation.cancelled'));

    gateway.categoryGate!.complete();
    await pending;
    state = container.read(discoveryPageControllerProvider);
    expect(_collection(state.result!).id, 'home-books');
  });

  test('supports two nested pages and returns one level at a time', () async {
    final container = _container(_TreeGateway());
    addTearDown(container.dispose);
    final listener = container.listen<DiscoveryPageState>(discoveryPageControllerProvider, (_, _) {}, fireImmediately: true);
    addTearDown(listener.close);
    await _waitUntil(() => _isLoaded(container));

    final controller = container.read(discoveryPageControllerProvider.notifier);
    await controller.openCategory('category:fantasy');
    await controller.openCategory('category:fantasy');
    var state = container.read(discoveryPageControllerProvider);
    expect(state.navigationDepth, 2);
    expect(state.retainedParents.map(_collection).map((collection) => collection.id), <String>['home-books', 'fantasy-books']);

    controller.goBack();
    state = container.read(discoveryPageControllerProvider);
    expect(state.navigationDepth, 1);
    expect(state.canNavigateBack, isTrue);
    expect(state.retainedParents.map(_collection).map((collection) => collection.id), <String>['home-books']);
    controller.goBack();
    expect(container.read(discoveryPageControllerProvider).navigationDepth, 0);
    expect(container.read(discoveryPageControllerProvider).canNavigateBack, isFalse);
  });

  test('keeps the child page for failure retry and emits a safe terminal span', () async {
    final diagnostics = DiagnosticsTestkit();
    addTearDown(diagnostics.dispose);
    final gateway = _TreeGateway()..failFirstBrokenCategory = true;
    final container = _container(gateway, diagnostics: diagnostics);
    addTearDown(container.dispose);
    final listener = container.listen<DiscoveryPageState>(discoveryPageControllerProvider, (_, _) {}, fireImmediately: true);
    addTearDown(listener.close);
    await _waitUntil(() => _isLoaded(container));

    final controller = container.read(discoveryPageControllerProvider.notifier);
    await controller.openCategory('category:broken');
    var state = container.read(discoveryPageControllerProvider);
    expect(state.status, DiscoveryPageStatus.failure);
    expect(state.canNavigateBack, isTrue);
    expect(state.navigationDepth, 1);

    controller.goBack();
    state = container.read(discoveryPageControllerProvider);
    expect(state.status, DiscoveryPageStatus.loaded);
    expect(state.navigationDepth, 0);
    expect(_collection(state.result!).id, 'home-books');

    gateway.failFirstBrokenCategory = true;
    await controller.openCategory('category:broken');
    expect(container.read(discoveryPageControllerProvider).status, DiscoveryPageStatus.failure);
    await controller.retry();
    state = container.read(discoveryPageControllerProvider);
    expect(state.status, DiscoveryPageStatus.loaded);
    expect(state.navigationDepth, 1);

    final navigationEvents = diagnostics.sink.events
        .where((event) => event.eventName.startsWith('discovery.navigation'))
        .toList(growable: false);
    expect(
      navigationEvents.map((event) => event.eventName),
      containsAll(<String>['discovery.navigation.start', 'discovery.navigation.error', 'discovery.navigation.complete']),
    );
    for (final event in navigationEvents) {
      expect(event.attributes.values.keys, isNot(contains('target')));
      expect(event.attributes.values.keys, isNot(contains('sourceName')));
    }
  });

  test('current development source update returns discovery to its root', () async {
    final changes = StreamController<DevelopmentPluginChangeBatch>.broadcast();
    addTearDown(changes.close);
    final gateway = _TreeGateway();
    final container = ProviderContainer(
      overrides: [
        sourceContentGatewayProvider.overrideWithValue(gateway),
        discoverySourceSelectionStoreProvider.overrideWithValue(_MemoryDiscoverySourceSelectionStore(null)),
        pluginRuntimeDevelopmentChangesProvider.overrideWith((ref) => changes.stream),
      ],
    );
    addTearDown(container.dispose);
    final listener = container.listen<DiscoveryPageState>(discoveryPageControllerProvider, (_, _) {}, fireImmediately: true);
    addTearDown(listener.close);
    await _waitUntil(() => _isLoaded(container));
    await container.read(discoveryPageControllerProvider.notifier).openCategory('category:fantasy');

    changes.add(
      DevelopmentPluginChangeBatch(
        revision: 1,
        changes: const <DevelopmentPluginChange>[
          DevelopmentPluginChange(kind: DevelopmentPluginChangeKind.updated, pluginId: _TreeGateway._pluginId),
        ],
      ),
    );
    await _waitUntil(() => container.read(discoveryPageControllerProvider).navigationDepth == 0);

    expect(_collection(container.read(discoveryPageControllerProvider).result!).id, 'home-books');
    expect(gateway.documentRequestCount, 3);
  });

  test('unrelated development source update preserves the current document', () async {
    final changes = StreamController<DevelopmentPluginChangeBatch>.broadcast();
    addTearDown(changes.close);
    final gateway = _TreeGateway();
    final container = ProviderContainer(
      overrides: [
        sourceContentGatewayProvider.overrideWithValue(gateway),
        discoverySourceSelectionStoreProvider.overrideWithValue(_MemoryDiscoverySourceSelectionStore(null)),
        pluginRuntimeDevelopmentChangesProvider.overrideWith((ref) => changes.stream),
      ],
    );
    addTearDown(container.dispose);
    final listener = container.listen<DiscoveryPageState>(discoveryPageControllerProvider, (_, _) {}, fireImmediately: true);
    addTearDown(listener.close);
    await _waitUntil(() => _isLoaded(container));
    await container.read(discoveryPageControllerProvider.notifier).openCategory('category:fantasy');
    final requestCount = gateway.documentRequestCount;

    changes.add(
      DevelopmentPluginChangeBatch(
        revision: 2,
        changes: const <DevelopmentPluginChange>[
          DevelopmentPluginChange(kind: DevelopmentPluginChangeKind.updated, pluginId: _TreeGateway.alternatePluginId),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));

    final state = container.read(discoveryPageControllerProvider);
    expect(state.navigationDepth, 1);
    expect(_collection(state.result!).id, 'fantasy-books');
    expect(gateway.documentRequestCount, requestCount);
  });

  test('removed current development source falls back to an available source', () async {
    final changes = StreamController<DevelopmentPluginChangeBatch>.broadcast();
    addTearDown(changes.close);
    final gateway = _TreeGateway();
    final container = ProviderContainer(
      overrides: [
        sourceContentGatewayProvider.overrideWithValue(gateway),
        discoverySourceSelectionStoreProvider.overrideWithValue(_MemoryDiscoverySourceSelectionStore(null)),
        pluginRuntimeDevelopmentChangesProvider.overrideWith((ref) => changes.stream),
      ],
    );
    addTearDown(container.dispose);
    final listener = container.listen<DiscoveryPageState>(discoveryPageControllerProvider, (_, _) {}, fireImmediately: true);
    addTearDown(listener.close);
    await _waitUntil(() => _isLoaded(container));
    gateway.includePrimary = false;

    changes.add(
      DevelopmentPluginChangeBatch(
        revision: 3,
        changes: const <DevelopmentPluginChange>[
          DevelopmentPluginChange(kind: DevelopmentPluginChangeKind.removed, pluginId: _TreeGateway._pluginId),
        ],
      ),
    );
    await _waitUntil(() => container.read(discoveryPageControllerProvider).selectedSourceId == _TreeGateway.alternatePluginId);

    expect(container.read(discoveryPageControllerProvider).navigationDepth, 0);
    expect(gateway.documentPluginIds.last, _TreeGateway.alternatePluginId);
  });
}

ProviderContainer _container(_TreeGateway gateway, {DiagnosticsTestkit? diagnostics}) => ProviderContainer(
  overrides: [
    sourceContentGatewayProvider.overrideWithValue(gateway),
    discoverySourceSelectionStoreProvider.overrideWithValue(_MemoryDiscoverySourceSelectionStore(null)),
    if (diagnostics != null) diagnosticsManagerProvider.overrideWithValue(diagnostics.manager),
  ],
);

bool _isLoaded(ProviderContainer container) => container.read(discoveryPageControllerProvider).status == DiscoveryPageStatus.loaded;

Future<void> _waitUntil(bool Function() predicate) async {
  for (var attempt = 0; attempt < 20; attempt += 1) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('Discovery page controller did not resolve.');
}

PluginDiscoveryContentCollectionComponent _collection(PluginDiscoveryDocumentResult result) =>
    result.document.components.single as PluginDiscoveryContentCollectionComponent;

final class _TreeGateway implements SourceContentGateway {
  static const _pluginId = 'org.mgread.tree-test';
  static const alternatePluginId = 'org.mgread.alternate-tree-test';
  int documentRequestCount = 0;
  final List<String> documentPluginIds = <String>[];
  Completer<void>? categoryGate;
  bool failFirstBrokenCategory = false;
  bool includePrimary = true;

  @override
  Future<List<PluginSourceDescriptor>> listSources() async => <PluginSourceDescriptor>[
    if (includePrimary)
      PluginSourceDescriptor(id: _pluginId, displayName: '树测试数据源', contentKinds: const <PluginContentKind>[PluginContentKind.novel]),
    PluginSourceDescriptor(
      id: alternatePluginId,
      displayName: '备用树测试数据源',
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
        sourceName: '树测试数据源',
        collectionId: collectionId,
        continuation: null,
        items: <PluginDiscoveryContentItem>[_item('fantasy:2')],
      );
    }
    documentRequestCount++;
    if (target == 'category:broken' && failFirstBrokenCategory) {
      failFirstBrokenCategory = false;
      throw StateError('controlled discovery failure');
    }
    documentPluginIds.add(pluginId);
    final isCategory = target == 'category:fantasy';
    if (isCategory) {
      await categoryGate?.future;
    }
    return PluginDiscoveryDocumentResult(
      pluginId: pluginId,
      sourceName: '树测试数据源',
      document: PluginDiscoveryDocument(
        components: <PluginDiscoveryComponent>[
          PluginDiscoveryContentCollectionComponent(
            id: isCategory ? 'fantasy-books' : 'home-books',
            layout: PluginDiscoveryContentLayout.list,
            items: <PluginDiscoveryContentItem>[_item(isCategory ? 'fantasy:1' : 'home:1')],
            continuation: isCategory ? const PluginDiscoveryContinuation(target: 'category:fantasy', cursor: 'page:2') : null,
          ),
        ],
      ),
    );
  }

  @override
  Future<PluginSearchResult> search({required String pluginId, required String query, String? cursor, int pageSize = 20}) =>
      throw UnsupportedError('Not used by discovery tree test.');

  @override
  Future<PluginSearchSuggestionsResult> searchSuggestions({required String pluginId, String? cursor, int pageSize = 20}) =>
      throw UnsupportedError('Not used by discovery tree test.');

  @override
  Future<PluginContentDetail> getDetail({required String pluginId, required String id}) =>
      throw UnsupportedError('Not used by discovery tree test.');

  @override
  Future<PluginChaptersResult> getChapters({required String pluginId, required String id}) =>
      throw UnsupportedError('Not used by discovery tree test.');

  @override
  Future<PluginChapterContent> getContent({required String pluginId, required String id, required String chapterId}) =>
      throw UnsupportedError('Not used by discovery tree test.');
}

final class _MemoryDiscoverySourceSelectionStore implements DiscoverySourceSelectionStore {
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
