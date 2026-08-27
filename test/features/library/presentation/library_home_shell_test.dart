import 'dart:convert';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/library/presentation/library_book_list_view_data.dart';
import 'package:mg_read/features/library/presentation/library_home_view_data.dart';
import 'package:mg_read/features/library/presentation/widgets/library_book_cover.dart';
import 'package:mg_read/features/library/presentation/widgets/library_book_list.dart';
import 'package:mg_read/features/library/presentation/widgets/library_book_removal_transition.dart';
import 'package:mg_read/features/library/presentation/widgets/library_book_swipe_actions.dart';
import 'package:mg_read/features/library/presentation/widgets/library_continue_reading_card.dart';
import 'package:mg_read/features/library/presentation/widgets/library_home_controls.dart';
import 'package:mg_read/features/library/presentation/widgets/library_home_shell.dart';
import 'package:mg_read/features/library/presentation/widgets/library_home_top_bar.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';
import 'package:mg_read/shared/presentation/widgets/async_book_cover_loader.dart';
import 'package:mg_read/shared/presentation/widgets/app_bottom_navigation.dart';

void main() {
  testWidgets('renders the home hierarchy with progress and book semantics', (WidgetTester tester) async {
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    expect(find.descendant(of: find.byType(LibraryHomeTopBar), matching: find.text('首页')), findsOneWidget);
    expect(find.textContaining('界面预览'), findsNothing);
    expect(find.byKey(const Key('continue-reading-cta')), findsOneWidget);
    expect(find.text('诡秘之主'), findsAtLeastNWidgets(2));
    expect(find.text('最近更新'), findsOneWidget);
    expect(find.text('管理我的书源'), findsNothing);
    expect(find.byType(AppBottomNavigation), findsOneWidget);
    expect(find.byWidgetPredicate((Widget widget) => widget is Semantics && widget.properties.label == '阅读进度 72%'), findsOneWidget);
    expect(
      find.byWidgetPredicate((Widget widget) => widget is Semantics && widget.properties.label == '诡秘之主，第1268章 不可名状的低语，1小时前，有更新'),
      findsOneWidget,
    );
  });

  testWidgets('shows preparation only on the selected shelf entry', (WidgetTester tester) async {
    await tester.pumpWidget(_host(preparingBookId: 'fixture-heavenly-path'));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    final preparingRow = find.byWidgetPredicate(
      (Widget widget) => widget is LibraryBookListItem && widget.data.id == 'fixture-heavenly-path' && widget.isPreparing,
    );
    expect(preparingRow, findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (Widget widget) => widget is LibraryBookListItem && widget.data.id != 'fixture-heavenly-path' && widget.isPreparing,
      ),
      findsNothing,
    );
  });

  testWidgets('opens the book-detail intent from a long press', (WidgetTester tester) async {
    LibraryBookListItemViewData? selectedBook;
    await tester.pumpWidget(_host(callbacks: LibraryHomeCallbacks(onBookLongPress: (book) => selectedBook = book)));
    await tester.pumpAndSettle();

    await tester.longPress(find.byType(LibraryBookListItem).first);

    expect(selectedBook?.id, 'fixture-lord-of-mysteries');
  });

  testWidgets('exposes data-source management from the top-right menu', (WidgetTester tester) async {
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();

    expect(find.text('管理数据源'), findsOneWidget);
    expect(find.text('管理书源'), findsNothing);
  });

  testWidgets('confirms bookshelf deletion before invoking the delete action', (WidgetTester tester) async {
    LibraryBookListItemViewData? deletedBook;
    await tester.pumpWidget(
      _host(
        callbacks: LibraryHomeCallbacks(
          onDeleteBook: (LibraryBookListItemViewData book) async {
            deletedBook = book;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.drag(find.byType(LibraryBookListItem).first, const Offset(-220, 0));
    await tester.pumpAndSettle();

    expect(find.text('删除'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(find.text('删除书籍'), findsOneWidget);
    expect(find.textContaining('确定要从书架删除'), findsOneWidget);
    expect(deletedBook, isNull);

    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pump();

    expect(deletedBook, isNull);
    expect(tester.widget<LibraryBookRemovalTransition>(find.byType(LibraryBookRemovalTransition).first).isRemoving, isTrue);
    await tester.pump(AppMotion.destinationTransition);
    await tester.pump();

    expect(deletedBook?.id, 'fixture-lord-of-mysteries');
    expect(find.text('已从书架删除《诡秘之主》'), findsOneWidget);
    expect(tester.widget<SnackBar>(find.byType(SnackBar)).behavior, SnackBarBehavior.floating);
  });

  testWidgets('restores a failed deletion in its original list position', (WidgetTester tester) async {
    await tester.pumpWidget(
      _host(
        callbacks: LibraryHomeCallbacks(
          onDeleteBook: (LibraryBookListItemViewData book) async {
            throw StateError('durable removal unavailable');
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.drag(find.byType(LibraryBookListItem).first, const Offset(-220, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pump(AppMotion.destinationTransition);
    await tester.pumpAndSettle();

    expect(find.text('诡秘之主'), findsAtLeastNWidgets(1));
    expect(find.text('删除操作未能完成，请稍后刷新。'), findsOneWidget);
    expect(tester.widget<LibraryBookRemovalTransition>(find.byType(LibraryBookRemovalTransition).first).isRemoving, isFalse);
  });

  testWidgets('top menu closes cleanly when interrupted', (WidgetTester tester) async {
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('更多操作'));
    await tester.pump(const Duration(milliseconds: 40));
    expect(find.byKey(const Key('library-top-overflow-menu')), findsOneWidget);

    await tester.tapAt(const Offset(16, 500));
    await tester.pump(AppMotion.destinationTransition);
    expect(find.byKey(const Key('library-top-overflow-menu')), findsNothing);

    await tester.tap(find.byTooltip('更多操作'));
    await tester.pump(const Duration(milliseconds: 40));
    expect(find.byKey(const Key('library-top-overflow-menu')), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(AppMotion.destinationTransition);
    expect(find.byKey(const Key('library-top-overflow-menu')), findsNothing);
  });

  testWidgets('menus honor reduce motion without retaining an overlay', (WidgetTester tester) async {
    await tester.pumpWidget(_host(disableAnimations: true));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('更多操作'));
    await tester.pump();
    expect(find.byKey(const Key('library-top-overflow-menu')), findsOneWidget);

    await tester.tapAt(const Offset(16, 500));
    await tester.pump();
    expect(find.byKey(const Key('library-top-overflow-menu')), findsNothing);
  });

  testWidgets('offers privacy actions from book swipe actions and home overflow menu', (WidgetTester tester) async {
    LibraryBookListItemViewData? privateBook;
    var privateShelfOpenCount = 0;
    await tester.pumpWidget(
      _host(
        callbacks: LibraryHomeCallbacks(
          onSetBookPrivate: (book) async {
            privateBook = book;
          },
          onPrivacyLibraryRequested: () {
            privateShelfOpenCount++;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.drag(find.byType(LibraryBookListItem).first, const Offset(-220, 0));
    await tester.pumpAndSettle();
    expect(find.text('隐私'), findsOneWidget);
    await tester.tap(find.text('隐私'));
    await tester.pumpAndSettle();
    expect(privateBook?.id, 'fixture-lord-of-mysteries');
    expect(find.textContaining('设为隐私书籍'), findsOneWidget);
    expect(tester.widget<SnackBar>(find.byType(SnackBar)).behavior, SnackBarBehavior.floating);

    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    expect(find.text('隐私书架'), findsOneWidget);
    await tester.tap(find.text('隐私书架'));
    await tester.pumpAndSettle();
    expect(privateShelfOpenCount, 1);
  });

  testWidgets('continue reading and bottom navigation invoke replaceable callbacks', (WidgetTester tester) async {
    int continueReadingCount = 0;
    AppNavigationDestination? selectedDestination;

    await tester.pumpWidget(
      _host(
        callbacks: LibraryHomeCallbacks(
          onContinueReading: () {
            continueReadingCount += 1;
          },
          onNavigationSelected: (AppNavigationDestination destination) {
            selectedDestination = destination;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('continue-reading-cta')));
    expect(continueReadingCount, 1);

    await tester.tap(find.text('搜索'));
    await tester.pumpAndSettle();
    expect(selectedDestination, AppNavigationDestination.search);
  });

  testWidgets('hides the temporary theme toggle beside search', (WidgetTester tester) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    await _setViewport(tester, const Size(390, 900));
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    final Finder search = find.byTooltip('搜索书籍');
    expect(search, findsOneWidget);
    expect(find.byKey(const Key('theme-mode-toggle')), findsNothing);
    semantics.dispose();
  });

  testWidgets('renders the first-run empty bookshelf without preview data', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: LibraryHomeShell(
          data: LibraryHomeViewData.empty(),
          isRefreshing: false,
          onRefresh: () async {},
          callbacks: const LibraryHomeCallbacks(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('开始你的阅读旅程'), findsNothing);
    expect(find.text('当前还没有阅读记录'), findsNothing);
    expect(find.text('暂无更新内容'), findsOneWidget);
    expect(find.text('去发现好书'), findsOneWidget);
    expect(find.textContaining('界面预览'), findsNothing);
    expect(find.text('管理我的书源'), findsNothing);
  });

  testWidgets('uses the compact reference font-size and weight hierarchy', (WidgetTester tester) async {
    await _setViewport(tester, const Size(390, 900));
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    final Text pageTitle = tester.widget<Text>(find.descendant(of: find.byType(LibraryHomeTopBar), matching: find.text('首页')));
    final Text updateTitle = tester.widget<Text>(
      find.descendant(of: find.byType(LibraryBookListItem).first, matching: find.text('诡秘之主')).last,
    );
    final Text selectedSection = tester.widget<Text>(find.text('最近更新'));
    final Text unselectedSection = tester.widget<Text>(find.text('书架'));
    final Text continueAction = tester.widget<Text>(
      find.descendant(of: find.byKey(const Key('continue-reading-cta')), matching: find.text('继续阅读')),
    );

    expect(pageTitle.style?.fontSize, AppTypography.pageTitle);
    expect(pageTitle.style?.fontWeight, FontWeight.w600);
    expect(updateTitle.style?.fontSize, 16);
    expect(updateTitle.style?.fontWeight, FontWeight.w600);
    expect(selectedSection.style?.fontSize, 16);
    expect(selectedSection.style?.fontWeight, FontWeight.w600);
    expect(unselectedSection.style?.fontSize, 16);
    expect(unselectedSection.style?.fontWeight, FontWeight.w400);
    expect(continueAction.style?.fontSize, 14);
    expect(continueAction.style?.fontWeight, FontWeight.w500);
  });

  testWidgets('unbound actions show and dismiss local presentation feedback', (WidgetTester tester) async {
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('continue-reading-cta')));
    await tester.pumpAndSettle();
    expect(find.text('此操作尚未接入真实数据，可由后续功能替换。'), findsOneWidget);

    await tester.tap(find.byTooltip('关闭提示'));
    await tester.pumpAndSettle();
    expect(find.text('此操作尚未接入真实数据，可由后续功能替换。'), findsNothing);
  });

  testWidgets('status filtering supports touch selection and keeps semantic state', (WidgetTester tester) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    await _setViewport(tester, const Size(390, 844));
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    final Finder completedFilter = find.byKey(const Key('library-filter-completed'));
    await tester.ensureVisible(completedFilter);
    await tester.tap(completedFilter);
    await tester.pumpAndSettle();

    expect(find.text('大道朝天'), findsNothing);
    expect(find.text('我在精神病院学斩神'), findsAtLeastNWidgets(1));
    expect(find.text('宿命之环'), findsAtLeastNWidgets(1));
    final SemanticsNode completedSemantics = tester.getSemantics(completedFilter);
    expect(completedSemantics.flagsCollection.isSelected, Tristate.isTrue);
    expect(completedSemantics.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    semantics.dispose();
  });

  testWidgets('filter switching reuses resolved covers without a loading flash', (WidgetTester tester) async {
    BookCoverMemoryCache.clear();
    addTearDown(BookCoverMemoryCache.clear);
    final loader = _CountingBookCoverBytesLoader();
    final data = _asyncCoverLibraryHomeData();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookCoverBytesLoaderProvider.overrideWithValue(loader)],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: LibraryHomeShell(data: data, isRefreshing: false, onRefresh: () async {}),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(loader.loadCounts.values, everyElement(1));
    expect(loader.loadCounts.length, 3);
    expect(
      tester.widgetList<Image>(find.byType(Image)).where((Image image) => image.image is MemoryImage),
      everyElement(isA<Image>().having((Image image) => image.gaplessPlayback, 'gaplessPlayback', isTrue)),
    );

    await tester.tap(find.byKey(const Key('library-filter-completed')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('library-filter-all')));
    await tester.pump();

    expect(
      find.byWidgetPredicate((Widget widget) => widget is Semantics && widget.properties.label?.endsWith('的封面加载中') == true),
      findsNothing,
    );
    expect(loader.loadCounts.values, everyElement(1));
  });

  testWidgets('section and filter switching keep the stable header widgets mounted', (WidgetTester tester) async {
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();
    final headerBefore = tester.widget<LibraryHomeTopBar>(find.byType(LibraryHomeTopBar));
    final readingBefore = tester.widget<LibraryContinueReadingCard>(find.byType(LibraryContinueReadingCard));
    final navigationRectBefore = tester.getRect(find.byType(LibrarySectionNavigation));
    final filterRectBefore = tester.getRect(find.byKey(const Key('library-status-filter-bar')));

    await tester.tap(find.text('书架'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('library-filter-completed')));
    await tester.pumpAndSettle();

    expect(tester.widget<LibraryHomeTopBar>(find.byType(LibraryHomeTopBar)), same(headerBefore));
    expect(tester.widget<LibraryContinueReadingCard>(find.byType(LibraryContinueReadingCard)), same(readingBefore));
    expect(tester.getRect(find.byType(LibrarySectionNavigation)), navigationRectBefore);
    expect(tester.getRect(find.byKey(const Key('library-status-filter-bar'))), filterRectBefore);
  });

  testWidgets('uses the shared book sliver for both home sections', (WidgetTester tester) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    await _setViewport(tester, const Size(390, 844));
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    expect(
      tester.widget<LibraryBookSliverList>(find.byType(LibraryBookSliverList)).presentation,
      same(LibraryBookListPresentation.recentUpdates),
    );
    expect(find.byWidgetPredicate((Widget widget) => widget is Semantics && widget.properties.label == '有更新'), findsAtLeastNWidgets(1));

    await tester.tap(find.text('书架'));
    await tester.pumpAndSettle();

    expect(tester.widget<LibraryBookSliverList>(find.byType(LibraryBookSliverList)).presentation, same(LibraryBookListPresentation.shelf));
    expect(find.byWidgetPredicate((Widget widget) => widget is Semantics && widget.properties.label == '有更新'), findsNothing);
    semantics.dispose();
  });

  testWidgets('adapts the home content to the available viewport width', (WidgetTester tester) async {
    await _setViewport(tester, const Size(390, 844));
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('library-mobile-layout')), findsOneWidget);

    final Rect compactLayout = tester.getRect(find.byKey(const Key('library-mobile-layout')));
    expect(compactLayout.width, 390 - AppSpacing.compactPagePadding * 2);

    await _setViewport(tester, const Size(720, 900));
    await tester.pump();
    await tester.pumpAndSettle();
    final Rect tabletLayout = tester.getRect(find.byKey(const Key('library-mobile-layout')));
    expect(tabletLayout.width, 720 - AppSpacing.widePagePadding * 2);
    expect(tabletLayout.center.dx, closeTo(360, 0.1));

    await _setViewport(tester, const Size(1280, 900));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('library-mobile-layout')), findsOneWidget);
    final Rect mobileLayout = tester.getRect(find.byKey(const Key('library-mobile-layout')));
    expect(mobileLayout.width, AppSpacing.contentMaxWidth - AppSpacing.widePagePadding * 2);
    expect(mobileLayout.center.dx, closeTo(640, 0.1));
  });

  testWidgets('stretches the remaining empty-state card across a narrow window', (WidgetTester tester) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    await _setViewport(tester, const Size(489, 1000));
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: LibraryHomeShell(data: LibraryHomeViewData.empty(), isRefreshing: false, onRefresh: () async {}),
      ),
    );
    await tester.pumpAndSettle();

    final double expectedWidth = 489 - AppSpacing.compactPagePadding * 2;
    final Finder emptyUpdatesCard = find.byWidgetPredicate((Widget widget) => widget is Semantics && widget.properties.label == '暂无更新内容');
    expect(emptyUpdatesCard, findsOneWidget);
    expect(tester.getRect(emptyUpdatesCard).width, expectedWidth);
    semantics.dispose();
  });

  testWidgets('keeps filters beside the section navigation and the reading action inside the raised-cover card', (
    WidgetTester tester,
  ) async {
    await _setViewport(tester, const Size(390, 844));
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    final Rect headingRow = tester.getRect(find.byKey(const Key('library-list-heading-row')));
    final Rect filters = tester.getRect(find.byKey(const Key('library-status-filter-bar')));
    final Rect sectionNavigation = tester.getRect(find.byType(LibrarySectionNavigation));
    final Rect continueCover = tester.getRect(find.byType(LibraryBookCover).first);
    final Rect continueAction = tester.getRect(find.byKey(const Key('continue-reading-cta')));

    expect(filters.left, greaterThan(sectionNavigation.right));
    expect(filters.center.dy, closeTo(headingRow.center.dy, 0.1));
    expect(filters.right, closeTo(headingRow.right, 0.1));
    expect(continueAction.bottom, lessThan(continueCover.bottom));
  });

  testWidgets('raises the cover beyond the shorter card and keeps a long title to one line', (WidgetTester tester) async {
    await _setViewport(tester, const Size(390, 844));
    const String longTitle = '这是一本足够长到需要在极窄空间里自动缩小并最终省略的继续阅读书籍标题';
    final data = LibraryHomeViewData(
      isPresentationFixture: true,
      continueReading: const LibraryContinueReadingViewData(
        bookId: 'long-title',
        title: longTitle,
        chapter: '第999章 不应显示',
        lastReadLabel: '上次阅读 不应显示',
        progress: 0.72,
        coverVariant: LibraryCoverVariant.dusk,
      ),
      books: const <LibraryBookListItemViewData>[],
    );
    await tester.pumpWidget(_host(data: data));
    await tester.pumpAndSettle();

    final Rect surface = tester.getRect(find.byKey(const Key('continue-reading-surface')));
    final Rect cover = tester.getRect(find.byType(LibraryBookCover).first);
    final Text title = tester.widget<Text>(
      find.byWidgetPredicate((Widget widget) => widget is Text && widget.data == longTitle && widget.maxLines == 1),
    );

    expect(surface.height, AppSpacing.continueReadingCardHeight);
    expect(cover.height, greaterThan(surface.height));
    expect(cover.top, lessThan(surface.top));
    expect(cover.bottom, greaterThan(surface.bottom));
    expect(cover.left, lessThan(surface.left));
    expect(find.text('继续阅读'), findsOneWidget);
    expect(find.text('阅读记录'), findsNothing);
    expect(find.text('第999章 不应显示'), findsNothing);
    expect(find.text('上次阅读 不应显示'), findsNothing);
    expect(title.maxLines, 1);
    expect(title.overflow, TextOverflow.ellipsis);
    expect(title.style?.fontSize, lessThan(AppTypography.sectionTitle));
  });

  testWidgets('aligns compact row metadata with the cover and stacks the trailing controls', (WidgetTester tester) async {
    await _setViewport(tester, const Size(390, 844));
    await tester.pumpWidget(_host(callbacks: LibraryHomeCallbacks(onDeleteBook: (_) async {})));
    await tester.pumpAndSettle();

    final Finder firstCover = find.byType(LibraryBookCover).at(1);
    final Finder firstTile = find.byType(LibraryBookListItem).first;
    final Finder firstMetadataTag = find.byType(LibraryMetadataTag).first;
    final Finder firstSwipeActions = find.byType(LibraryBookSwipeActions).first;
    final Finder firstUnreadDot = find.byWidgetPredicate((Widget widget) => widget is Semantics && widget.properties.label == '有更新').first;
    final Finder firstUpdatedLabel = find.text('1小时前');

    final Rect cover = tester.getRect(firstCover);
    final Rect tile = tester.getRect(firstTile);
    final Rect tag = tester.getRect(firstMetadataTag);
    final Rect swipeActions = tester.getRect(firstSwipeActions);
    final Rect unreadDot = tester.getRect(firstUnreadDot);
    final Rect updatedLabel = tester.getRect(firstUpdatedLabel);

    expect(tag.height, AppSpacing.metadataTagHeight);
    expect((cover.bottom - tag.bottom).abs(), lessThanOrEqualTo(4));
    expect(tile.height, closeTo(cover.height + AppSpacing.bookListVerticalPadding * 2, 0.1));
    expect(updatedLabel.right, lessThanOrEqualTo(swipeActions.right));
    expect(swipeActions.width, greaterThan(AppSpacing.minimumTouchTarget));
    expect(unreadDot.right, lessThanOrEqualTo(swipeActions.right));
    expect(updatedLabel.center.dy, closeTo(unreadDot.center.dy, 2));
  });

  testWidgets('renders the hierarchy in the temporary light-only mode', (WidgetTester tester) async {
    await tester.pumpWidget(_host(themeMode: ThemeMode.light));
    await tester.pumpAndSettle();
    BuildContext context = tester.element(find.byType(LibraryHomeShell));
    expect(Theme.of(context).brightness, Brightness.light);
    expect(Theme.of(context).textTheme.bodyMedium?.fontFamily, 'packages/novel_reader_ui/MiSans');
    expect(find.byKey(const Key('continue-reading-cta')), findsOneWidget);
  });

  testWidgets('keyboard traversal activates the first top-bar action', (WidgetTester tester) async {
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

  testWidgets('desktop scrollbar shares the attached list controller during mouse hover', (WidgetTester tester) async {
    await _setViewport(tester, const Size(656, 1129));
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    final Scrollbar scrollbar = tester.widget<Scrollbar>(find.byType(Scrollbar));
    final CustomScrollView list = tester.widget<CustomScrollView>(find.byKey(const Key('library-home-content')));
    expect(scrollbar.controller, same(list.controller));
    expect(list.primary, isFalse);

    final TestGesture mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(650, 400));
    await mouse.moveTo(const Offset(650, 400));
    await tester.pump(const Duration(milliseconds: 250));

    expect(tester.takeException(), isNull);
    await mouse.removePointer(location: const Offset(650, 400));
  });

  testWidgets('lazily builds a long bookshelf and reaches later rows on scroll', (WidgetTester tester) async {
    await _setViewport(tester, const Size(390, 844));
    final data = _largeLibraryHomeData(100);
    await tester.pumpWidget(_host(data: data));
    await tester.pumpAndSettle();

    expect(find.byType(LibraryBookListItem).evaluate().length, lessThan(data.books.length));
    final lastBook = find.byWidgetPredicate((Widget widget) => widget is LibraryBookListItem && widget.data.id == 'performance-book-99');
    expect(lastBook, findsNothing);

    await tester.dragUntilVisible(lastBook, find.byKey(const Key('library-home-content')), const Offset(0, -420));
    expect(lastBook, findsOneWidget);
  });
}

Widget _host({
  ThemeMode themeMode = ThemeMode.light,
  LibraryHomeCallbacks callbacks = const LibraryHomeCallbacks(),
  VoidCallback? onToggleTheme,
  LibraryHomeViewData? data,
  String? preparingBookId,
  bool disableAnimations = false,
}) {
  return MaterialApp(
    theme: AppTheme.light(),
    darkTheme: AppTheme.dark(),
    themeMode: themeMode,
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: disableAnimations),
      child: LibraryHomeShell(
        data: data ?? LibraryHomeFixtures.preview,
        callbacks: callbacks,
        isRefreshing: false,
        onRefresh: () async {},
        onToggleTheme: onToggleTheme,
        preparingBookId: preparingBookId,
      ),
    ),
  );
}

LibraryHomeViewData _largeLibraryHomeData(int count) => LibraryHomeViewData(
  isPresentationFixture: true,
  continueReading: null,
  books: List<LibraryBookListItemViewData>.generate(
    count,
    (int index) => LibraryBookListItemViewData(
      id: 'performance-book-$index',
      title: '性能测试书 $index',
      coverVariant: LibraryCoverVariant.values[index % LibraryCoverVariant.values.length],
      status: LibraryBookStatus.local,
    ),
  ),
);

Future<void> _setViewport(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pump();
}

LibraryHomeViewData _asyncCoverLibraryHomeData() {
  final requests = List<BookCoverRequest>.generate(
    3,
    (int index) => BookCoverRequest(
      pluginId: 'cover-source',
      pluginVersion: '1.0.0',
      remoteContentId: 'book-$index',
      coverUrl: Uri.parse('https://example.com/book-$index.png'),
    ),
  );
  return LibraryHomeViewData(
    isPresentationFixture: false,
    continueReading: LibraryContinueReadingViewData(
      bookId: 'book-0',
      title: '继续阅读测试',
      chapter: '第1章',
      progress: 0.5,
      lastReadLabel: '刚刚',
      coverVariant: LibraryCoverVariant.dusk,
      coverRequest: requests[0],
    ),
    books: <LibraryBookListItemViewData>[
      LibraryBookListItemViewData(
        id: 'book-1',
        title: '连载测试',
        coverVariant: LibraryCoverVariant.dawn,
        status: LibraryBookStatus.ongoing,
        coverRequest: requests[1],
      ),
      LibraryBookListItemViewData(
        id: 'book-2',
        title: '完结测试',
        coverVariant: LibraryCoverVariant.ocean,
        status: LibraryBookStatus.completed,
        coverRequest: requests[2],
      ),
    ],
  );
}

final class _CountingBookCoverBytesLoader implements BookCoverBytesLoader {
  final Map<BookCoverRequest, int> loadCounts = <BookCoverRequest, int>{};

  @override
  Future<List<int>?> resolve(BookCoverRequest request) async {
    loadCounts.update(request, (int count) => count + 1, ifAbsent: () => 1);
    return base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=');
  }
}
