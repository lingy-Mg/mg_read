import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/library/presentation/library_home_view_data.dart';
import 'package:mg_read/features/library/presentation/widgets/library_home_shell.dart';

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

  testWidgets('matches the compact light home visual baseline', (
    WidgetTester tester,
  ) async {
    await _setViewport(tester, const Size(390, 900));
    await tester.pumpWidget(_host(themeMode: ThemeMode.light));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/library_home_compact_light.png'),
    );
  });

  testWidgets('matches the compact dark home visual baseline', (
    WidgetTester tester,
  ) async {
    await _setViewport(tester, const Size(390, 900));
    await tester.pumpWidget(_host(themeMode: ThemeMode.dark));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/library_home_compact_dark.png'),
    );
  });

  testWidgets('matches the mobile-first dark baseline on a wide viewport', (
    WidgetTester tester,
  ) async {
    await _setViewport(tester, const Size(1280, 900));
    await tester.pumpWidget(_host(themeMode: ThemeMode.dark));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/library_home_wide_dark.png'),
    );
  });

  testWidgets(
    'matches the compact light source-manager baseline after scroll',
    (WidgetTester tester) async {
      await _setViewport(tester, const Size(390, 900));
      await tester.pumpWidget(_host(themeMode: ThemeMode.light));
      await tester.pumpAndSettle();

      await tester.drag(
        find.byKey(const Key('library-home-content')),
        const Offset(0, -1200),
      );
      await tester.pumpAndSettle();

      expect(find.text('管理我的书源'), findsOneWidget);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/library_home_compact_sources_light.png'),
      );
    },
  );
}

Widget _host({required ThemeMode themeMode}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.light(),
    darkTheme: AppTheme.dark(),
    themeMode: themeMode,
    home: LibraryHomeShell(
      data: LibraryHomeFixtures.preview,
      isRefreshing: false,
      onRefresh: () async {},
      onToggleTheme: () {},
    ),
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
