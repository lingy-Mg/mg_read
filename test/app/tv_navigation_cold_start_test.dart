/// Root-bridge cold start, stable remote focus/scroll and durable cache cleanup.
/// Gated fake sources ensure navigation never depends on Runtime readiness.
library;

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mg_read/app/app_startup.dart';
import 'package:mg_read/app/app_tv_source_navigation.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/discovery/application/discovery_page_controller.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/discovery/application/tv_discovery_navigation_snapshot.dart';
import 'package:mg_read/features/discovery/application/tv_discovery_navigation_store.dart';
import 'package:mg_read/features/discovery/application/tv_discovery_session.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';
import 'package:mg_read/shared/presentation/tv_source_navigation_scope.dart';
import 'package:mg_read/shared/presentation/widgets/tv_destination_action.dart';
import 'package:mg_read/shared/presentation/widgets/tv_focusable.dart';
import 'package:mg_read/shared/presentation/widgets/tv_top_navigation.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import '../core/diagnostics/diagnostics_testkit.dart';
import '../support/tv_discovery_test_fixture.dart';
import 'mg_read_app_test_support.dart';

void main() {
  testWidgets('cached categories are interactive before startup and unchanged validation retains focus and scroll', (tester) async {
    await tester.binding.setSurfaceSize(const Size(640, 360));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final gateway = _Gateway()
      ..listGate = Completer<void>()
      ..homeGate = Completer<void>();
    final harness = await _mount(tester, gateway, cached: true);
    expect(find.text('分类 0'), findsOneWidget);
    expect(gateway.listCalls, 0, reason: 'cached labels cannot start Runtime before the library frame');
    await _select(tester, 'tab-5');
    expect(harness.router.routeInformationProvider.value.uri.toString(), '/discover?tv=content');
    expect(_scope(tester).target, 'tab-5');
    harness.startup.signalLibraryTerminalFrame();
    await tester.pump();
    await tester.pump();
    expect(gateway.listCalls, 1);
    gateway.listGate!.complete();
    await tester.pump();
    await _select(tester, 'tab-7');
    expect(_scope(tester).target, 'tab-7', reason: 'latest intent must be selected before homepage validation');
    expect(harness.container.read(discoveryPageControllerProvider.notifier).tvPrimaryTarget, 'tab-7');
    final trace = <String>[];
    harness.container.listen(
      discoveryPageControllerProvider,
      (_, next) =>
          trace.add('${next.status}/${next.target}/${harness.container.read(discoveryPageControllerProvider.notifier).tvPrimaryTarget}'),
    );
    final focus = FocusManager.instance.primaryFocus;
    final tabNode = _focus(tester, 'tab-7');
    final position = tester
        .state<ScrollableState>(find.descendant(of: find.byKey(const Key('tv-outer-navigation')), matching: find.byType(Scrollable)).first)
        .position;
    final offset = position.pixels;
    expect(offset, greaterThan(0));
    gateway.homeGate!.complete();
    await tester.pumpAndSettle();
    expect(harness.container.read(discoveryPageControllerProvider).target, 'tab-7', reason: trace.join('\n'));
    expect(_scope(tester).target, 'tab-7');
    expect(_focus(tester, 'tab-7'), same(tabNode));
    expect(FocusManager.instance.primaryFocus, same(focus));
    expect(position.pixels, offset);
    expect(tester.takeException(), isNull);
  });

  for (final corrupt in [false, true]) {
    testWidgets('${corrupt ? 'corrupt cache' : 'first install'} shows classification loading with working static navigation', (
      tester,
    ) async {
      final gateway = _Gateway();
      await _mount(tester, gateway, corrupt: corrupt);
      expect(find.text('正在加载分类…'), findsOneWidget);
      for (final label in ['首页', '发现', '设置', '搜索']) {
        expect(find.text(label), findsOneWidget);
      }
      expect(gateway.listCalls, 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('authoritative removal clears visible and persisted navigation', (tester) async {
    final gateway = _Gateway();
    final harness = await _mount(tester, gateway, cached: true);
    harness.startup.signalLibraryTerminalFrame();
    await tester.pumpAndSettle();
    gateway.ids = [];
    harness.container.read(pluginRuntimeCatalogChangeProvider.notifier).publish(pluginIds: ['sakura']);
    await tester.pumpAndSettle();
    expect(_scope(tester).entries, isEmpty);
    expect(harness.settings.get(AppSettingKeys.tvDiscoveryNavigation), isEmpty);
    await tester.pump(const Duration(milliseconds: 350));
    expect(tester.takeException(), isNull);
  });
}

Future<({GoRouter router, AppStartupController startup, ProviderContainer container, AppSettingsManager settings})> _mount(
  WidgetTester tester,
  _Gateway gateway, {
  bool cached = false,
  bool corrupt = false,
}) async {
  final settings = await createTestAppSettings();
  addTearDown(settings.close);
  if (cached) {
    await AppSettingsTvDiscoveryNavigationStore(settings).save(
      TvDiscoveryNavigationSnapshot(
        sourceId: 'sakura',
        pluginVersion: '1',
        tabs: [
          const TvDiscoveryTab(label: '樱花动漫', target: null),
          for (var i = 0; i < 8; i++) TvDiscoveryTab(label: '分类 $i', target: 'tab-$i'),
        ],
      ),
    );
  }
  if (corrupt) await settings.set(AppSettingKeys.tvDiscoveryNavigation, {'version': 1, 'tabs': 'broken'});
  final diagnostics = DiagnosticsTestkit();
  addTearDown(diagnostics.dispose);
  final startup = AppStartupController(diagnostics: diagnostics.manager, openResources: () async => const AppStartupResources());
  addTearDown(startup.close);
  await startup.start();
  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, _) => const _Page()),
      GoRoute(path: '/discover', builder: (_, _) => const _Page(content: true)),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appSettingsProvider.overrideWithValue(settings),
        appStartupControllerProvider.overrideWithValue(startup),
        sourceContentGatewayProvider.overrideWithValue(gateway),
      ],
      child: MaterialApp.router(
        theme: AppTheme.dark(),
        routerConfig: router,
        builder: (_, child) => TvNavigationHandoff(
          child: AppTvSourceNavigation(enabled: true, router: router, child: child!),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  final container = ProviderScope.containerOf(tester.element(find.byType(AppTvSourceNavigation)));
  return (router: router, startup: startup, container: container, settings: settings);
}

class _Page extends StatelessWidget {
  const _Page({this.content = false});
  final bool content;
  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        TvTopNavigation(selected: content ? AppNavigationDestination.discover : AppNavigationDestination.home, onSelected: (_) {}),
        const Expanded(child: SizedBox()),
      ],
    ),
  );
}

Finder _tab(String target) => find.byKey(ValueKey<Object>(('tv-source-tab', 'sakura', target)));
FocusNode _focus(WidgetTester tester, String target) =>
    tester.widget<TvFocusable>(find.descendant(of: _tab(target), matching: find.byType(TvFocusable))).focusNode!;
TvSourceNavigationScope _scope(WidgetTester tester) => TvSourceNavigationScope.maybeOf(tester.element(find.byType(TvTopNavigation)))!;
Future<void> _select(WidgetTester tester, String target) async {
  await tester.ensureVisible(_tab(target));
  await tester.tap(_tab(target));
  await tester.pumpAndSettle();
}

class _Gateway extends TvDiscoveryTestGateway {
  Completer<void>? listGate;
  int listCalls = 0;
  List<String> ids = ['sakura'];
  @override
  Future<List<PluginSourceDescriptor>> listSources() async {
    listCalls++;
    await listGate?.future;
    return [
      for (final id in ids)
        PluginSourceDescriptor(id: id, displayName: '樱花动漫', pluginVersion: '1', contentKinds: const [PluginContentKind.video]),
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
    if (target != null) return tvDiscoveryDocument(pluginId: pluginId, target: target);
    await homeGate?.future;
    return PluginDiscoveryDocumentResult(
      pluginId: pluginId,
      sourceName: '樱花动漫',
      document: PluginDiscoveryDocument(
        components: [
          PluginDiscoveryTabsComponent(
            id: 'tabs',
            selectedTabId: 'tab-0',
            tabs: [for (var i = 0; i < 8; i++) PluginDiscoveryTab(id: 'tab-$i', label: '分类 $i', target: 'tab-$i')],
          ),
        ],
      ),
    );
  }
}
