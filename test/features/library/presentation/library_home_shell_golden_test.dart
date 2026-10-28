import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/library/presentation/library_home_view_data.dart';
import 'package:mg_read/features/library/presentation/widgets/library_book_grid.dart';
import 'package:mg_read/features/library/presentation/widgets/library_home_shell.dart';

void main() {
  setUpAll(() async {
    final FontLoader miSans = FontLoader('packages/novel_reader_ui/MiSans')
      ..addFont(rootBundle.load('packages/novel_reader_ui/assets/fonts/MiSansVF.ttf'));
    final FontLoader materialIcons = FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await Future.wait(<Future<void>>[miSans.load(), materialIcons.load()]);
  });

  testWidgets('matches the compact light home visual baseline', (WidgetTester tester) async {
    await _setViewport(tester, const Size(390, 900));
    await tester.pumpWidget(_host(themeMode: ThemeMode.light));
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
    expect(find.byType(Image), findsAtLeastNWidgets(7));

    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/library_home_compact_light.png'));
  });

  testWidgets('matches the compact light home card baseline', (WidgetTester tester) async {
    await _setViewport(tester, const Size(390, 900));
    await tester.pumpWidget(_host(themeMode: ThemeMode.light, initialLayoutMode: LibraryHomeLayoutMode.card));
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();

    expect(find.byType(LibraryBookSliverGrid), findsOneWidget);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/library_home_compact_card_light.png'));
  });

  for (final (mode, size, name) in [
    (ThemeMode.dark, const Size(390, 900), 'library_home_compact_dark.png'),
    (ThemeMode.dark, const Size(1280, 900), 'library_home_wide_dark.png'),
    (ThemeMode.light, const Size(1280, 900), 'library_home_wide_light.png'),
  ]) {
    testWidgets('home contrast and layout $name', (tester) async {
      await _setViewport(tester, size);
      await tester.pumpWidget(_host(themeMode: mode));
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name'));
    });
  }
}

Widget _host({required ThemeMode themeMode, LibraryHomeLayoutMode initialLayoutMode = LibraryHomeLayoutMode.list}) {
  return ProviderScope(
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeMode,
      builder: (BuildContext context, Widget? child) {
        final MediaQueryData mediaQuery = MediaQuery.of(context);
        return MediaQuery(
          data: mediaQuery.copyWith(padding: const EdgeInsets.only(top: 24), viewPadding: const EdgeInsets.only(top: 24)),
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: LibraryHomeShell(
        data: LibraryHomeFixtures.preview,
        initialLayoutMode: initialLayoutMode,
        onLayoutModeChanged: (_) async {},
        isRefreshing: false,
        onRefresh: () async {},
        onToggleTheme: () {},
      ),
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
