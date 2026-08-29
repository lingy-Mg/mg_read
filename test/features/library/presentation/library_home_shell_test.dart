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
import 'package:mg_read/features/library/presentation/widgets/library_book_grid.dart';
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
  testWidgets('extends the home artwork behind the system inset while keeping the header below it', (WidgetTester tester) async {
    await tester.pumpWidget(_host(topInset: 24));
    await tester.pumpAndSettle();

    expect(tester.getRect(find.byKey(const Key('library-home-top-backdrop'))).top, 0);
    final Rect topBar = tester.getRect(find.byType(LibraryHomeTopBar));
    final Rect cover = tester.getRect(find.byKey(const Key('continue-reading-flat-cover')));
    expect(topBar.top, 24);
    expect(cover.top, topBar.top);
  });

  testWidgets('renders the home hierarchy with progress and book semantics', (WidgetTester tester) async {
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    expect(find.descendant(of: find.byType(LibraryHomeTopBar), matching: find.text('首页')), findsNothing);
    expect(find.textContaining('界面预览'), findsNothing);
    expect(find.byKey(const Key('continue-reading-cta')), findsOneWidget);
    expect(find.text('诡秘之主'), findsAtLeastNWidgets(2));
    expect(find.text('最近阅读'), findsOneWidget);
    expect(find.text('管理我的数据源'), findsNothing);
    expect(find.byType(AppBottomNavigation), findsOneWidget);
    expect(find.byWidgetPredicate((Widget widget) => widget is Semantics && widget.properties.label == '阅读进度 72%'), findsOneWidget);
    expect(
      find.byWidgetPredicate((Widget widget) => widget is Semantics && widget.properties.label == '诡秘之主，第1268章 不可名状的低语，1小时前，有更新'),
      findsOneWidget,
    );
  });

  testWidgets('uses the current cover behind the complete top area', (WidgetTester tester) async {
    await _setViewport(tester, const Size(390, 844));
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    final Rect backdrop = tester.getRect(find.byKey(const Key('library-home-top-backdrop')));
    final Rect topBar = tester.getRect(find.byType(LibraryHomeTopBar));
    final Rect readingSurface = tester.getRect(find.byKey(const Key('continue-reading-surface')));

    expect(find.byKey(const Key('library-home-top-backdrop-cover')), findsOneWidget);
    expect(find.byKey(const Key('library-home-top-bottom-fade')), findsOneWidget);
    expect(find.byKey(const Key('library-home-reading-readability-scrim')), findsOneWidget);
    expect(tester.widget<ClipRect>(find.byKey(const Key('library-home-top-backdrop'))), isA<ClipRect>());
    expect(tester.widget<LibraryBookCover>(find.byKey(const Key('library-home-top-backdrop-cover'))).alignment, Alignment.topCenter);
    expect(backdrop.left, 0);
    expect(backdrop.right, 390);
    expect(backdrop.contains(topBar.topLeft), isTrue);
    expect(backdrop.contains(topBar.bottomRight), isTrue);
    expect(backdrop.contains(readingSurface.topLeft), isTrue);
    expect(backdrop.contains(readingSurface.bottomRight), isTrue);
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
  });

  testWidgets('switches between list and card modes from the top menu', (WidgetTester tester) async {
    final List<LibraryHomeLayoutMode> savedModes = <LibraryHomeLayoutMode>[];
    await tester.pumpWidget(
      _host(
        onLayoutModeChanged: (LibraryHomeLayoutMode mode) async {
          savedModes.add(mode);
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(LibraryBookSliverList), findsOneWidget);
    expect(find.byType(LibraryBookSliverGrid), findsNothing);

    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    expect(find.text('切换为卡片模式'), findsOneWidget);
    await tester.tap(find.text('切换为卡片模式'));
    await tester.pumpAndSettle();

    expect(savedModes, <LibraryHomeLayoutMode>[LibraryHomeLayoutMode.card]);
    expect(find.byType(LibraryBookSliverGrid), findsOneWidget);
    expect(find.byType(LibraryBookSliverList), findsNothing);

    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    expect(find.text('切换为列表模式'), findsOneWidget);
  });

  testWidgets('restores list mode when the card preference cannot be saved', (WidgetTester tester) async {
    await tester.pumpWidget(
      _host(
        onLayoutModeChanged: (LibraryHomeLayoutMode mode) async {
          throw StateError('settings unavailable');
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('切换为卡片模式'));
    await tester.pumpAndSettle();

    expect(find.byType(LibraryBookSliverList), findsOneWidget);
    expect(find.byType(LibraryBookSliverGrid), findsNothing);
    expect(find.text('首页布局偏好保存失败，已恢复原模式。'), findsOneWidget);
  });

  testWidgets('card mode preserves book open, long press, and private actions', (WidgetTester tester) async {
    LibraryBookListItemViewData? openedBook;
    LibraryBookListItemViewData? longPressedBook;
    LibraryBookListItemViewData? privateBook;
    await tester.pumpWidget(
      _host(
        initialLayoutMode: LibraryHomeLayoutMode.card,
        callbacks: LibraryHomeCallbacks(
          onOpenBook: (LibraryBookListItemViewData book) => openedBook = book,
          onBookLongPress: (LibraryBookListItemViewData book) => longPressedBook = book,
          onSetBookPrivate: (LibraryBookListItemViewData book) async {
            privateBook = book;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Finder firstCard = find.byType(LibraryBookGridItem).first;
    await tester.tap(firstCard);
    expect(openedBook?.id, 'fixture-lord-of-mysteries');
    await tester.longPress(firstCard);
    expect(longPressedBook?.id, 'fixture-lord-of-mysteries');

    final Finder cardMenu = find.byKey(const Key('library-grid-book-overflow-menu-fixture-lord-of-mysteries'));
    await tester.tap(cardMenu);
    await tester.pumpAndSettle();
    final Finder gridPrivacy = find.byKey(const Key('library-grid-book-action-fixture-lord-of-mysteries-set-private'));
    await tester.tap(gridPrivacy);
    await tester.pump(AppMotion.destinationTransition);
    await tester.pumpAndSettle();
    expect(privateBook?.id, 'fixture-lord-of-mysteries');
  });

  testWidgets('card mode preserves preparation, filtering, and deletion', (WidgetTester tester) async {
    LibraryBookListItemViewData? deletedBook;
    await _setViewport(tester, const Size(390, 844));
    await tester.pumpWidget(
      _host(
        initialLayoutMode: LibraryHomeLayoutMode.card,
        preparingBookId: 'fixture-heavenly-path',
        callbacks: LibraryHomeCallbacks(
          onDeleteBook: (LibraryBookListItemViewData book) async {
            deletedBook = book;
          },
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byWidgetPredicate(
        (Widget widget) => widget is LibraryBookGridItem && widget.data.id == 'fixture-heavenly-path' && widget.isPreparing,
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('library-filter-completed')));
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate((Widget widget) => widget is LibraryBookGridItem && widget.data.status == LibraryBookStatus.ongoing),
      findsNothing,
    );

    final LibraryBookGridItem completedCard = tester.widget<LibraryBookGridItem>(find.byType(LibraryBookGridItem).first);
    await tester.tap(find.byKey(Key('library-grid-book-overflow-menu-${completedCard.data.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('library-grid-book-action-${completedCard.data.id}-delete')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pump(AppMotion.destinationTransition);
    await tester.pumpAndSettle();
    expect(deletedBook?.id, completedCard.data.id);
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

  testWidgets('offers refresh from the bookshelf more menu', (WidgetTester tester) async {
    LibraryBookListItemViewData? refreshedBook;
    await tester.pumpWidget(
      _host(
        callbacks: LibraryHomeCallbacks(
          onRefreshBook: (LibraryBookListItemViewData book) async {
            refreshedBook = book;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('library-book-overflow-menu-fixture-lord-of-mysteries')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('刷新'));
    await tester.pumpAndSettle();

    expect(refreshedBook?.id, 'fixture-lord-of-mysteries');
    expect(find.text('《诡秘之主》已刷新'), findsOneWidget);
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

  testWidgets('long pressing the home destination reveals privacy mode before opening it', (WidgetTester tester) async {
    var privateShelfOpenCount = 0;
    await tester.pumpWidget(
      _host(
        callbacks: LibraryHomeCallbacks(
          onPrivacyLibraryRequested: () {
            privateShelfOpenCount++;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.longPress(find.byKey(const Key('app-nav-home')));
    await tester.pump();

    expect(find.byKey(const Key('private-library-reveal')), findsOneWidget);
    expect(find.bySemanticsLabel('正在进入隐私模式'), findsOneWidget);
    expect(privateShelfOpenCount, 0);

    await tester.pump(const Duration(milliseconds: 260));
    expect(privateShelfOpenCount, 0);

    await tester.pump(const Duration(milliseconds: 300));
    expect(privateShelfOpenCount, 1);
    expect(find.byKey(const Key('private-library-reveal')), findsOneWidget);

    await tester.pump(AppMotion.destinationTransition);
    await tester.pump();
    expect(find.byKey(const Key('private-library-reveal')), findsNothing);
  });

  testWidgets('reduced motion opens privacy mode immediately on home long press', (WidgetTester tester) async {
    var privateShelfOpenCount = 0;
    await tester.pumpWidget(
      _host(disableAnimations: true, callbacks: LibraryHomeCallbacks(onPrivacyLibraryRequested: () => privateShelfOpenCount++)),
    );
    await tester.pumpAndSettle();

    await tester.longPress(find.byKey(const Key('app-nav-home')));
    await tester.pump();

    expect(privateShelfOpenCount, 1);
    expect(find.byKey(const Key('private-library-reveal')), findsNothing);
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
    expect(find.text('管理我的数据源'), findsNothing);
  });

  testWidgets('uses the compact reference font-size and weight hierarchy', (WidgetTester tester) async {
    await _setViewport(tester, const Size(390, 900));
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    final Text updateTitle = tester.widget<Text>(
      find.descendant(of: find.byType(LibraryBookListItem).first, matching: find.text('诡秘之主')).last,
    );
    final Text selectedSection = tester.widget<Text>(find.text('最近阅读'));
    final Text unselectedSection = tester.widget<Text>(find.text('书架'));
    final Text continueAction = tester.widget<Text>(
      find.descendant(of: find.byKey(const Key('continue-reading-cta')), matching: find.text('继续阅读')),
    );

    expect(updateTitle.style?.fontSize, 16);
    expect(updateTitle.style?.fontWeight, FontWeight.w600);
    expect(selectedSection.style?.fontSize, AppTypography.secondary);
    expect(selectedSection.style?.fontWeight, FontWeight.w600);
    expect(unselectedSection.style?.fontSize, AppTypography.secondary);
    expect(unselectedSection.style?.fontWeight, FontWeight.w400);
    expect(continueAction.style?.fontSize, 16);
    expect(continueAction.style?.fontWeight, FontWeight.w600);
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
          home: LibraryHomeShell(data: data, initialLayoutMode: LibraryHomeLayoutMode.card, isRefreshing: false, onRefresh: () async {}),
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
    final Rect continueCover = tester.getRect(find.byKey(const Key('continue-reading-flat-cover')));
    final Rect continueAction = tester.getRect(find.byKey(const Key('continue-reading-cta')));
    final Rect continueTitle = tester.getRect(
      find.descendant(of: find.byKey(const Key('continue-reading-surface')), matching: find.text('诡秘之主')),
    );

    expect(filters.left, greaterThan(sectionNavigation.right));
    expect(filters.center.dy, closeTo(headingRow.center.dy, 0.1));
    expect(filters.right, closeTo(headingRow.right, 0.1));
    final Rect continueSurface = tester.getRect(find.byKey(const Key('continue-reading-surface')));
    expect(continueSurface.contains(continueCover.topLeft), isTrue);
    expect(continueSurface.contains(continueAction.bottomRight), isTrue);
    expect(continueCover.right, lessThan(continueTitle.left));
    expect(continueCover.right, lessThan(continueAction.left));
    expect(continueAction.center.dx, closeTo((continueCover.right + AppSpacing.comfortable + continueSurface.right) / 2, 0.1));
    expect(tester.widget<FractionallySizedBox>(find.byKey(const Key('continue-reading-cta-progress'))).widthFactor, 0.72);
  });

  testWidgets('keeps the flat cover inside the hero and safely truncates a long title', (WidgetTester tester) async {
    await _setViewport(tester, const Size(390, 844));
    const String longTitle = '这是一本足够长到需要在极窄空间里自动缩小并最终省略的继续阅读书籍标题';
    final data = LibraryHomeViewData(
      isPresentationFixture: true,
      continueReading: const LibraryContinueReadingViewData(
        bookId: 'long-title',
        title: longTitle,
        author: '这是一个足够长到需要省略的作者名',
        description: '这是一段用来验证首页窄屏排版和多行省略的很长作品简介。',
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
    final Finder flatCover = find.byKey(const Key('continue-reading-flat-cover'));
    final Rect cover = tester.getRect(flatCover);
    final Widget readingSurface = tester.widget(find.byKey(const Key('continue-reading-surface')));
    final Text title = tester.widget<Text>(
      find.byWidgetPredicate(
        (Widget widget) =>
            widget is Text && widget.data == longTitle && widget.maxLines == 1 && widget.style?.fontSize == AppTypography.sectionTitle,
      ),
    );

    expect(surface.height, greaterThanOrEqualTo(172));
    expect(readingSurface, isA<SizedBox>());
    expect(cover.height, greaterThan(210));
    expect(surface.contains(cover.topLeft), isTrue);
    expect(cover.bottom, lessThanOrEqualTo(surface.bottom));
    expect(cover.left, closeTo(surface.left, 0.1));
    expect(find.ancestor(of: flatCover, matching: find.byType(RotatedBox)), findsNothing);
    expect(find.text('继续阅读'), findsOneWidget);
    expect(find.text('阅读记录'), findsNothing);
    expect(find.text('第999章 不应显示'), findsNothing);
    expect(find.text('上次阅读 不应显示'), findsNothing);
    expect(find.byKey(const Key('continue-reading-author')), findsOneWidget);
    expect(find.byKey(const Key('continue-reading-description')), findsOneWidget);
    expect(title.maxLines, 1);
    expect(title.overflow, TextOverflow.ellipsis);
    expect(title.style?.fontSize, lessThanOrEqualTo(AppTypography.sectionTitle));
    expect(title.style?.shadows, isNull);
  });

  testWidgets('keeps the hero and one-line controls overflow-free with enlarged text', (WidgetTester tester) async {
    await _setViewport(tester, const Size(390, 844));
    await tester.pumpWidget(_host(textScaler: const TextScaler.linear(1.5)));
    await tester.pumpAndSettle();

    final Rect heading = tester.getRect(find.byKey(const Key('library-list-heading-row')));
    final Rect sections = tester.getRect(find.byType(LibrarySectionNavigation));
    final Rect filters = tester.getRect(find.byKey(const Key('library-status-filter-bar')));
    final Rect hero = tester.getRect(find.byKey(const Key('continue-reading-surface')));
    final Rect cover = tester.getRect(find.byKey(const Key('continue-reading-flat-cover')));

    expect(tester.takeException(), isNull);
    expect(sections.center.dy, closeTo(heading.center.dy, 0.1));
    expect(filters.center.dy, closeTo(heading.center.dy, 0.1));
    expect(cover.bottom, lessThanOrEqualTo(hero.bottom));
    expect(cover.left, closeTo(hero.left, 0.1));
  });

  testWidgets('aligns compact row metadata with the cover and stacks the trailing controls', (WidgetTester tester) async {
    await _setViewport(tester, const Size(390, 844));
    await tester.pumpWidget(_host(callbacks: LibraryHomeCallbacks(onDeleteBook: (_) async {})));
    await tester.pumpAndSettle();

    final Finder firstTile = find.byType(LibraryBookListItem).first;
    final Finder firstCover = find.descendant(of: firstTile, matching: find.byType(LibraryBookCover));
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
  double topInset = 0,
  TextScaler textScaler = TextScaler.noScaling,
  LibraryHomeLayoutMode initialLayoutMode = LibraryHomeLayoutMode.list,
  Future<void> Function(LibraryHomeLayoutMode mode)? onLayoutModeChanged,
}) {
  return MaterialApp(
    theme: AppTheme.light(),
    darkTheme: AppTheme.dark(),
    themeMode: themeMode,
    home: MediaQuery(
      data: MediaQueryData(
        disableAnimations: disableAnimations,
        textScaler: textScaler,
        padding: EdgeInsets.only(top: topInset),
        viewPadding: EdgeInsets.only(top: topInset),
      ),
      child: LibraryHomeShell(
        data: data ?? LibraryHomeFixtures.preview,
        initialLayoutMode: initialLayoutMode,
        onLayoutModeChanged: onLayoutModeChanged,
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
