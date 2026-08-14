import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/profile/presentation/profile_page.dart';

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

  testWidgets('matches the compact light profile visual baseline', (
    WidgetTester tester,
  ) async {
    await _setViewport(tester, const Size(390, 900));
    await tester.pumpWidget(_host(themeMode: ThemeMode.light));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/profile_compact_light.png'),
    );
  });

  testWidgets('matches the compact dark profile visual baseline', (
    WidgetTester tester,
  ) async {
    await _setViewport(tester, const Size(390, 900));
    await tester.pumpWidget(_host(themeMode: ThemeMode.dark));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/profile_compact_dark.png'),
    );
  });

  testWidgets('keeps the phone-first profile surface centered when wide', (
    WidgetTester tester,
  ) async {
    await _setViewport(tester, const Size(1280, 900));
    await tester.pumpWidget(_host(themeMode: ThemeMode.light));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/profile_wide_light.png'),
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
    home: ProfilePage(onToggleTheme: () {}),
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
