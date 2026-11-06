/// Menu regressions: viewport containment, large-text access, dismissal and shared home visuals.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/library/presentation/library_home_view_data.dart';
import 'package:mg_read/features/library/presentation/widgets/library_anchored_menu.dart';
import 'package:mg_read/features/library/presentation/widgets/library_book_list.dart';
import 'package:mg_read/features/library/presentation/widgets/library_home_shell.dart';

const _menuKey = Key('test-menu');

void main() {
  setUpAll(() async {
    final font = FontLoader('packages/novel_reader_ui/MiSans')
      ..addFont(rootBundle.load('packages/novel_reader_ui/assets/fonts/MiSansVF.ttf'));
    final icons = FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await Future.wait(<Future<void>>[font.load(), icons.load()]);
  });

  for (final alignment in <Alignment>[Alignment.topRight, Alignment.bottomRight, Alignment.topLeft]) {
    testWidgets('menu stays inside the safe area at $alignment', (tester) async {
      await _viewport(tester, const Size(390, 600));
      await tester.pumpWidget(_menuHost(alignment: alignment));
      await tester.tap(find.byTooltip('测试菜单'));
      await tester.pumpAndSettle();

      final Rect menu = tester.getRect(find.byKey(_menuKey));
      final Rect trigger = tester.getRect(find.byTooltip('测试菜单'));
      expect(menu.width, inInclusiveRange(200, 280));
      expect(menu.left, greaterThanOrEqualTo(12));
      expect(menu.right, lessThanOrEqualTo(378));
      expect(menu.top, greaterThanOrEqualTo(36));
      expect(menu.bottom, lessThanOrEqualTo(572));
      if (alignment == Alignment.bottomRight) {
        expect(menu.bottom, lessThan(trigger.top));
      } else {
        expect(menu.top, greaterThan(trigger.bottom));
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('short narrow viewport keeps large-text actions reachable by scrolling', (tester) async {
    await _viewport(tester, const Size(320, 320));
    int selected = 0;
    await tester.pumpWidget(_menuHost(textScale: 2, actionCount: 8, onSelected: () => selected++));
    await tester.tap(find.byTooltip('测试菜单'));
    await tester.pumpAndSettle();

    final Rect menu = tester.getRect(find.byKey(_menuKey));
    expect(menu.left, greaterThanOrEqualTo(12));
    expect(menu.right, lessThanOrEqualTo(308));
    expect(menu.top, greaterThanOrEqualTo(36));
    expect(menu.bottom, lessThanOrEqualTo(292));
    await tester.drag(find.byKey(_menuKey), const Offset(0, -1000));
    await tester.pumpAndSettle();
    await tester.tap(find.text('操作 7'));
    await tester.pumpAndSettle();
    expect(selected, 1);
    expect(find.byKey(_menuKey), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing animation cannot select an action twice', (tester) async {
    int selected = 0;
    await tester.pumpWidget(_menuHost(onSelected: () => selected++));
    await tester.tap(find.byTooltip('测试菜单'));
    await tester.pumpAndSettle();
    final Offset action = tester.getCenter(find.text('操作 0'));
    await tester.tapAt(action);
    await tester.pump();
    await tester.tapAt(action);
    await tester.pumpAndSettle();
    expect(selected, 1);
    expect(find.byKey(_menuKey), findsNothing);
  });

  testWidgets('back closes the menu before leaving its page and disposal clears the overlay', (tester) async {
    await tester.pumpWidget(_menuHost());
    await tester.tap(find.byTooltip('测试菜单'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(_menuKey), findsNothing);
    expect(find.byTooltip('测试菜单'), findsOneWidget);
    await tester.tap(find.byTooltip('测试菜单'));
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(find.byKey(_menuKey), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keyboard moves between actions and Escape returns focus to the trigger', (tester) async {
    await tester.pumpWidget(_menuHost());
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(Focus.of(tester.element(find.text('操作 1'))).hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(_menuKey), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byKey(_menuKey), findsOneWidget);
  });

  testWidgets('scrolling the shelf dismisses the menu attached to its old book position', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: ListView(controller: controller, children: <Widget>[_testMenu(), const SizedBox(height: 1500)]),
        ),
      ),
    );
    await tester.tap(find.byTooltip('测试菜单'));
    await tester.pumpAndSettle();
    controller.jumpTo(100);
    await tester.pumpAndSettle();
    expect(find.byKey(_menuKey), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    for (final kind in <String>['top', 'list', 'card']) {
      testWidgets('$kind menu visual in ${brightness.name} theme', (tester) async {
        await _viewport(tester, const Size(390, 900));
        await tester.pumpWidget(_homeHost(brightness: brightness, card: kind == 'card'));
        await tester.pumpAndSettle();
        final Finder popup;
        if (kind == 'top') {
          await tester.tap(find.byTooltip('更多操作'));
          popup = find.descendant(of: find.byType(BottomSheet), matching: find.byType(Material)).first;
        } else if (kind == 'card') {
          await tester.tap(find.byKey(const Key('library-grid-book-overflow-menu-fixture-lord-of-mysteries')));
          popup = find.byKey(const Key('library-grid-book-popup-fixture-lord-of-mysteries'));
        } else {
          await tester.tap(find.text('书架'));
          await tester.pumpAndSettle();
          final book = find.byType(LibraryBookListItem).first;
          await tester.ensureVisible(book);
          await tester.tap(find.descendant(of: book, matching: find.byTooltip('书籍更多操作')));
          popup = find.byKey(const Key('library-book-overflow-menu-fixture-lord-of-mysteries'));
        }
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final Rect menu = tester.getRect(popup);
        if (kind == 'top') {
          expect(menu.left, 0);
          expect(menu.right, 390);
          expect(menu.bottom, 900);
        } else {
          expect(menu.left, greaterThanOrEqualTo(12));
          expect(menu.right, lessThanOrEqualTo(378));
          expect(menu.bottom, lessThanOrEqualTo(888));
        }
        await expectLater(popup, matchesGoldenFile('../goldens/library_${kind}_menu_${brightness.name}.png'));
      });
    }
  }
}

Widget _testMenu({int actionCount = 3, VoidCallback? onSelected}) => LibraryAnchoredMenu(
  tooltip: '测试菜单',
  menuKey: _menuKey,
  actions: <LibraryAnchoredMenuAction>[
    for (int index = 0; index < actionCount; index++)
      LibraryAnchoredMenuAction(label: '操作 $index', icon: Icons.info_outline_rounded, onSelected: onSelected ?? () {}),
  ],
  triggerBuilder: (context, onPressed) => IconButton(tooltip: '测试菜单', onPressed: onPressed, icon: const Icon(Icons.more_vert)),
);

Widget _menuHost({Alignment alignment = Alignment.topRight, double textScale = 1, int actionCount = 3, VoidCallback? onSelected}) {
  return MaterialApp(
    theme: AppTheme.light(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(padding: const EdgeInsets.only(top: 24, bottom: 16), textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Align(
            alignment: alignment,
            child: _testMenu(actionCount: actionCount, onSelected: onSelected),
          ),
        ),
      ),
    ),
  );
}

Widget _homeHost({required Brightness brightness, required bool card}) => ProviderScope(
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: brightness == Brightness.dark ? AppTheme.dark() : AppTheme.light(),
    home: LibraryHomeShell(
      data: LibraryHomeFixtures.preview,
      initialLayoutMode: card ? LibraryHomeLayoutMode.card : LibraryHomeLayoutMode.list,
      isRefreshing: false,
      onRefresh: () async {},
      onLayoutModeChanged: (_) async {},
      callbacks: LibraryHomeCallbacks(
        onImportLocal: () {},
        onBookDetail: (_) {},
        onRefreshBook: (_) async {},
        onSetBookPrivate: (_) async {},
        onDeleteBook: (_) async {},
        onToggleBookCoverBlur: (_) async {},
      ),
    ),
  ),
);

Future<void> _viewport(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pump();
}
