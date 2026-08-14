import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_strings.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/discovery/presentation/discovery_page.dart';
import 'package:mg_read/features/discovery/presentation/widgets/discovery_book_cover.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';
import 'package:mg_read/shared/presentation/widgets/app_bottom_navigation.dart';

void main() {
  testWidgets(
    'renders the 390 wide discovery hierarchy and reference geometry',
    (WidgetTester tester) async {
      await _setViewport(tester, const Size(390, 900));
      await tester.pumpWidget(_host());
      await tester.pumpAndSettle();

      expect(find.byType(DiscoveryTopBar), findsOneWidget);
      expect(find.byType(DiscoveryTabs), findsOneWidget);
      expect(find.byType(DiscoveryHeroCard), findsOneWidget);
      expect(find.byType(DiscoveryPopularBook), findsNWidgets(5));
      expect(find.byType(DiscoveryRankingBoard), findsOneWidget);
      expect(find.byType(DiscoveryCategoryBoard), findsOneWidget);
      expect(find.byType(DiscoveryEditorsChoiceCard), findsOneWidget);
      expect(find.byType(AppBottomNavigation), findsOneWidget);

      final Rect hero = tester.getRect(find.byType(DiscoveryHeroCard));
      final Finder heroCoverFinder = find.descendant(
        of: find.byType(DiscoveryHeroCard),
        matching: find.byType(DiscoveryBookCover),
      );
      final Rect heroCover = tester.getRect(heroCoverFinder);
      final Rect ranking = tester.getRect(find.byType(DiscoveryRankingBoard));
      final Rect categories = tester.getRect(
        find.byType(DiscoveryCategoryBoard),
      );
      final Rect navigation = tester.getRect(find.byType(AppBottomNavigation));

      expect(hero.left, closeTo(16, 0.1));
      expect(hero.top, closeTo(127, 0.1));
      expect(hero.width, closeTo(358, 0.1));
      expect(hero.height, AppSpacing.discoveryHeroHeight);
      expect(heroCover.size, const Size(108, 164));
      expect(heroCover.right, closeTo(340, 0.1));
      expect(ranking.left, closeTo(16, 0.1));
      expect(ranking.top, closeTo(486, 0.1));
      expect(ranking.height, AppSpacing.discoveryBoardHeight);
      expect(categories.left, closeTo(199, 0.1));
      expect(categories.size, ranking.size);
      expect(navigation.top, closeTo(820, 0.1));
      expect(navigation.height, AppSpacing.bottomNavigationHeight);
    },
  );

  testWidgets(
    'uses explicit discovery text hierarchy and selected navigation',
    (WidgetTester tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      await _setViewport(tester, const Size(390, 900));
      await tester.pumpWidget(_host());
      await tester.pumpAndSettle();

      final Text title = tester.widget<Text>(
        find.descendant(
          of: find.byType(DiscoveryTopBar),
          matching: find.text(AppStrings.discoverNavigationLabel),
        ),
      );
      final Text popularTitle = tester.widget<Text>(
        find.descendant(
          of: find.byType(DiscoverySectionHeader).first,
          matching: find.text(AppStrings.discoveryPopularTitle),
        ),
      );
      final SemanticsNode discoverNavigation = tester.getSemantics(
        find.byKey(const Key('app-nav-discover')),
      );
      final SemanticsNode recommendationTab = tester.getSemantics(
        find.byKey(
          const ValueKey<String>(
            'discovery-tab-${AppStrings.discoveryTabRecommendation}',
          ),
        ),
      );

      expect(title.style?.fontSize, 26);
      expect(title.style?.fontWeight, FontWeight.w600);
      expect(title.style?.height, 1.15);
      expect(popularTitle.style?.fontSize, 17);
      expect(popularTitle.style?.fontWeight, FontWeight.w600);
      expect(discoverNavigation.flagsCollection.isSelected, Tristate.isTrue);
      expect(recommendationTab.flagsCollection.isSelected, Tristate.isTrue);
      semantics.dispose();
    },
  );

  testWidgets(
    'toggles theme, delegates real routes, and keeps pending actions local',
    (WidgetTester tester) async {
      int toggleCount = 0;
      final List<AppNavigationDestination> requested =
          <AppNavigationDestination>[];
      await _setViewport(tester, const Size(390, 900));
      await tester.pumpWidget(
        _host(
          onToggleTheme: () {
            toggleCount += 1;
          },
          onDestinationRequested: requested.add,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('theme-mode-toggle')));
      expect(toggleCount, 1);

      await tester.tap(find.byKey(const Key('discovery-search-action')));
      await tester.pump();
      expect(find.text(AppStrings.actionUnavailableMessage), findsOneWidget);

      await tester.tap(find.byKey(const Key('app-nav-search')));
      await tester.pump();
      expect(requested, isEmpty);
      expect(find.text(AppStrings.actionUnavailableMessage), findsOneWidget);

      await tester.tap(find.byKey(const Key('app-nav-home')));
      await tester.tap(find.byKey(const Key('app-nav-profile')));
      expect(requested, <AppNavigationDestination>[
        AppNavigationDestination.home,
        AppNavigationDestination.profile,
      ]);
    },
  );

  testWidgets('keeps the discovery content centered on a wide viewport', (
    WidgetTester tester,
  ) async {
    await _setViewport(tester, const Size(1280, 900));
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    final Rect hero = tester.getRect(find.byType(DiscoveryHeroCard));
    expect(hero.center.dx, closeTo(640, 0.1));
    expect(hero.width, closeTo(358, 0.1));
  });
}

Widget _host({
  ValueChanged<AppNavigationDestination>? onDestinationRequested,
  VoidCallback? onToggleTheme,
}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.light(),
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
    home: DiscoveryPage(
      onDestinationRequested: onDestinationRequested ?? (_) {},
      onToggleTheme: onToggleTheme ?? () {},
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
