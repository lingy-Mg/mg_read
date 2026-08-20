import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/discovery/presentation/discovery_page.dart';

void main() {
  setUpAll(() async {
    final FontLoader miSans = FontLoader('packages/novel_reader_ui/MiSans')
      ..addFont(
        rootBundle.load('packages/novel_reader_ui/assets/fonts/MiSansVF.ttf'),
      );
    final FontLoader materialIcons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await Future.wait(<Future<void>>[miSans.load(), materialIcons.load()]);
  });

  testWidgets('matches the compact light discovery visual baseline', (
    WidgetTester tester,
  ) async {
    await _setViewport(tester, const Size(390, 900));
    await tester.pumpWidget(_host(themeMode: ThemeMode.light));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/discovery_compact_light.png'),
    );
  });

  testWidgets('keeps the mobile-first discovery surface centered when wide', (
    WidgetTester tester,
  ) async {
    await _setViewport(tester, const Size(1280, 900));
    await tester.pumpWidget(_host(themeMode: ThemeMode.light));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/discovery_wide_light.png'),
    );
  });
}

Widget _host({required ThemeMode themeMode}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.light(),
    darkTheme: AppTheme.dark(),
    themeMode: themeMode,
    builder: (BuildContext context, Widget? child) {
      final MediaQueryData mediaQuery = MediaQuery.of(context);
      return MediaQuery(
        data: mediaQuery.copyWith(
          padding: const EdgeInsets.only(top: 24),
          viewPadding: const EdgeInsets.only(top: 24),
        ),
        child: child ?? const SizedBox.shrink(),
      );
    },
    home: DiscoveryPage(onDestinationRequested: (_) {}, onToggleTheme: () {}),
  );
}

Future<void> _setViewport(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pump();
}
