/// TV source-home expansion, pinned categories and focus-triggered cache hits.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/app/app_tv_theme.dart';
import 'package:mg_read/features/discovery/application/discovery_page_controller.dart';
import 'package:mg_read/features/discovery/application/discovery_source_selection_store.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/discovery/presentation/discovery_destination_page.dart';
import 'package:mg_read/shared/presentation/tv_mode_scope.dart';
import 'package:mg_read/shared/presentation/widgets/tv_destination_action.dart';
import '../../../support/tv_discovery_test_fixture.dart';

void main() {
  setUpAll(() async {
    await (FontLoader(
      'packages/novel_reader_ui/MiSans',
    )..addFont(rootBundle.load('packages/novel_reader_ui/assets/fonts/MiSansVF.ttf'))).load();
    await (FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  testWidgets('source-named home expands every item and category focus uses preloaded content', (tester) async {
    final gateway = TvDiscoveryTestGateway()..autoComplete = true;
    await _mount(tester, gateway);
    expect(find.byKey(const ValueKey('tv-discovery-home')), findsOneWidget);
    expect(find.text('首页全部推荐'), findsOneWidget);
    expect(find.text('动漫分类'), findsNothing);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/tv_discovery_source_tabs.png'));
    final tabs = find.byKey(const Key('tv-discovery-tabs'));
    final tabsTop = tester.getTopLeft(tabs).dy;
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('runtime-discovery-cover-home-14')),
      240,
      scrollable: find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first,
    );
    expect(tester.getTopLeft(tabs).dy, tabsTop);
    final homeFocus = _focus(tester, 'home');
    homeFocus.requestFocus();
    await tester.pumpAndSettle();
    final bodyScroll = find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first;
    final homeOffset = tester.state<ScrollableState>(bodyScroll).position.pixels;
    expect(homeOffset, greaterThan(0));
    final before = gateway.requests.length;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(find.text('分类 today'), findsOneWidget);
    expect(gateway.requests, hasLength(before));
    expect(FocusManager.instance.primaryFocus, _focus(tester, 'today'));
    expect(find.byKey(const Key('runtime-discovery-back')), findsNothing);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/tv_discovery_category_tabs.png'));
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('首页全部推荐'), findsOneWidget);
    expect(FocusManager.instance.primaryFocus, homeFocus);
    expect(tester.state<ScrollableState>(bodyScroll).position.pixels, closeTo(homeOffset, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('rapid category focus keeps its node and rejects an earlier category completion', (tester) async {
    final gateway = TvDiscoveryTestGateway();
    await _mount(tester, gateway);
    final container = ProviderScope.containerOf(tester.element(find.byType(DiscoveryDestinationPage)));
    _focus(tester, 'home').requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    final hotFocus = _focus(tester, 'hot');
    expect(FocusManager.instance.primaryFocus, hotFocus);
    gateway.complete('today');
    await tester.pump();
    expect(container.read(discoveryPageControllerProvider).target, 'hot');
    gateway.complete('hot');
    await tester.pumpAndSettle();
    expect(find.text('分类 hot'), findsOneWidget);
    expect(FocusManager.instance.primaryFocus, hotFocus);
    gateway.autoComplete = true;
    for (final gate in gateway.gates.values) {
      if (!gate.isCompleted) gate.complete();
    }
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('pinned navigation fits a short screen with large text', (tester) async {
    final gateway = TvDiscoveryTestGateway()..autoComplete = true;
    await _mount(tester, gateway, size: const Size(640, 360), scale: 1.6);
    _focus(tester, 'home').requestFocus();
    await tester.pumpAndSettle();
    for (var i = 0; i < 4; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
    }
    expect(FocusManager.instance.primaryFocus, _focus(tester, 'new'));
    expect(find.byKey(const ValueKey('tv-discovery-tab-new')).hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

FocusNode _focus(WidgetTester tester, String tab) => tester
    .widget<Focus>(
      find
          .descendant(of: find.byKey(ValueKey(tab == 'home' ? 'tv-discovery-home' : 'tv-discovery-tab-$tab')), matching: find.byType(Focus))
          .first,
    )
    .focusNode!;

Future<void> _mount(WidgetTester tester, TvDiscoveryTestGateway gateway, {Size size = const Size(1280, 720), double scale = 1}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sourceContentGatewayProvider.overrideWithValue(gateway),
        discoverySourceSelectionStoreProvider.overrideWithValue(TvDiscoveryTestSelection()),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: appTvTheme(AppTheme.dark()),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
          child: TvModeScope(
            enabled: true,
            onChanged: (_) {},
            child: TvNavigationHandoff(child: TvRemoteShortcuts(child: child!)),
          ),
        ),
        home: DiscoveryDestinationPage(onDestinationRequested: (_) {}),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
