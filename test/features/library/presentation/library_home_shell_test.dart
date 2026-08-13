import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_strings.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/library/presentation/library_home_view_data.dart';
import 'package:mg_read/features/library/presentation/widgets/library_book_cover.dart';
import 'package:mg_read/features/library/presentation/widgets/library_book_update_tile.dart';
import 'package:mg_read/features/library/presentation/widgets/library_home_controls.dart';
import 'package:mg_read/features/library/presentation/widgets/library_home_shell.dart';

void main() {
  testWidgets('renders the home hierarchy with progress and book semantics', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byType(LibraryHomeTopBar),
        matching: find.text(AppStrings.libraryTitle),
      ),
      findsOneWidget,
    );
    expect(find.textContaining(AppStrings.previewModeLabel), findsNothing);
    expect(find.byKey(const Key('continue-reading-cta')), findsOneWidget);
    expect(find.text('诡秘之主'), findsAtLeastNWidgets(2));
    expect(find.text(AppStrings.recentUpdatesLabel), findsOneWidget);
    expect(find.text(AppStrings.manageSourcesLabel), findsOneWidget);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (Widget widget) =>
            widget is Semantics &&
            widget.properties.label == AppStrings.readingProgressLabel(72),
      ),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (Widget widget) =>
            widget is Semantics &&
            widget.properties.label ==
                AppStrings.bookUpdateLabel(
                  title: '诡秘之主',
                  chapter: '第1268章 不可名状的低语',
                  updatedLabel: '1小时前',
                  hasUnreadUpdate: true,
                ),
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'continue reading and bottom navigation invoke replaceable callbacks',
    (WidgetTester tester) async {
      int continueReadingCount = 0;
      LibraryNavigationDestination? selectedDestination;

      await tester.pumpWidget(
        _host(
          callbacks: LibraryHomeCallbacks(
            onContinueReading: () {
              continueReadingCount += 1;
            },
            onNavigationSelected: (LibraryNavigationDestination destination) {
              selectedDestination = destination;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('continue-reading-cta')));
      expect(continueReadingCount, 1);

      await tester.tap(find.text(AppStrings.searchNavigationLabel));
      await tester.pumpAndSettle();
      expect(selectedDestination, LibraryNavigationDestination.search);
    },
  );

  testWidgets('places the temporary theme toggle beside search', (
    WidgetTester tester,
  ) async {
    int toggleCount = 0;
    await _setViewport(tester, const Size(390, 900));
    await tester.pumpWidget(
      _host(
        onToggleTheme: () {
          toggleCount += 1;
        },
      ),
    );
    await tester.pumpAndSettle();

    final Finder search = find.byTooltip(AppStrings.searchActionLabel);
    final Finder toggle = find.byKey(const Key('theme-mode-toggle'));
    expect(toggle, findsOneWidget);
    final double actionGap =
        tester.getRect(toggle).left - tester.getRect(search).right;
    expect(actionGap, greaterThanOrEqualTo(0));
    expect(actionGap, lessThanOrEqualTo(AppSpacing.compact));
    expect(find.byTooltip(AppStrings.switchToDarkThemeLabel), findsOneWidget);

    await tester.tap(toggle);
    expect(toggleCount, 1);
  });

  testWidgets('unbound actions show and dismiss local presentation feedback', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('continue-reading-cta')));
    await tester.pumpAndSettle();
    expect(find.text(AppStrings.actionUnavailableMessage), findsOneWidget);

    await tester.tap(find.byTooltip(AppStrings.dismissLabel));
    await tester.pumpAndSettle();
    expect(find.text(AppStrings.actionUnavailableMessage), findsNothing);
  });

  testWidgets(
    'status filtering supports touch selection and keeps semantic state',
    (WidgetTester tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      await _setViewport(tester, const Size(390, 844));
      await tester.pumpWidget(_host());
      await tester.pumpAndSettle();

      final Finder completedFilter = find.byKey(
        const Key('library-filter-completed'),
      );
      await tester.ensureVisible(completedFilter);
      await tester.tap(completedFilter);
      await tester.pumpAndSettle();

      expect(find.text('大道朝天'), findsNothing);
      expect(find.text('我在精神病院学斩神'), findsAtLeastNWidgets(1));
      expect(find.text('宿命之环'), findsAtLeastNWidgets(1));
      final SemanticsNode completedSemantics = tester.getSemantics(
        completedFilter,
      );
      expect(completedSemantics.flagsCollection.isSelected, Tristate.isTrue);
      expect(
        completedSemantics.getSemanticsData().hasAction(SemanticsAction.tap),
        isTrue,
      );
      semantics.dispose();
    },
  );

  testWidgets('keeps the mobile layout centered on a wide viewport', (
    WidgetTester tester,
  ) async {
    await _setViewport(tester, const Size(390, 844));
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('library-mobile-layout')), findsOneWidget);

    await _setViewport(tester, const Size(1280, 900));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('library-mobile-layout')), findsOneWidget);
    final Rect mobileLayout = tester.getRect(
      find.byKey(const Key('library-mobile-layout')),
    );
    expect(
      mobileLayout.width,
      AppSpacing.mobileContentMaxWidth - AppSpacing.compactPagePadding * 2,
    );
    expect(mobileLayout.center.dx, closeTo(640, 0.1));
  });

  testWidgets(
    'keeps filters beside the section navigation and the reading action on the cover baseline',
    (WidgetTester tester) async {
      await _setViewport(tester, const Size(390, 844));
      await tester.pumpWidget(_host());
      await tester.pumpAndSettle();

      final Rect headingRow = tester.getRect(
        find.byKey(const Key('library-list-heading-row')),
      );
      final Rect filters = tester.getRect(
        find.byKey(const Key('library-status-filter-bar')),
      );
      final Rect sectionNavigation = tester.getRect(
        find.byType(LibrarySectionNavigation),
      );
      final Rect continueCover = tester.getRect(
        find.byType(LibraryBookCover).first,
      );
      final Rect continueAction = tester.getRect(
        find.byKey(const Key('continue-reading-cta')),
      );

      expect(filters.left, greaterThan(sectionNavigation.right));
      expect(filters.center.dy, closeTo(headingRow.center.dy, 0.1));
      expect(filters.right, closeTo(headingRow.right, 0.1));
      expect(continueAction.bottom, closeTo(continueCover.bottom, 0.1));
    },
  );

  testWidgets(
    'aligns compact row metadata with the cover and stacks the trailing controls',
    (WidgetTester tester) async {
      await _setViewport(tester, const Size(390, 844));
      await tester.pumpWidget(_host());
      await tester.pumpAndSettle();

      final Finder firstCover = find.byType(LibraryBookCover).at(1);
      final Finder firstTile = find.byType(LibraryBookUpdateTile).first;
      final Finder firstMetadataTag = find.byType(LibraryMetadataTag).first;
      final Finder firstMoreAction = find
          .byTooltip(AppStrings.bookMoreActionsLabel)
          .first;
      final Finder firstUnreadDot = find
          .byWidgetPredicate(
            (Widget widget) =>
                widget is Semantics &&
                widget.properties.label == AppStrings.unreadUpdateLabel,
          )
          .first;
      final Finder firstUpdatedLabel = find.text('1小时前');

      final Rect cover = tester.getRect(firstCover);
      final Rect tile = tester.getRect(firstTile);
      final Rect tag = tester.getRect(firstMetadataTag);
      final Rect moreAction = tester.getRect(firstMoreAction);
      final Rect unreadDot = tester.getRect(firstUnreadDot);
      final Rect updatedLabel = tester.getRect(firstUpdatedLabel);

      expect(tag.height, AppSpacing.metadataTagHeight);
      expect((cover.bottom - tag.bottom).abs(), lessThanOrEqualTo(4));
      expect(
        tile.height,
        closeTo(cover.height + AppSpacing.bookUpdateVerticalPadding * 2, 0.1),
      );
      expect(updatedLabel.right, lessThan(moreAction.left));
      expect(moreAction.center.dx, closeTo(unreadDot.center.dx, 1));
      expect(unreadDot.top, greaterThan(moreAction.bottom));
      expect(updatedLabel.center.dy, closeTo(unreadDot.center.dy, 2));
    },
  );

  testWidgets('renders the same hierarchy in light and dark themes', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_host(themeMode: ThemeMode.light));
    await tester.pumpAndSettle();
    BuildContext context = tester.element(find.byType(LibraryHomeShell));
    expect(Theme.of(context).brightness, Brightness.light);
    expect(
      Theme.of(context).textTheme.bodyMedium?.fontFamily,
      'packages/novel_reader_ui/MiSans',
    );
    expect(find.byKey(const Key('continue-reading-cta')), findsOneWidget);

    await tester.pumpWidget(_host(themeMode: ThemeMode.dark));
    await tester.pumpAndSettle();
    context = tester.element(find.byType(LibraryHomeShell));
    expect(Theme.of(context).brightness, Brightness.dark);
    expect(find.byKey(const Key('continue-reading-cta')), findsOneWidget);
  });

  testWidgets('keyboard traversal activates the first top-bar action', (
    WidgetTester tester,
  ) async {
    int searchCount = 0;
    await tester.pumpWidget(
      _host(
        callbacks: LibraryHomeCallbacks(
          onSearch: () {
            searchCount += 1;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(searchCount, 1);
  });

  testWidgets(
    'desktop scrollbar shares the attached list controller during mouse hover',
    (WidgetTester tester) async {
      await _setViewport(tester, const Size(656, 1129));
      await tester.pumpWidget(_host());
      await tester.pumpAndSettle();

      final Scrollbar scrollbar = tester.widget<Scrollbar>(
        find.byType(Scrollbar),
      );
      final ListView list = tester.widget<ListView>(
        find.byKey(const Key('library-home-content')),
      );
      expect(scrollbar.controller, same(list.controller));
      expect(list.primary, isFalse);

      final TestGesture mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await mouse.addPointer(location: const Offset(650, 400));
      await mouse.moveTo(const Offset(650, 400));
      await tester.pump(const Duration(milliseconds: 250));

      expect(tester.takeException(), isNull);
      await mouse.removePointer(location: const Offset(650, 400));
    },
  );
}

Widget _host({
  ThemeMode themeMode = ThemeMode.light,
  LibraryHomeCallbacks callbacks = const LibraryHomeCallbacks(),
  VoidCallback? onToggleTheme,
}) {
  return MaterialApp(
    theme: AppTheme.light(),
    darkTheme: AppTheme.dark(),
    themeMode: themeMode,
    home: LibraryHomeShell(
      data: LibraryHomeFixtures.preview,
      callbacks: callbacks,
      isRefreshing: false,
      onRefresh: () async {},
      onToggleTheme: onToggleTheme,
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
