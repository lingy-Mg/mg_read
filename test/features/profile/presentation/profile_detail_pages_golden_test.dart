import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/profile/presentation/about_page.dart';
import 'package:mg_read/features/profile/presentation/feedback_page.dart';

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

  testWidgets('matches the compact light about reference baseline', (
    WidgetTester tester,
  ) async {
    await _setViewport(tester);
    await tester.pumpWidget(
      _host(themeMode: ThemeMode.light, child: _aboutPage()),
    );
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/about_compact_light.png'),
    );
  });

  testWidgets('matches the compact light feedback reference baseline', (
    WidgetTester tester,
  ) async {
    await _setViewport(tester);
    await tester.pumpWidget(
      _host(themeMode: ThemeMode.light, child: _feedbackPage()),
    );
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/feedback_compact_light.png'),
    );
  });
}

Widget _aboutPage() {
  return AboutPage(onBackRequested: () {}, onDestinationRequested: (_) {});
}

Widget _feedbackPage() {
  return FeedbackPage(onBackRequested: () {}, onDestinationRequested: (_) {});
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
        data: mediaQuery.copyWith(
          padding: const EdgeInsets.only(top: 24),
          viewPadding: const EdgeInsets.only(top: 24),
        ),
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
