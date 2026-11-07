/// Cold-start intent, navigation revalidation and cancellation with gated sources.
/// No native Runtime, device or network is involved.
library;

import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/features/discovery/application/discovery_page_controller.dart';
import 'package:mg_read/features/discovery/application/discovery_page_state.dart';
import 'package:mg_read/features/discovery/application/discovery_source_selection_store.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/discovery/application/tv_discovery_navigation_snapshot.dart';
import 'package:mg_read/features/discovery/application/tv_discovery_session.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import '../../../support/tv_discovery_test_fixture.dart';

void main() {
  test('latest cached selection wins while sources and homepage are blocked; homepage never flashes', () async {
    final gateway = _Gateway()
      ..listGate = Completer<void>()
      ..homeGate = Completer<void>();
    final container = _container(gateway);
    final controller = container.read(discoveryPageControllerProvider.notifier);
    final results = <String?>[];
    container.listen(discoveryPageControllerProvider, (_, next) {
      if (next.result != null) results.add(next.target);
    });
    await controller.selectTvTab('today');
    await controller.selectTvTab('hot');
    expect(controller.tvPrimaryTarget, 'hot');
    gateway.listGate!.complete();
    await _wait(() => gateway.requests.contains('sakura/home'));
    await controller.selectTvTab('new');
    gateway.homeGate!.complete();
    await _wait(() => container.read(discoveryPageControllerProvider).result != null);
    expect(container.read(discoveryPageControllerProvider).target, 'new');
    expect(results, isNot(contains(null)));
  });

  test('same navigation and plugin version change retain selection, filters and content identity', () async {
    final gateway = _Gateway();
    final container = _container(gateway);
    final controller = container.read(discoveryPageControllerProvider.notifier);
    await _wait(() => container.read(discoveryPageControllerProvider).result != null);
    await controller.selectTvTab('hot');
    await controller.selectTvFilter('hot:filter');
    final result = container.read(discoveryPageControllerProvider).result;
    final snapshot = controller.tvNavigationSnapshot;
    final before = gateway.requests.where((key) => key == 'sakura/hot:filter').length;
    gateway.version = '2';
    container.read(pluginRuntimeCatalogChangeProvider.notifier).publish(pluginIds: ['sakura']);
    await _wait(() => controller.tvNavigationSnapshot?.pluginVersion == '2');
    expect(controller.tvNavigationSnapshot!.sameNavigation(snapshot!), isTrue);
    expect(controller.tvPrimaryTarget, 'hot');
    expect(container.read(discoveryPageControllerProvider).target, 'hot:filter');
    expect(container.read(discoveryPageControllerProvider).result, same(result));
    expect(gateway.requests.where((key) => key == 'sakura/hot:filter'), hasLength(before));
  });

  test('rename and reorder retain active content; removing the active target falls back once', () async {
    final gateway = _Gateway();
    final container = _container(gateway);
    final controller = container.read(discoveryPageControllerProvider.notifier);
    await _wait(() => container.read(discoveryPageControllerProvider).result != null);
    await controller.selectTvTab('hot');
    final result = container.read(discoveryPageControllerProvider).result;
    gateway.tabs = {'new': '新片', 'hot': '热门排行', 'today': '今日更新'};
    container.read(pluginRuntimeCatalogChangeProvider.notifier).publish(pluginIds: ['sakura']);
    await _wait(() => controller.tvNavigationSnapshot!.tabs[1].target == 'new');
    expect(controller.tvPrimaryTarget, 'hot');
    expect(container.read(discoveryPageControllerProvider).result, same(result));
    gateway.tabs = {'today': '今日更新'};
    container.read(pluginRuntimeCatalogChangeProvider.notifier).publish(pluginIds: ['sakura']);
    await _wait(() => controller.tvNavigationNotice == 1);
    expect(controller.tvPrimaryTarget, isNull);
    expect(container.read(discoveryPageControllerProvider).target, isNull);
    expect(controller.tvNavigationSnapshot!.tabs.map((tab) => tab.target), [null, 'today']);
  });

  test('failed home retains cached selection and retry loads it automatically', () async {
    final gateway = _Gateway()..failHome = true;
    final container = _container(gateway);
    final controller = container.read(discoveryPageControllerProvider.notifier);
    await controller.selectTvTab('hot');
    await _wait(() => container.read(discoveryPageControllerProvider).status == DiscoveryPageStatus.failure);
    expect(controller.tvNavigationSnapshot!.contains('hot'), isTrue);
    gateway.failHome = false;
    await controller.retry();
    expect(container.read(discoveryPageControllerProvider).target, 'hot');
    expect(container.read(discoveryPageControllerProvider).result, isNotNull);
  });

  test('selection while an updated catalog is blocked does not cancel its home validation', () async {
    final gateway = _Gateway();
    final container = _container(gateway);
    final controller = container.read(discoveryPageControllerProvider.notifier);
    await _wait(() => container.read(discoveryPageControllerProvider).result != null);
    await controller.selectTvTab('hot');
    gateway.listGate = Completer<void>();
    container.read(pluginRuntimeCatalogChangeProvider.notifier).publish(pluginIds: ['sakura']);
    await Future<void>.delayed(Duration.zero);
    await controller.selectTvTab('new');
    gateway.listGate!.complete();
    await _wait(
      () =>
          container.read(discoveryPageControllerProvider).target == 'new' && container.read(discoveryPageControllerProvider).result != null,
    );
    expect(controller.tvPrimaryTarget, 'new');
  });

  test('disabling TV during validation starts a normal homepage and rejects the old home', () async {
    final gateway = _Gateway()..homeGate = Completer<void>();
    final container = _container(gateway);
    final controller = container.read(discoveryPageControllerProvider.notifier);
    await _wait(() => gateway.requests.contains('sakura/home'));
    final old = gateway.homeGate!;
    gateway.homeGate = null;
    controller.configureTvMode(false);
    await _wait(() => container.read(discoveryPageControllerProvider).result != null);
    final result = container.read(discoveryPageControllerProvider).result;
    old.complete();
    await Future<void>.delayed(Duration.zero);
    expect(controller.tvNavigation, isNull);
    expect(container.read(discoveryPageControllerProvider).result, same(result));
  });

  test('disabled or removed source discards its snapshot and uses the available fallback', () async {
    final gateway = _Gateway()..ids = ['other'];
    final container = _container(gateway);
    final controller = container.read(discoveryPageControllerProvider.notifier);
    await controller.selectTvTab('hot');
    await _wait(() => container.read(discoveryPageControllerProvider).result != null);
    expect(container.read(discoveryPageControllerProvider).selectedSourceId, 'other');
    expect(controller.tvNavigationSnapshot!.sourceId, 'other');
    expect(controller.tvPrimaryTarget, isNull);
    gateway.ids = [];
    container.read(pluginRuntimeCatalogChangeProvider.notifier).publish(pluginIds: ['other']);
    await _wait(() => container.read(discoveryPageControllerProvider).status == DiscoveryPageStatus.noSources);
    expect(controller.tvNavigationSnapshot, isNull);
  });

  test('switching sources cancels home validation and ignores late results', () async {
    final gateway = _Gateway()..homeGate = Completer<void>();
    final container = _container(gateway);
    final controller = container.read(discoveryPageControllerProvider.notifier);
    await _wait(() => gateway.requests.contains('sakura/home'));
    await controller.selectTvTab('hot');
    final old = gateway.homeGate!;
    gateway.homeGate = null;
    await controller.selectSource('other');
    old.complete();
    await Future<void>.delayed(Duration.zero);
    expect(controller.tvNavigationSnapshot!.sourceId, 'other');
    expect(container.read(discoveryPageControllerProvider).selectedSourceId, 'other');
    expect(gateway.cancellations.first.isCancelled, isTrue);
  });

  test('leaving during startup clears intent; a late home cannot open that category', () async {
    final gateway = _Gateway()..homeGate = Completer<void>();
    final container = _container(gateway);
    final controller = container.read(discoveryPageControllerProvider.notifier);
    await _wait(() => gateway.requests.contains('sakura/home'));
    await controller.selectTvTab('hot');
    controller.cancelPendingTvSelection();
    gateway.homeGate!.complete();
    await _wait(() => container.read(discoveryPageControllerProvider).result != null);
    expect(container.read(discoveryPageControllerProvider).target, isNull);
  });
}

ProviderContainer _container(_Gateway gateway) {
  final container = ProviderContainer(
    overrides: [
      sourceContentGatewayProvider.overrideWithValue(gateway),
      discoverySourceSelectionStoreProvider.overrideWithValue(TvDiscoveryTestSelection()),
    ],
  );
  addTearDown(container.dispose);
  container.listen(discoveryPageControllerProvider, (_, _) {});
  container.read(discoveryPageControllerProvider.notifier)
    ..restoreTvNavigation(
      TvDiscoveryNavigationSnapshot(sourceId: 'sakura', pluginVersion: '1', tabs: TvDiscoveryNavigation(tvDiscoveryDocument()).tabs),
    )
    ..configureTvMode(true);
  return container;
}

class _Gateway extends TvDiscoveryTestGateway {
  Completer<void>? listGate;
  bool failHome = false;
  String version = '1';
  List<String> ids = ['sakura', 'other'];
  Map<String, String> tabs = {'today': '今日更新', 'hot': '热榜', 'week': '本周追番', 'new': '新片上线'};

  @override
  Future<List<PluginSourceDescriptor>> listSources() async {
    await listGate?.future;
    return [
      for (final id in ids)
        PluginSourceDescriptor(id: id, displayName: id, pluginVersion: version, contentKinds: const [PluginContentKind.video]),
    ];
  }

  @override
  Future<PluginDiscoverResult> discover({
    required String pluginId,
    String? target,
    String? cursor,
    String? collectionId,
    int pageSize = 20,
  }) async {
    requests.add('$pluginId/${target ?? 'home'}');
    if (target != null) return tvDiscoveryDocument(pluginId: pluginId, target: target);
    final entries = Map.of(tabs);
    await homeGate?.future;
    if (failHome) throw StateError('offline');
    final home = tvDiscoveryDocument(pluginId: pluginId);
    return PluginDiscoveryDocumentResult(
      pluginId: pluginId,
      sourceName: home.sourceName,
      document: PluginDiscoveryDocument(
        components: [
          home.document.components.first,
          PluginDiscoveryTabsComponent(
            id: 'tabs',
            selectedTabId: 'today',
            tabs: [for (final tab in entries.entries) PluginDiscoveryTab(id: tab.key, label: tab.value, target: tab.key)],
          ),
        ],
      ),
    );
  }
}

Future<void> _wait(bool Function() condition) async {
  for (var i = 0; i < 200; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  fail('Expected TV startup state did not arrive.');
}
