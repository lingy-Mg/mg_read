import 'dart:ui' show PointerDeviceKind, Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/discovery/presentation/discovery_page.dart';
import 'package:mg_read/features/discovery/presentation/discovery_view_data.dart';
import 'package:mg_read/features/discovery/presentation/widgets/discovery_book_cover.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';
import 'package:mg_read/shared/presentation/widgets/app_bottom_navigation.dart';

void main() {
  testWidgets('renders the 390 wide discovery hierarchy and reference geometry', (WidgetTester tester) async {
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
    expect(tester.getRect(find.byType(DiscoveryTopBar)).top, 24);

    final Rect hero = tester.getRect(find.byType(DiscoveryHeroCard));
    final Finder heroCoverFinder = find.descendant(of: find.byType(DiscoveryHeroCard), matching: find.byType(DiscoveryBookCover));
    final Rect heroCover = tester.getRect(heroCoverFinder);
    final Rect ranking = tester.getRect(find.byType(DiscoveryRankingBoard));
    final Rect categories = tester.getRect(find.byType(DiscoveryCategoryBoard));
    final Rect navigation = tester.getRect(find.byType(AppBottomNavigation));

    expect(hero.left, closeTo(16, 0.1));
    expect(hero.top, closeTo(116, 0.1));
    expect(hero.width, closeTo(358, 0.1));
    expect(hero.height, AppSpacing.discoveryHeroHeight);
    expect(heroCover.size, const Size(108, 164));
    expect(heroCover.right, closeTo(340, 0.1));
    expect(ranking.left, closeTo(16, 0.1));
    expect(ranking.top, closeTo(475, 0.1));
    expect(ranking.height, AppSpacing.discoveryBoardHeight);
    expect(categories.left, closeTo(199, 0.1));
    expect(categories.size, ranking.size);
    expect(navigation.top, closeTo(828, 0.1));
    expect(navigation.height, AppSpacing.bottomNavigationHeight);
  });

  testWidgets('uses explicit discovery text hierarchy and selected navigation', (WidgetTester tester) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    await _setViewport(tester, const Size(390, 900));
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    final Text title = tester.widget<Text>(find.descendant(of: find.byType(DiscoveryTopBar), matching: find.text('发现')));
    final Text popularTitle = tester.widget<Text>(
      find.descendant(of: find.byType(DiscoverySectionHeader).first, matching: find.text('人气推荐')),
    );
    final SemanticsNode discoverNavigation = tester.getSemantics(find.byKey(const Key('app-nav-discover')));
    final SemanticsNode recommendationTab = tester.getSemantics(find.byKey(const ValueKey<String>('discovery-tab-推荐')));

    expect(title.style?.fontSize, AppTypography.pageTitle);
    expect(title.style?.fontWeight, FontWeight.w600);
    expect(title.style?.height, 1.15);
    expect(popularTitle.style?.fontSize, AppTypography.sectionTitle);
    expect(popularTitle.style?.fontWeight, FontWeight.w600);
    expect(discoverNavigation.flagsCollection.isSelected, Tristate.isTrue);
    expect(recommendationTab.flagsCollection.isSelected, Tristate.isTrue);
    semantics.dispose();
  });

  testWidgets('delegates real routes and keeps pending actions local in light-only mode', (WidgetTester tester) async {
    final List<AppNavigationDestination> requested = <AppNavigationDestination>[];
    await _setViewport(tester, const Size(390, 900));
    await tester.pumpWidget(_host(onToggleTheme: () {}, onDestinationRequested: requested.add));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('theme-mode-toggle')), findsNothing);

    await tester.tap(find.byKey(const Key('discovery-search-action')));
    await tester.pump();
    expect(requested, <AppNavigationDestination>[AppNavigationDestination.search]);

    await tester.tap(find.byKey(const Key('app-nav-search')));
    await tester.pump();
    expect(requested, <AppNavigationDestination>[AppNavigationDestination.search, AppNavigationDestination.search]);

    await tester.tap(find.byKey(const Key('discovery-source-selector')));
    await tester.pump();
    expect(find.text('此操作尚未接入真实数据，可由后续功能替换。'), findsOneWidget);

    await tester.tap(find.byKey(const Key('app-nav-home')));
    await tester.tap(find.byKey(const Key('app-nav-profile')));
    expect(requested.skip(2), <AppNavigationDestination>[AppNavigationDestination.home, AppNavigationDestination.profile]);
  });

  testWidgets('keeps the discovery content centered on a wide viewport', (WidgetTester tester) async {
    await _setViewport(tester, const Size(1280, 900));
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    final Rect hero = tester.getRect(find.byType(DiscoveryHeroCard));
    expect(hero.center.dx, closeTo(640, 0.1));
    expect(hero.width, closeTo(AppSpacing.contentMaxWidth - AppSpacing.widePagePadding * 2, 0.1));
  });

  testWidgets('adds category columns only when the board can fit them', (WidgetTester tester) async {
    await _setViewport(tester, const Size(390, 900));
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    final Finder compactTiles = find.byType(DiscoveryCategoryTile);
    expect(compactTiles, findsNWidgets(8));
    final double compactTop = tester.getTopLeft(compactTiles.first).dy;
    expect(tester.getTopLeft(compactTiles.at(2)).dy, greaterThan(compactTop));

    await _setViewport(tester, const Size(1280, 900));
    await tester.pump();
    await tester.pumpAndSettle();

    final List<Rect> wideTiles = List<Rect>.generate(
      compactTiles.evaluate().length,
      (int index) => tester.getRect(compactTiles.at(index)),
      growable: false,
    );
    final double firstRowTop = wideTiles.first.top;
    expect(wideTiles.where((rect) => (rect.top - firstRowTop).abs() < 0.1), hasLength(4));
  });

  testWidgets('does not overflow on a compact viewport with larger text', (WidgetTester tester) async {
    await _setViewport(tester, const Size(360, 800));
    await tester.pumpWidget(_host(textScaler: const TextScaler.linear(1.3)));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('renders the recommendation carousel responsively', (WidgetTester tester) async {
    final books = <DiscoveryHeroViewData>[
      const DiscoveryHeroViewData(
        title: '自适应推荐书',
        category: '科幻',
        description: '这是一段推荐简介，用于验证窄屏和宽屏下的截断与布局。',
        metadata: '作者 · 爱丽丝书屋',
        coverVariant: DiscoveryCoverVariant.gothic,
        heat: '1.2万',
      ),
      const DiscoveryHeroViewData(
        title: '第二本推荐书',
        category: '经典',
        description: '第二本推荐内容。',
        metadata: '作者二',
        coverVariant: DiscoveryCoverVariant.abyss,
        heat: '9800',
      ),
    ];

    await _setViewport(tester, const Size(320, 320));
    await tester.pumpWidget(_hostCarousel(books));
    await tester.pump();
    expect(find.byType(DiscoveryCarouselHeroCard), findsOneWidget);
    expect(find.byKey(const Key('discovery-carousel-books')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await _setViewport(tester, const Size(1280, 320));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(tester.getRect(find.byKey(const Key('discovery-carousel-books'))).width, greaterThan(600));
  });

  testWidgets('keeps a wide recommendation card inside its carousel height', (WidgetTester tester) async {
    const book = DiscoveryHeroViewData(
      title: '我想操你（各种花式操弄，高H）',
      category: '校园',
      description: '“我想操你。”一切的改变就是从陶软收到这条信息开始。从此以后，陶软的生活彻底改变。',
      metadata: '溪夕汐',
      coverVariant: DiscoveryCoverVariant.gothic,
    );

    await _setViewport(tester, const Size(540, 320));
    await tester.pumpWidget(_hostCarousel(const <DiscoveryHeroViewData>[book]));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final Rect carousel = tester.getRect(find.byKey(const Key('discovery-carousel-books')));
    final Rect card = tester.getRect(find.byType(DiscoveryCarouselHeroCard));
    expect(card.height, greaterThan(184));
    expect(card.bottom, lessThanOrEqualTo(carousel.bottom));
  });

  testWidgets('allows the recommendation carousel to follow a mouse drag before release', (WidgetTester tester) async {
    const books = <DiscoveryHeroViewData>[
      DiscoveryHeroViewData(title: '第一本推荐书', category: null, description: null, metadata: null, coverVariant: DiscoveryCoverVariant.gothic),
      DiscoveryHeroViewData(title: '第二本推荐书', category: null, description: null, metadata: null, coverVariant: DiscoveryCoverVariant.abyss),
    ];
    await _setViewport(tester, const Size(540, 320));
    await tester.pumpWidget(_hostCarousel(books));
    await tester.pump();

    final Finder scrollable = find.descendant(of: find.byType(PageView), matching: find.byType(Scrollable));
    final ScrollPosition position = tester.state<ScrollableState>(scrollable).position;
    expect(position.pixels, 0);

    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.byType(DiscoveryCarouselHeroCard)),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(-60, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-60, 0));
    await tester.pump();

    expect(position.pixels, greaterThan(0));
    await gesture.up();
  });
}

Widget _host({ValueChanged<AppNavigationDestination>? onDestinationRequested, VoidCallback? onToggleTheme, TextScaler? textScaler}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.light(),
    builder: (BuildContext context, Widget? child) {
      final MediaQueryData mediaQuery = MediaQuery.of(context);
      return MediaQuery(
        data: mediaQuery.copyWith(
          padding: const EdgeInsets.only(top: 24),
          viewPadding: const EdgeInsets.only(top: 24),
          textScaler: textScaler ?? mediaQuery.textScaler,
        ),
        child: child ?? const SizedBox.shrink(),
      );
    },
    home: DiscoveryPage(onDestinationRequested: onDestinationRequested ?? (_) {}, onToggleTheme: onToggleTheme ?? () {}),
  );
}

Widget _hostCarousel(List<DiscoveryHeroViewData> books) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.light(),
    home: Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: DiscoveryCarouselBooks(books: books, onBookPressed: (_) {}),
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
