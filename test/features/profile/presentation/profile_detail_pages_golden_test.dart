import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/profile/presentation/about_page.dart';
import 'package:mg_read/features/profile/presentation/feedback_page.dart';
import 'package:mg_read/features/profile/presentation/network_proxy_settings_page.dart';

import '../../../core/settings/settings_testkit.dart';

void main() {
  setUpAll(() async {
    final FontLoader miSans = FontLoader('packages/novel_reader_ui/MiSans')
      ..addFont(rootBundle.load('packages/novel_reader_ui/assets/fonts/MiSansVF.ttf'));
    final FontLoader materialIcons = FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await Future.wait(<Future<void>>[miSans.load(), materialIcons.load()]);
  });

  testWidgets('matches the compact light about reference baseline', (WidgetTester tester) async {
    await _setViewport(tester);
    await tester.pumpWidget(_host(themeMode: ThemeMode.light, child: _aboutPage()));
    await tester.pumpAndSettle();

    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/about_compact_light.png'));
  });

  testWidgets('matches the compact light feedback reference baseline', (WidgetTester tester) async {
    await _setViewport(tester);
    await tester.pumpWidget(_host(themeMode: ThemeMode.light, child: _feedbackPage()));
    await tester.pumpAndSettle();

    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/feedback_compact_light.png'));
  });

  testWidgets('matches the compact light network proxy reference baseline', (WidgetTester tester) async {
    final settings = AppSettingsManager(store: FakeSettingsStore(), registry: AppSettingKeys.registry);
    await settings.initialize();
    addTearDown(settings.close);
    await _setViewport(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appSettingsProvider.overrideWithValue(settings)],
        child: _host(themeMode: ThemeMode.light, child: _networkProxyPage()),
      ),
    );
    await tester.pumpAndSettle();

    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/network_proxy_compact_light.png'));
  });

  testWidgets('network proxy summary follows endpoint and traffic edits', (WidgetTester tester) async {
    final settings = AppSettingsManager(store: FakeSettingsStore(), registry: AppSettingKeys.registry);
    await settings.initialize();
    addTearDown(settings.close);
    await _setViewport(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appSettingsProvider.overrideWithValue(settings)],
        child: _host(themeMode: ThemeMode.light, child: _networkProxyPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('HTTP://127.0.0.1:9000'), findsOneWidget);
    expect(find.text('未启用'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('network-proxy-host')), 'proxy.local');
    await tester.enterText(find.byKey(const Key('network-proxy-port')), '8080');
    await tester.pump();
    expect(find.text('HTTP://proxy.local:8080'), findsOneWidget);

    final Finder coverSwitch = find.descendant(of: find.byKey(const Key('network-proxy-cover')), matching: find.byType(Switch));
    await tester.tap(coverSwitch);
    await tester.pump();
    expect(find.text('已启用 1 项'), findsOneWidget);
  });
}

Widget _aboutPage() {
  return AboutPage(onBackRequested: () {}, onDestinationRequested: (_) {});
}

Widget _feedbackPage() {
  return FeedbackPage(onBackRequested: () {}, onDestinationRequested: (_) {});
}

Widget _networkProxyPage() {
  return NetworkProxySettingsPage(onBackRequested: () {});
}

Widget _host({required ThemeMode themeMode, required Widget child}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.light(),
    darkTheme: AppTheme.dark(),
    themeMode: themeMode,
    builder: (BuildContext context, Widget? routedChild) {
      final MediaQueryData mediaQuery = MediaQuery.of(context);
      return MediaQuery(
        data: mediaQuery.copyWith(padding: const EdgeInsets.only(top: 24), viewPadding: const EdgeInsets.only(top: 24)),
        child: routedChild ?? const SizedBox.shrink(),
      );
    },
    home: child,
  );
}

Future<void> _setViewport(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pump();
}
