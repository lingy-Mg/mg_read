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

  test('preload is bounded to two requests and a focused queued tab gains priority without duplication', () async {
    final gateway = TvDiscoveryTestGateway();
    final session = TvDiscoverySession(home: tvDiscoveryDocument(), gateway: gateway)..prefetch();
    addTearDown(session.dispose);
    expect(gateway.requests, ['sakura/today', 'sakura/hot']);
    final foreground = session.load('new');
    gateway.complete('today');
    await _wait(() => gateway.requests.length == 3);
    expect(gateway.requests.last, 'sakura/new');
    gateway.complete('new');
    await foreground;
    await _wait(() => gateway.requests.length == 4);
    gateway.complete('hot');
    gateway.complete('week');
    await _wait(() => gateway.active == 0);
    expect(gateway.maxActive, 2);
    expect(session.read('week'), isNotNull);
    await session.load('new');
    expect(gateway.requests, hasLength(4));
  });

  test('disposing cancels preload tokens and late results cannot refill the session', () async {
    final gateway = TvDiscoveryTestGateway();
    final session = TvDiscoverySession(home: tvDiscoveryDocument(), gateway: gateway)..prefetch();
    session.dispose();
    expect(gateway.cancellations.every((token) => token.isCancelled), isTrue);
    gateway.complete('today');
    gateway.complete('hot');
    await _wait(() => gateway.active == 0);
    expect(session.read('today'), isNull);
    expect(gateway.requests, hasLength(2));
  });

  test('failed background loads remain retryable when selected', () async {
    final gateway = TvDiscoveryTestGateway();
    final session = TvDiscoverySession(home: tvDiscoveryDocument(), gateway: gateway)..prefetch();
    addTearDown(session.dispose);
    gateway.gates['sakura/today']!.completeError(StateError('offline'));
    await _wait(() => gateway.requests.contains('sakura/week'));
    gateway.autoComplete = true;
    gateway.complete('hot');
    gateway.complete('week');
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
    expect(oldTokens, hasLength(2));
    final pending = controller.selectTvTab('today');
    await controller.selectSource('other');
    expect(oldTokens.every((token) => token.isCancelled), isTrue);
    gateway.complete('today');
    gateway.complete('hot');
    await pending;
    expect(container.read(discoveryPageControllerProvider).selectedSourceId, 'other');
    expect(controller.tvNavigation!.home.sourceName, '备用动漫');
    gateway.autoComplete = true;
    gateway.complete('today', source: 'other');
    gateway.complete('hot', source: 'other');
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
