/// Library home shell structure, shelf modes, and refresh behavior.
part of 'library_home_shell_test.dart';

void _registerLibraryHomeShellBasics() {
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
    expect(tester.widget<Scaffold>(find.byType(Scaffold)).extendBody, isTrue);
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
    expect(tester.widget<ColoredBox>(find.byKey(const Key('library-home-top-backdrop'))), isA<ColoredBox>());
    final LibraryBookCover backdropCover = tester.widget<LibraryBookCover>(find.byKey(const Key('library-home-top-backdrop-cover')));
    expect(backdropCover.alignment, Alignment.center);
    expect(backdropCover.fit, BoxFit.cover);
    expect(backdropCover.showLetterboxBackground, isFalse);
    expect(backdropCover.isBlurred, isFalse);
    expect(backdropCover.clipToBounds, isFalse);
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

  testWidgets('card mode can place title and author inside the cover', (WidgetTester tester) async {
    await tester.pumpWidget(
      _host(initialLayoutMode: LibraryHomeLayoutMode.card, initialCoverMetadataMode: LibraryHomeCoverMetadataMode.insideCover),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('library-grid-book-overlay-title-fixture-lord-of-mysteries')), findsOneWidget);
    expect(find.byKey(const Key('library-grid-book-overlay-subtitle-fixture-lord-of-mysteries')), findsOneWidget);
  });

  testWidgets('card metadata mode follows the latest app-owned setting', (WidgetTester tester) async {
    final ValueNotifier<LibraryHomeCoverMetadataMode> metadataMode = ValueNotifier<LibraryHomeCoverMetadataMode>(
      LibraryHomeCoverMetadataMode.insideCover,
    );
    addTearDown(metadataMode.dispose);
    await tester.pumpWidget(_host(initialLayoutMode: LibraryHomeLayoutMode.card, coverMetadataModeListenable: metadataMode));
    await tester.pumpAndSettle();

    expect(tester.widget<LibraryBookSliverGrid>(find.byType(LibraryBookSliverGrid)).metadataMode, LibraryHomeCoverMetadataMode.insideCover);

    metadataMode.value = LibraryHomeCoverMetadataMode.belowCover;
    await tester.pumpAndSettle();

    expect(tester.widget<LibraryBookSliverGrid>(find.byType(LibraryBookSliverGrid)).metadataMode, LibraryHomeCoverMetadataMode.belowCover);
  });

  testWidgets('card menu stays subtle until hover or expansion', (WidgetTester tester) async {
    await tester.pumpWidget(
      _host(
        initialLayoutMode: LibraryHomeLayoutMode.card,
        callbacks: LibraryHomeCallbacks(onSetBookPrivate: (_) async {}),
      ),
    );
    await tester.pumpAndSettle();

    final Finder surface = find.byKey(const Key('library-grid-book-menu-surface-fixture-lord-of-mysteries'));
    BoxDecoration decoration() => tester.widget<AnimatedContainer>(surface).decoration! as BoxDecoration;
    double iconOpacity() => tester.widget<AnimatedOpacity>(find.descendant(of: surface, matching: find.byType(AnimatedOpacity))).opacity;

    final BoxDecoration defaultDecoration = decoration();
    expect(defaultDecoration.boxShadow, isEmpty);
    expect(iconOpacity(), 0.68);

    final TestGesture mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(surface));
    await tester.pump(AppMotion.micro);

    final BoxDecoration hoveredDecoration = decoration();
    expect(hoveredDecoration.color!.a, greaterThan(defaultDecoration.color!.a));
    expect(hoveredDecoration.boxShadow, isNotEmpty);
    expect(iconOpacity(), 1);

    await tester.tap(surface);
    await tester.pumpAndSettle();
    await mouse.moveTo(Offset.zero);
    await tester.pump(AppMotion.micro);

    expect(find.byKey(const Key('library-grid-book-action-fixture-lord-of-mysteries-set-private')), findsOneWidget);
    expect(decoration().boxShadow, isNotEmpty);
    expect(iconOpacity(), 1);
    await mouse.removePointer();
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
    expect(find.textContaining('确定要从书架移除'), findsOneWidget);
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

    await tester.tap(find.text('书架'));
    await tester.pumpAndSettle();
    await _openHomeBookMenu(tester);
    await tester.tap(find.text('刷新'));
    await tester.pumpAndSettle();

    expect(refreshedBook?.id, 'fixture-lord-of-mysteries');
    expect(find.text('《诡秘之主》已刷新'), findsOneWidget);
  });

  testWidgets('offers a manual shelf refresh from the top-right more menu', (WidgetTester tester) async {
    var refreshCount = 0;
    await tester.pumpWidget(
      _host(
        onRefresh: () async {
          refreshCount++;
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('刷新书架'));
    await tester.pumpAndSettle();

    expect(refreshCount, 1);
  });

  testWidgets('uses the manual shelf refresh callback for mobile pull-to-refresh', (WidgetTester tester) async {
    var refreshCount = 0;
    await tester.pumpWidget(
      _host(
        onRefresh: () async {
          refreshCount++;
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.drag(find.byKey(const Key('library-home-content')), const Offset(0, 420));
    await tester.pumpAndSettle();

    expect(refreshCount, 1);
  });

  testWidgets('shows a copyable modal with the original reason when bookshelf refresh fails', (WidgetTester tester) async {
    await tester.pumpWidget(
      _host(
        callbacks: LibraryHomeCallbacks(
          onRefreshBook: (LibraryBookListItemViewData book) => Future<void>.error(StateError('source returned HTTP 503')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('书架'));
    await tester.pumpAndSettle();
    await _openHomeBookMenu(tester);
    await tester.tap(find.text('刷新'));
    await tester.pump();
    await tester.pump(AppMotion.destinationTransition);

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('刷新书籍失败'), findsOneWidget);
    expect(find.text('Bad state: source returned HTTP 503'), findsOneWidget);
    expect(find.byKey(const Key('app-operation-error-copy')), findsOneWidget);
    expect(find.text('刷新书籍失败，请稍后重试。'), findsNothing);
  });

  testWidgets('offers cover blur from the bookshelf more menu', (WidgetTester tester) async {
    LibraryBookListItemViewData? toggledBook;
    await tester.pumpWidget(
      _host(
        callbacks: LibraryHomeCallbacks(
          onToggleBookCoverBlur: (LibraryBookListItemViewData book) async {
            toggledBook = book;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('书架'));
    await tester.pumpAndSettle();
    final LibraryBookSliverList shelfList = tester.widget<LibraryBookSliverList>(find.byType(LibraryBookSliverList));
    expect(shelfList.presentation, same(LibraryBookListPresentation.shelf));
    expect(shelfList.actions.map((action) => action.id), contains('toggle-cover-blur'));
    await _openHomeBookMenu(tester);
    expect(find.text('模糊封面'), findsOneWidget);
    await tester.tap(find.text('模糊封面'));
    await tester.pumpAndSettle();

    expect(toggledBook?.id, 'fixture-lord-of-mysteries');
    expect(find.text('已模糊《诡秘之主》的封面'), findsOneWidget);
  });

  testWidgets('renders a blurred cover when the shelf item is marked blurred', (WidgetTester tester) async {
    final data = LibraryHomeViewData(
      isPresentationFixture: true,
      continueReading: null,
      books: <LibraryBookListItemViewData>[
        LibraryBookListItemViewData(
          id: 'blurred-cover-book',
          title: '隐私封面',
          coverVariant: LibraryCoverVariant.dusk,
          coverAssetPath: 'assets/fixtures/home_covers/lord_of_mysteries_small.png',
          status: LibraryBookStatus.local,
          isCoverBlurred: true,
        ),
      ],
    );
    await tester.pumpWidget(_host(data: data));
    await tester.pumpAndSettle();

    final Finder cover = find.byType(LibraryBookCover);
    expect(find.descendant(of: cover, matching: find.byType(ImageFiltered)), findsOneWidget);
  });

  testWidgets('shows a cover refresh animation until the bookshelf refresh completes', (WidgetTester tester) async {
    final Completer<void> refreshCompleter = Completer<void>();
    var refreshRequested = false;
    await tester.pumpWidget(
      _host(
        callbacks: LibraryHomeCallbacks(
          onRefreshBook: (LibraryBookListItemViewData book) {
            refreshRequested = true;
            return refreshCompleter.future;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('书架'));
    await tester.pumpAndSettle();
    await _openHomeBookMenu(tester);
    await tester.tap(find.text('刷新'));
    await tester.pump(AppMotion.destinationTransition);

    expect(refreshRequested, isTrue);
    expect(find.byWidgetPredicate((Widget widget) => widget is LibraryBookListItem && widget.isRefreshing), findsOneWidget);
    final Finder refreshLabel = find.byWidgetPredicate((Widget widget) => widget is Semantics && widget.properties.label == '诡秘之主 的封面刷新中');
    expect(refreshLabel, findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsWidgets);

    refreshCompleter.complete();
    await tester.pumpAndSettle();

    expect(refreshLabel, findsNothing);
  });
}
