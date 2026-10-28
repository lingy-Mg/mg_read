/// Library home shell layout, semantics, and scrolling behavior.
part of 'library_home_shell_test.dart';

void _registerLibraryHomeShellLayout() {
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
    expect(continueAction.style?.fontSize, AppTypography.action);
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
    final coverImages = tester.widgetList<Image>(find.byType(Image)).where((image) {
      final provider = image.image;
      return provider is MemoryImage || (provider is ResizeImage && provider.imageProvider is MemoryImage);
    });
    expect(coverImages, isNotEmpty);
    expect(coverImages, everyElement(isA<Image>().having((Image image) => image.gaplessPlayback, 'gaplessPlayback', isTrue)));

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

  testWidgets('adapts the home content to the full available viewport width', (WidgetTester tester) async {
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

    await _setViewport(tester, const Size(1600, 900));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('library-mobile-layout')), findsOneWidget);
    final Rect wideLayout = tester.getRect(find.byKey(const Key('library-mobile-layout')));
    expect(wideLayout.width, AppSpacing.readableContentMaxWidth - AppSpacing.widePagePadding * 2);
    expect(wideLayout.center.dx, closeTo(800, 0.1));
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
    final Finder welcomeCard = find.byKey(const Key('library-first-run-welcome'));
    expect(welcomeCard, findsOneWidget);
    expect(tester.getRect(welcomeCard).width, expectedWidth);
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
    expect(continueAction.bottom, closeTo(continueCover.bottom - AppSpacing.compact / 2, 0.1));
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
    final Text title = tester.widget<Text>(find.byKey(const Key('continue-reading-title')));

    expect(surface.height, greaterThanOrEqualTo(172));
    expect(readingSurface, isA<SizedBox>());
    expect(cover.height, inInclusiveRange(180, 210));
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
    expect(title.data, longTitle);
    expect(title.maxLines, 2);
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

  testWidgets('renders the hierarchy with the shared light theme', (WidgetTester tester) async {
    await tester.pumpWidget(_host(themeMode: ThemeMode.light));
    await tester.pumpAndSettle();
    BuildContext context = tester.element(find.byType(LibraryHomeShell));
    expect(Theme.of(context).brightness, Brightness.light);
    expect(Theme.of(context).textTheme.bodyMedium?.fontFamily, 'packages/novel_reader_ui/MiSans');
    expect(find.byKey(const Key('continue-reading-cta')), findsOneWidget);
  });

  testWidgets('keyboard traversal activates the first top-bar action', (WidgetTester tester) async {
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('library-top-overflow-menu')), findsOneWidget);
    expect(find.text('刷新书架'), findsOneWidget);
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
  LibraryHomeCoverMetadataMode initialCoverMetadataMode = LibraryHomeCoverMetadataMode.belowCover,
  ValueNotifier<LibraryHomeCoverMetadataMode>? coverMetadataModeListenable,
  Future<void> Function()? onRefresh,
}) {
  Widget buildShell(LibraryHomeCoverMetadataMode coverMetadataMode) => MediaQuery(
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
      initialCoverMetadataMode: coverMetadataMode,
      callbacks: callbacks,
      isRefreshing: false,
      onRefresh: onRefresh ?? () async {},
      onToggleTheme: onToggleTheme,
      preparingBookId: preparingBookId,
    ),
  );

  return MaterialApp(
    theme: AppTheme.light(),
    darkTheme: AppTheme.dark(),
    themeMode: themeMode,
    home: coverMetadataModeListenable == null
        ? buildShell(initialCoverMetadataMode)
        : ValueListenableBuilder<LibraryHomeCoverMetadataMode>(
            valueListenable: coverMetadataModeListenable,
            builder: (BuildContext context, LibraryHomeCoverMetadataMode coverMetadataMode, Widget? child) => buildShell(coverMetadataMode),
          ),
  );
}
