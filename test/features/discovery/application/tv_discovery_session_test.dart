/// TV first-page warming, request priority and controller navigation acceptance.
library;

import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/features/discovery/application/discovery_page_controller.dart';
import 'package:mg_read/features/discovery/application/discovery_page_state.dart';
import 'package:mg_read/features/discovery/application/discovery_source_selection_store.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/discovery/application/tv_discovery_session.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import '../../../support/tv_discovery_test_fixture.dart';

void main() {
  test('source homepage retains all content and promotes distinct targets from nested navigation', () {
    final home = tvDiscoveryDocument();
    final navigation = TvDiscoveryNavigation(home);
    expect(navigation.tabs.map((tab) => tab.label), ['樱花动漫', '今日更新', '热榜', '本周追番', '新片上线']);
    expect(navigation.homeContent, hasLength(1));
    final section = navigation.homeContent.single as PluginDiscoverySectionComponent;
    expect((section.children.single as PluginDiscoveryContentCollectionComponent).items, hasLength(15));
    expect(home.document.components, hasLength(3));
  });

  test('four preloads leave a foreground slot and a queued selection shares its request', () async {
    final gateway = TvDiscoveryTestGateway();
    final home = PluginDiscoveryDocumentResult(
      pluginId: 'sakura',
      sourceName: '樱花动漫',
      document: PluginDiscoveryDocument(
        components: [
          PluginDiscoveryTabsComponent(
            id: 'tabs',
            selectedTabId: 'today',
            tabs: [
              for (final target in ['today', 'hot', 'week', 'new', 'queued', 'focused'])
                PluginDiscoveryTab(id: target, label: target, target: target),
            ],
          ),
        ],
      ),
    );
    final session = TvDiscoverySession(home: home, gateway: gateway)..prefetch();
    addTearDown(session.dispose);
    expect(gateway.requests, ['sakura/today', 'sakura/hot', 'sakura/week', 'sakura/new']);
    final foreground = session.load('focused');
    final shared = session.load('focused');
    expect(shared, same(foreground));
    expect(gateway.requests.last, 'sakura/focused', reason: 'selection starts even while every background slot is busy');
    expect(gateway.requests, hasLength(5));
    gateway.complete('focused');
    await foreground;
    gateway.complete('today');
    await _wait(() => gateway.requests.length == 6);
    expect(gateway.requests.last, 'sakura/queued');
    gateway.complete('new');
    gateway.complete('hot');
    gateway.complete('week');
    gateway.complete('queued');
    await _wait(() => gateway.active == 0);
    expect(gateway.maxActive, 5);
    expect(session.read('week'), isNotNull);
    await session.load('focused');
    expect(gateway.requests, hasLength(6));
  });

  test('nested filters warm every group fairly within one bounded speculative hop', () async {
    final gateway = TvDiscoveryTestGateway()..autoComplete = true;
    final session = TvDiscoverySession(home: tvDiscoveryDocument(), gateway: gateway);
    addTearDown(session.dispose);
    final library = tvDiscoveryDocument(target: 'library');
    session.prefetchFilters(
      PluginDiscoveryDocumentResult(
        pluginId: library.pluginId,
        sourceName: library.sourceName,
        document: PluginDiscoveryDocument(
          components: [
            PluginDiscoveryGroupComponent(id: 'nested', layout: PluginDiscoveryGroupLayout.vertical, children: library.document.components),
          ],
        ),
      ),
    );
    await _wait(() => gateway.requests.length == 32 && session.read('library:hits') != null);
    expect(gateway.requests, hasLength(32));
    expect(gateway.requests.toSet(), hasLength(32));
    for (final target in ['library:jp', 'library:comedy', 'library:area-jp', 'library:2026', 'library:A', 'library:hits']) {
      expect(session.read(target), isNotNull, reason: 'each group gets a turn before the long genre list');
    }
    expect(gateway.maxActive, lessThanOrEqualTo(4));
    expect(
      gateway.requests.any((target) => target.contains('comedy:')),
      isFalse,
      reason: 'speculative pages do not expand more combinations',
    );
  });

  test('a warmed secondary filter switches immediately without a loading snapshot or duplicate request', () async {
    final gateway = TvDiscoveryTestGateway()
      ..autoComplete = true
      ..includeLibrary = true;
    final container = _container(gateway);
    addTearDown(container.dispose);
    await _wait(() => container.read(discoveryPageControllerProvider).result != null);
    final controller = container.read(discoveryPageControllerProvider.notifier)..configureTvMode(true);
    await _wait(() => gateway.requests.contains('sakura/library:hits'));
    await Future<void>.delayed(Duration.zero);
    await controller.selectTvTab('library');
    final states = <DiscoveryPageStatus>[];
    container.listen(discoveryPageControllerProvider, (_, next) => states.add(next.status));
    final before = gateway.requests.where((key) => key == 'sakura/library:2026').length;
    final selected = controller.selectTvFilter('library:2026');
    expect(container.read(discoveryPageControllerProvider).target, 'library:2026');
    expect(container.read(discoveryPageControllerProvider).result, isNotNull);
    await selected;
    expect(states, isNot(contains(DiscoveryPageStatus.loadingContent)));
    expect(before, 1);
    expect(gateway.requests.where((key) => key == 'sakura/library:2026'), hasLength(before));
    await _wait(() => gateway.active == 0);
  });

  test('disposing cancels preload tokens and late results cannot refill the session', () async {
    final gateway = TvDiscoveryTestGateway();
    final session = TvDiscoverySession(home: tvDiscoveryDocument(), gateway: gateway)
      ..prefetch()
      ..prefetchTargets(['queued']);
    session.dispose();
    expect(gateway.cancellations.every((token) => token.isCancelled), isTrue);
    gateway.complete('today');
    gateway.complete('hot');
    gateway.complete('week');
    gateway.complete('new');
    await _wait(() => gateway.active == 0);
    expect(session.read('today'), isNull);
    expect(gateway.requests, hasLength(4));
  });

  test('failed background loads remain retryable when selected', () async {
    final gateway = TvDiscoveryTestGateway();
    final session = TvDiscoverySession(home: tvDiscoveryDocument(), gateway: gateway)..prefetch();
    addTearDown(session.dispose);
    gateway.gates['sakura/today']!.completeError(StateError('offline'));
    await Future<void>.delayed(Duration.zero);
    gateway.autoComplete = true;
    gateway.complete('hot');
    gateway.complete('week');
    gateway.complete('new');
    await _wait(() => gateway.active == 0);
    await session.load('today');
    expect(session.read('today'), isNotNull);
    expect(gateway.requests.where((key) => key == 'sakura/today'), hasLength(2));
  });

  test('rapid tab movement shares preloads and commits only the final focused tab at root depth', () async {
    final gateway = TvDiscoveryTestGateway();
    final container = _container(gateway);
    addTearDown(container.dispose);
    await _wait(() => container.read(discoveryPageControllerProvider).result != null);
    final controller = container.read(discoveryPageControllerProvider.notifier)..configureTvMode(true);
    final first = controller.selectTvTab('today');
    final last = controller.selectTvTab('hot');
    gateway.complete('hot');
    await last;
    gateway.complete('today');
    await first;
    var state = container.read(discoveryPageControllerProvider);
    expect(state.target, 'hot');
    expect(state.navigationDepth, 0);
    expect(state.canNavigateBack, isFalse);
    final before = gateway.requests.length;
    await controller.selectTvTab('today');
    await controller.selectTvTab(null);
    state = container.read(discoveryPageControllerProvider);
    expect(state.target, isNull);
    expect(state.result!.document.components.first.id, 'content-home');
    expect(gateway.requests, hasLength(before));
    gateway.autoComplete = true;
    gateway.complete('week');
    gateway.complete('new');
    await _wait(() => gateway.active == 0);
  });

  test('switching sources cancels old preloads and ignores their completion', () async {
    final gateway = TvDiscoveryTestGateway();
    final container = _container(gateway);
    addTearDown(container.dispose);
    await _wait(() => container.read(discoveryPageControllerProvider).result != null);
    final controller = container.read(discoveryPageControllerProvider.notifier)..configureTvMode(true);
    final oldTokens = List.of(gateway.cancellations.skip(1));
    expect(oldTokens, hasLength(4));
    final pending = controller.selectTvTab('today');
    await controller.selectSource('other');
    expect(oldTokens.every((token) => token.isCancelled), isTrue);
    gateway.complete('today');
    gateway.complete('hot');
    gateway.complete('week');
    gateway.complete('new');
    await pending;
    expect(container.read(discoveryPageControllerProvider).selectedSourceId, 'other');
    expect(controller.tvNavigation!.home.sourceName, '备用动漫');
    gateway.autoComplete = true;
    gateway.complete('today', source: 'other');
    gateway.complete('hot', source: 'other');
    gateway.complete('week', source: 'other');
    gateway.complete('new', source: 'other');
    await _wait(() => gateway.active == 0);
  });

  test('a failed focused category retries that category instead of refreshing the retained homepage', () async {
    final gateway = TvDiscoveryTestGateway();
    final container = _container(gateway);
    addTearDown(container.dispose);
    await _wait(() => container.read(discoveryPageControllerProvider).result != null);
    final controller = container.read(discoveryPageControllerProvider.notifier)..configureTvMode(true);
    final loading = controller.selectTvTab('today');
    gateway.gates['sakura/today']!.completeError(StateError('offline'));
    await loading;
    expect(container.read(discoveryPageControllerProvider).status, DiscoveryPageStatus.failure);
    expect(container.read(discoveryPageControllerProvider).target, 'today');
    gateway.autoComplete = true;
    final retry = controller.refresh();
    gateway.complete('hot');
    gateway.complete('week');
    await retry;
    expect(container.read(discoveryPageControllerProvider).status, DiscoveryPageStatus.loaded);
    expect(container.read(discoveryPageControllerProvider).target, 'today');
    expect(gateway.requests.where((key) => key == 'sakura/home'), hasLength(1));
  });

  test('TV reloads an evicted homepage and disabling TV rejects that request when it completes late', () async {
    final gateway = TvDiscoveryTestGateway()..autoComplete = true;
    final container = _container(gateway);
    addTearDown(container.dispose);
    await _wait(() => container.read(discoveryPageControllerProvider).result != null);
    final controller = container.read(discoveryPageControllerProvider.notifier);
    for (var i = 0; i < 10; i++) {
      await controller.selectTab('mobile-$i');
    }
    gateway.homeGate = Completer<void>();
    controller.configureTvMode(true);
    await _wait(() => gateway.requests.where((key) => key == 'sakura/home').length == 2);
    controller.configureTvMode(false);
    expect(gateway.cancellations.last.isCancelled, isTrue);
    gateway.homeGate!.complete();
    await Future<void>.delayed(Duration.zero);
    expect(container.read(discoveryPageControllerProvider).target, 'mobile-9');
    expect(controller.tvNavigation, isNull);
  });

  test('leaving TV mode restores the mobile document stack', () async {
    final gateway = TvDiscoveryTestGateway()..autoComplete = true;
    final container = _container(gateway);
    addTearDown(container.dispose);
    await _wait(() => container.read(discoveryPageControllerProvider).result != null);
    final controller = container.read(discoveryPageControllerProvider.notifier);
    await controller.openCategory('week');
    controller.configureTvMode(true);
    await _wait(() => gateway.active == 0);
    await controller.selectTvTab('hot');
    controller.configureTvMode(false);
    final state = container.read(discoveryPageControllerProvider);
    expect(controller.tvNavigation, isNull);
    expect(state.target, 'week');
    expect(state.navigationDepth, 1);
    controller.goBack();
    expect(container.read(discoveryPageControllerProvider).target, isNull);
  });
}

ProviderContainer _container(TvDiscoveryTestGateway gateway) {
  final container = ProviderContainer(
    overrides: [
      sourceContentGatewayProvider.overrideWithValue(gateway),
      discoverySourceSelectionStoreProvider.overrideWithValue(TvDiscoveryTestSelection()),
    ],
  );
  container.listen(discoveryPageControllerProvider, (_, _) {});
  return container;
}

Future<void> _wait(bool Function() done) async {
  for (var i = 0; i < 100; i++) {
    if (done()) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  fail('Controlled TV discovery work did not settle.');
}
