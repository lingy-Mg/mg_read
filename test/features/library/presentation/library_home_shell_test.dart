import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_strings.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/library/presentation/library_home_view_data.dart';
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
    expect(find.textContaining(AppStrings.previewModeLabel), findsOneWidget);
    expect(find.byKey(const Key('continue-reading-cta')), findsOneWidget);
    expect(find.text('月影书塔'), findsAtLeastNWidgets(2));
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
                  title: '月影书塔',
                  chapter: '第 1268 章 月下的回信',
                  updatedLabel: '1 小时前',
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

      final Finder completedFilter = find.widgetWithText(
        ChoiceChip,
        AppStrings.filterCompletedLabel,
      );
      await tester.ensureVisible(completedFilter);
      await tester.tap(completedFilter);
      await tester.pumpAndSettle();

      expect(find.text('星海来信'), findsNothing);
      expect(find.text('雨夜观测站'), findsOneWidget);
      expect(find.text('炉火之环'), findsOneWidget);
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

  testWidgets('uses compact and wide layouts at the documented breakpoint', (
    WidgetTester tester,
  ) async {
    await _setViewport(tester, const Size(390, 844));
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('library-compact-layout')), findsOneWidget);
    expect(find.byKey(const Key('library-wide-layout')), findsNothing);

    await _setViewport(tester, const Size(1280, 900));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('library-wide-layout')), findsOneWidget);
    expect(find.byKey(const Key('library-compact-layout')), findsNothing);
    expect(
      tester.getSize(find.byKey(const Key('library-wide-layout'))).width,
      lessThanOrEqualTo(AppSpacing.contentMaxWidth),
    );
  });

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
