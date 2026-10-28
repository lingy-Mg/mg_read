/// Library home shell privacy, navigation, and first-run actions.
part of 'library_home_shell_test.dart';

void _registerLibraryHomeShellActions() {
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

  testWidgets('renders the first-run welcome guide without preview data', (WidgetTester tester) async {
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
    expect(find.text('欢迎来到 MgRead'), findsOneWidget);
    expect(find.text('从一本书开始，\n发现更大的世界'), findsOneWidget);
    expect(find.text('三步开启阅读'), findsOneWidget);
    expect(find.text('添加数据源'), findsOneWidget);
    expect(find.text('发现作品'), findsOneWidget);
    expect(find.text('开始阅读'), findsOneWidget);
    expect(find.text('去发现好书'), findsOneWidget);
    expect(find.text('管理数据源'), findsOneWidget);
    expect(find.byKey(const Key('first-run-discover-cta')), findsOneWidget);
    expect(find.textContaining('界面预览'), findsNothing);
    expect(find.byKey(const Key('library-first-run-welcome')), findsOneWidget);
  });

  testWidgets('keeps the first-run section close to the top actions', (WidgetTester tester) async {
    await _setViewport(tester, const Size(390, 900));
    await tester.pumpWidget(_host(data: LibraryHomeViewData.empty(), topInset: 24));
    await tester.pumpAndSettle();

    final Rect topBar = tester.getRect(find.byType(LibraryHomeTopBar));
    final Rect heading = tester.getRect(find.byKey(const Key('library-list-heading-row')));
    expect(topBar.top, 16);
    expect(heading.top - topBar.bottom, AppSpacing.comfortable);
  });
}
