/// TV route layout and remote focus regressions using local host fixtures.
/// Native IME and physical remote behavior require separate device acceptance.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mg_read/app/app_router.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/library/presentation/widgets/tv_library_shell.dart';
import 'package:mg_read/shared/presentation/widgets/app_bottom_navigation.dart';
import 'mg_read_app_test_support.dart';

void main() {
  setUpAll(() async {
    await (FontLoader(
      'packages/novel_reader_ui/MiSans',
    )..addFont(rootBundle.load('packages/novel_reader_ui/assets/fonts/MiSansVF.ttf'))).load();
    await (FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  for (final route in [
    '/search',
    '/discover',
    '/profile',
    '/profile/settings/theme-appearance',
    '/profile/settings/reading-settings',
    '/profile/settings/network-proxy',
    '/profile/edit',
    '/profile/about',
  ]) {
    testWidgets('TV large text fits $route on a short screen', (tester) async {
      tester.view.physicalSize = const Size(640, 360);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.6;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final settings = await createTestAppSettings();
      addTearDown(settings.close);
      await settings.set(AppSettingKeys.tvMode, true);
      await settings.set(AppSettingKeys.sourceAutoUpdateCheckEnabled, false);
      await tester.pumpWidget(testMgReadApp(settings));
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(tester.element(find.byType(TvLibraryShell)));
      container.read(appRouterProvider).go(route);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      if (route == '/search') {
        expect(
          tester.getRect(find.byKey(const Key('search-page-scroll'))).bottom,
          lessThanOrEqualTo(tester.getRect(find.byType(AppBottomNavigation)).top),
        );
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/tv_search_short_large_text.png'));
      }
      for (var i = 0; i < 16; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
    });
  }

  for (final entry in {'/profile/edit': 'edit-profile-display-name', '/profile/settings/network-proxy': 'network-proxy-host'}.entries) {
    testWidgets('TV ${entry.key} input can leave editing by remote', (tester) async {
      final settings = await createTestAppSettings();
      addTearDown(settings.close);
      await settings.set(AppSettingKeys.tvMode, true);
      await settings.set(AppSettingKeys.sourceAutoUpdateCheckEnabled, false);
      await tester.pumpWidget(testMgReadApp(settings));
      await tester.pumpAndSettle();
      final router = ProviderScope.containerOf(tester.element(find.byType(TvLibraryShell))).read(appRouterProvider);
      router.go(entry.key);
      await tester.pumpAndSettle();
      final field = find.byKey(Key(entry.value));
      await tester.scrollUntilVisible(field, 100, scrollable: find.byType(Scrollable).first);
      final input = tester.widget<EditableText>(find.descendant(of: field, matching: find.byType(EditableText)));
      input.focusNode.requestFocus();
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(input.focusNode.hasFocus, isFalse);
      if (entry.value == 'network-proxy-host') {
        final port = tester.widget<EditableText>(
          find.descendant(of: find.byKey(const Key('network-proxy-port')), matching: find.byType(EditableText)),
        );
        expect(port.focusNode.hasFocus, isTrue);
      }
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(router.routeInformationProvider.value.uri.path, '/profile');
    });
  }

  testWidgets('TV search input releases focus to remote directions', (tester) async {
    final settings = await createTestAppSettings();
    addTearDown(settings.close);
    await settings.set(AppSettingKeys.tvMode, true);
    await settings.set(AppSettingKeys.sourceAutoUpdateCheckEnabled, false);
    await tester.pumpWidget(testMgReadApp(settings));
    await tester.pumpAndSettle();
    ProviderScope.containerOf(tester.element(find.byType(TvLibraryShell))).read(appRouterProvider).go('/search');
    await tester.pumpAndSettle();
    final query = tester.widget<TextField>(find.byKey(const Key('source-search-query')));
    query.focusNode!.requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(query.focusNode!.hasFocus, isFalse);
  });
}
