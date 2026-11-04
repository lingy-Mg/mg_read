/// Outer TV source navigation and second-level library filter acceptance.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_router.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/discovery/application/discovery_page_controller.dart';
import 'package:mg_read/features/discovery/application/discovery_source_selection_store.dart';
import 'package:mg_read/features/library/presentation/widgets/tv_library_shell.dart';
import 'package:mg_read/features/discovery/presentation/discovery_page.dart';
import '../../../support/tv_discovery_test_fixture.dart';
import '../../../app/mg_read_app_test_support.dart';

void main() {
  setUp(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('mgread/rendering_settings'),
      (_) async => {'selected': 'auto', 'activeRenderer': 'opengl', 'restartRequired': false},
    ),
  );
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('mgread/rendering_settings'),
      null,
    ),
  );
  setUpAll(() async {
    await (FontLoader(
      'packages/novel_reader_ui/MiSans',
    )..addFont(rootBundle.load('packages/novel_reader_ui/assets/fonts/MiSansVF.ttf'))).load();
    await (FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  testWidgets('outer tabs replace movie and series while library retains secondary filters', (tester) async {
    final gateway = TvDiscoveryTestGateway()
      ..autoComplete = true
      ..includeLibrary = true;
    await _mount(tester, gateway);
    final container = ProviderScope.containerOf(tester.element(find.byType(TvLibraryShell)));
    final controller = container.read(discoveryPageControllerProvider.notifier);
    final router = container.read(appRouterProvider);
    final outer = find.byKey(const Key('tv-outer-navigation'));
    expect(find.descendant(of: outer, matching: find.text('樱花动漫')), findsOneWidget);
    expect(find.descendant(of: outer, matching: find.text('动漫库')), findsOneWidget);
    expect(find.text('电影'), findsNothing);
    expect(find.text('剧集'), findsNothing);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/tv_discovery_source_tabs.png'));
    _focus(tester, find.byKey(const Key('app-nav-home'))).requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(router.routeInformationProvider.value.uri.toString(), '/discover?tv=content');
    expect(find.text('首页全部推荐'), findsOneWidget);
    expect(find.byKey(const Key('tv-discovery-tabs')), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(controller.tvPrimaryTarget, 'library');
    expect(find.byKey(const Key('tv-open-filters')), findsOneWidget);
    expect(find.text('动漫库'), findsOneWidget, reason: 'the active outer tab is the only duplicate title');
    expect(find.descendant(of: outer, matching: find.text('日本动漫')), findsNothing);
    final before = gateway.requests.length;
    _focus(tester, find.byKey(const ValueKey(('discovery-filter', 'type', 'jp')))).requestFocus();
    await tester.pumpAndSettle();
    expect(container.read(discoveryPageControllerProvider).target, 'library:jp');
    expect(FocusManager.instance.primaryFocus, _focus(tester, find.byKey(const ValueKey(('discovery-filter', 'type', 'jp')))));
    expect(gateway.requests, hasLength(before));
    expect(controller.tvPrimaryTarget, 'library');
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/tv_discovery_category_tabs.png'));
    await tester.tap(find.byKey(const Key('tv-open-filters')));
    await tester.pumpAndSettle();
    _focus(tester, find.byKey(const ValueKey(('discovery-filter', 'genre', 'comedy')))).requestFocus();
    await tester.pumpAndSettle();
    expect(container.read(discoveryPageControllerProvider).target, 'library:jp', reason: 'filters require OK');
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(container.read(discoveryPageControllerProvider).target, 'library:jp:comedy');
    for (final key in [('area', 'jp'), ('year', '2026')]) {
      final option = find.byKey(ValueKey(('discovery-filter', key.$1, key.$2)));
      await tester.ensureVisible(option);
      _focus(tester, option).requestFocus();
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
    }
    expect(container.read(discoveryPageControllerProvider).target, 'library:jp:comedy:area-jp:2026');
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/tv_anime_library_filter_panel.png'));
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<Object>(('tv-source-tab', 'sakura', 'today'))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<Object>(('tv-source-tab', 'sakura', 'library'))));
    await tester.pumpAndSettle();
    expect(container.read(discoveryPageControllerProvider).target, 'library:jp:comedy:area-jp:2026');
    await tester.tap(find.byKey(const Key('tv-reset-filters')));
    await tester.pumpAndSettle();
    expect(container.read(discoveryPageControllerProvider).target, 'library');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(container.read(discoveryPageControllerProvider).target, 'library');
    expect(FocusManager.instance.primaryFocus, _focus(tester, find.byKey(const ValueKey<Object>(('tv-source-tab', 'sakura', 'library')))));
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(router.routeInformationProvider.value.uri.toString(), '/discover?tv=content');
    expect(find.text('再按一次返回键退出应用'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('source tab confirms refresh while upward focus and back retain the active tab', (tester) async {
    final gateway = TvDiscoveryTestGateway()..autoComplete = true;
    await _mount(tester, gateway);
    final container = ProviderScope.containerOf(tester.element(find.byType(TvLibraryShell)));
    final tab = find.byKey(const ValueKey<Object>(('tv-source-tab', 'sakura', 'hot')));
    _focus(tester, tab).requestFocus();
    await tester.pumpAndSettle();
    expect(find.byType(DiscoveryTopBar), findsNothing);
    final before = gateway.requests.where((value) => value == 'sakura/hot').length;
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(gateway.requests.where((value) => value == 'sakura/hot').length, before + 1);
    // Down enters the actual content grid; repeated Up must never select a neighbour.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(_focus(tester, tab).hasFocus, isFalse);
    for (var i = 0; i < 4; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
    }
    expect(_focus(tester, tab).hasFocus, isTrue);
    expect(container.read(discoveryPageControllerProvider.notifier).tvPrimaryTarget, 'hot');
    expect(gateway.requests.where((value) => value == 'sakura/hot').length, before + 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(_focus(tester, tab).hasFocus, isTrue);
    expect(container.read(discoveryPageControllerProvider.notifier).tvPrimaryTarget, 'hot');
    expect(find.text('再按一次返回键退出应用'), findsNothing);
  });
  testWidgets('changing source in Discovery updates the outer source name and categories', (tester) async {
    final gateway = TvDiscoveryTestGateway()
      ..autoComplete = true
      ..includeLibrary = true;
    await _mount(tester, gateway);
    final container = ProviderScope.containerOf(tester.element(find.byType(TvLibraryShell)));
    await tester.ensureVisible(find.byKey(const Key('app-nav-discover')));
    await tester.tap(find.byKey(const Key('app-nav-discover')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tv-discovery-sources')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('tv-source-choice-other')));
    await tester.pumpAndSettle();
    final outer = find.byKey(const Key('tv-outer-navigation'));
    expect(find.descendant(of: outer, matching: find.text('备用动漫')), findsOneWidget);
    expect(find.descendant(of: outer, matching: find.text('其他栏目')), findsOneWidget);
    expect(find.descendant(of: outer, matching: find.text('动漫库')), findsNothing);
    expect(find.descendant(of: outer, matching: find.text('樱花动漫')), findsNothing);
    expect(await container.read(discoverySourceSelectionStoreProvider).load(), 'other');
    await tester.ensureVisible(find.byKey(const Key('app-nav-home')));
    await tester.tap(find.byKey(const Key('app-nav-home')));
    await tester.pumpAndSettle();
    expect(find.byType(TvLibraryShell), findsOneWidget);
    expect(find.descendant(of: outer, matching: find.text('备用动漫')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('all genre options remain reachable by remote on a short large-text screen', (tester) async {
    final gateway = TvDiscoveryTestGateway()
      ..autoComplete = true
      ..includeLibrary = true;
    await _mount(tester, gateway, size: const Size(640, 360), scale: 1.6);
    final container = ProviderScope.containerOf(tester.element(find.byType(TvLibraryShell)));
    await container.read(discoveryPageControllerProvider.notifier).selectTvTab('library');
    container.read(appRouterProvider).go('/discover?tv=content');
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('tv-open-filters')));
    await tester.tap(find.byKey(const Key('tv-open-filters')));
    await tester.pumpAndSettle();
    final options = find.descendant(
      of: find.byKey(const Key('tv-filter-dialog')),
      matching: find.byWidgetPredicate(
        (widget) =>
            widget.key is ValueKey<(String, String, String)> && (widget.key! as ValueKey<(String, String, String)>).value.$2 == 'genre',
      ),
    );
    expect(options, findsNWidgets(45));
    _focus(tester, options.first).requestFocus();
    await tester.pumpAndSettle();
    for (var i = 1; i < 45; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
    }
    expect(FocusManager.instance.primaryFocus, _focus(tester, options.last));
    expect(options.last.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long outer navigation fits a short screen and Search still requires OK', (tester) async {
    final gateway = TvDiscoveryTestGateway()
      ..autoComplete = true
      ..includeLibrary = true;
    await _mount(tester, gateway, size: const Size(640, 360), scale: 1.6);
    final container = ProviderScope.containerOf(tester.element(find.byType(TvLibraryShell)));
    final router = container.read(appRouterProvider);
    _focus(tester, find.byKey(const Key('app-nav-home'))).requestFocus();
    await tester.pumpAndSettle();
    for (var i = 0; i < 9; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
    }
    final search = find.byKey(const Key('app-nav-search'));
    expect(FocusManager.instance.primaryFocus, _focus(tester, search));
    expect(search.hitTestable(), findsOneWidget);
    expect(router.routeInformationProvider.value.uri.path, '/profile');
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(router.routeInformationProvider.value.uri.path, '/search');
    expect(tester.takeException(), isNull);
  });
}

FocusNode _focus(WidgetTester tester, Finder target) =>
    tester.widget<Focus>(find.descendant(of: target, matching: find.byType(Focus)).first).focusNode!;
Future<void> _mount(WidgetTester tester, TvDiscoveryTestGateway gateway, {Size size = const Size(1280, 720), double scale = 1}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final settings = await createTestAppSettings();
  addTearDown(settings.close);
  await settings.set(AppSettingKeys.tvMode, true);
  await settings.set(AppSettingKeys.sourceAutoUpdateCheckEnabled, false);
  await tester.pumpWidget(testMgReadApp(settings, sourceGateway: gateway));
  await tester.pumpAndSettle();
}
