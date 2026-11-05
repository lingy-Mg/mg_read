/// TV tablet swipes follow the real outer tabs, routing and source controller.
/// All source results are local fixtures; no Runtime or network is started.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_router.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/discovery/application/discovery_page_controller.dart';
import 'package:mg_read/features/library/presentation/widgets/tv_library_shell.dart';
import '../../../app/mg_read_app_test_support.dart';
import '../../../support/tv_discovery_test_fixture.dart';

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('mgread/rendering_settings'),
      (_) async => {'selected': 'auto', 'activeRenderer': 'opengl', 'restartRequired': false},
    );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('mgread/rendering_settings'),
      null,
    );
  });

  for (final size in [const Size(1280, 800), const Size(800, 1280)]) {
    testWidgets('$size swipes traverse source tabs, retain library filters and restore remote focus', (tester) async {
      final gateway = TvDiscoveryTestGateway()
        ..autoComplete = true
        ..includeLibrary = true;
      await _mount(tester, gateway, size: size);
      final container = ProviderScope.containerOf(tester.element(find.byType(TvLibraryShell)));
      final router = container.read(appRouterProvider);
      final controller = container.read(discoveryPageControllerProvider.notifier);
      await _swipe(tester, left: false);
      expect(router.routeInformationProvider.value.uri.path, '/');
      await _swipe(tester);
      expect(router.routeInformationProvider.value.uri.toString(), '/discover?tv=content');
      expect(controller.tvPrimaryTarget, isNull);
      expect(find.text('首页全部推荐'), findsOneWidget);
      await _swipe(tester);
      expect(controller.tvPrimaryTarget, 'library');
      await controller.selectTvFilter('library:jp');
      await tester.pumpAndSettle();
      await _swipe(tester);
      expect(controller.tvPrimaryTarget, 'today');
      await _swipe(tester, left: false);
      expect(controller.tvPrimaryTarget, 'library');
      expect(container.read(discoveryPageControllerProvider).target, 'library:jp');
      final libraryTab = find.byKey(const ValueKey<Object>(('tv-source-tab', 'sakura', 'library')));
      final focus = tester.widget<Focus>(find.descendant(of: libraryTab, matching: find.byType(Focus)).first).focusNode;
      expect(FocusManager.instance.primaryFocus, focus);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(controller.tvPrimaryTarget, 'today');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('swipes reach Discovery, Settings and Search in displayed order and stop at the edge', (tester) async {
    final gateway = TvDiscoveryTestGateway()..autoComplete = true;
    await _mount(tester, gateway);
    final container = ProviderScope.containerOf(tester.element(find.byType(TvLibraryShell)));
    final router = container.read(appRouterProvider);
    await container.read(discoveryPageControllerProvider.notifier).selectTvTab('new');
    router.go('/discover?tv=content');
    await tester.pumpAndSettle();
    await _swipe(tester);
    expect(router.routeInformationProvider.value.uri.toString(), '/discover');
    expect(find.byKey(const Key('tv-discovery-sources')), findsOneWidget);
    await _swipe(tester);
    expect(router.routeInformationProvider.value.uri.path, '/profile');
    await _swipe(tester);
    expect(router.routeInformationProvider.value.uri.path, '/search');
    await _swipe(tester);
    expect(router.routeInformationProvider.value.uri.path, '/search');
    await _swipe(tester, left: false);
    expect(router.routeInformationProvider.value.uri.path, '/profile');
    expect(tester.takeException(), isNull);
  });
}

Future<void> _swipe(WidgetTester tester, {bool left = true}) async {
  final size = tester.view.physicalSize / tester.view.devicePixelRatio;
  await tester.dragFrom(Offset(size.width * (left ? .7 : .3), size.height * .75), Offset(size.width * (left ? -.2 : .2), 0));
  await tester.pumpAndSettle();
}

Future<void> _mount(WidgetTester tester, TvDiscoveryTestGateway gateway, {Size size = const Size(1280, 720)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final settings = await createTestAppSettings();
  addTearDown(settings.close);
  await settings.set(AppSettingKeys.tvMode, true);
  await settings.set(AppSettingKeys.sourceAutoUpdateCheckEnabled, false);
  await tester.pumpWidget(testMgReadApp(settings, sourceGateway: gateway));
  await tester.pumpAndSettle();
}
