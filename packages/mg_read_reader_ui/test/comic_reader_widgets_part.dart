/// Comic reader widget chrome, navigation, and session behavior.
part of 'comic_reader_test.dart';

void _registerComicWidgetTests() {
  testWidgets('comic reader exposes stable actions and sends exit observer', (
    WidgetTester tester,
  ) async {
    final observer = _RecordingComicObserver();
    await tester.pumpWidget(
      MaterialApp(
        home: ComicReaderView(
          bookId: 'book',
          dataSource: _FakeComicSource(),
          stateStore: _MemoryComicStateStore(),
          observer: observer,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(observer.firstContentCount, 1);
    expect(observer.firstPresentation?.anchor?.imageId, 'image-1');
    expect(observer.firstPresentation?.cacheHit, isTrue);
    expect(
      find.byKey(const ValueKey<String>('comic-reader-content-surface')),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('漫画图片 1'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('comic-reader-content-surface')),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('comic-reader-back-action')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('comic-reader-add-bookmark')),
      findsOneWidget,
    );
    final Finder primaryBar = find.byKey(
      const ValueKey<String>('comic-reader-primary-top-bar'),
    );
    final Finder sourceStrip = find.byKey(
      const ValueKey<String>('comic-reader-source-strip'),
    );
    expect(sourceStrip, findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('comic-reader-source-name')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('comic-reader-source-url-region')),
      findsOneWidget,
    );
    expect(find.text('测试漫画源'), findsOneWidget);
    expect(find.text('打开原网页'), findsOneWidget);
    expect(
      tester
          .getRect(
            find.byKey(const ValueKey<String>('comic-reader-source-name')),
          )
          .width,
      lessThan(104),
    );
    expect(tester.getRect(sourceStrip).top, tester.getRect(primaryBar).bottom);
    final Material stripMaterial = tester.widget<Material>(
      find.descendant(of: sourceStrip, matching: find.byType(Material)).first,
    );
    expect(stripMaterial.color, const Color(0xFF17191B));
    expect(
      find.byKey(const ValueKey<String>('comic-reader-catalog')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('comic-reader-bookmarks')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('comic-reader-settings')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('comic-reader-back-action')),
    );
    await tester.pump();
    expect(observer.exitCount, 1);
    expect(observer.firstContentCount, 1);
  });

  testWidgets(
    'comic settings expose shared page-turn layout and ratio controls',
    (WidgetTester tester) async {
      final store = _MemoryComicStateStore();
      await tester.pumpWidget(
        MaterialApp(
          home: ComicReaderView(
            bookId: 'book',
            dataSource: _FakeComicSource(),
            stateStore: store,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('comic-reader-content-surface')),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey<String>('comic-reader-settings')),
      );
      await tester.pumpAndSettle();

      expect(find.text('跳转比例'), findsOneWidget);
      expect(find.text('90%'), findsOneWidget);
      expect(find.text('点击翻页方向'), findsOneWidget);
      expect(find.text('上下区域'), findsOneWidget);
      expect(find.text('单手模式'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey<String>('comic-reader-page-turn-fraction')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('50%').last);
      await tester.pumpAndSettle();
      expect(store.preferences?.pageTurnFraction, .5);

      await tester.tap(
        find.byKey(const ValueKey<String>('comic-reader-page-turn-layout')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('左右区域').last);
      await tester.pumpAndSettle();
      expect(store.preferences?.pageTurnLayout, ComicPageTurnLayout.horizontal);

      await tester.tap(find.text('单手模式'));
      await tester.pump();
      expect(store.preferences?.singleHandMode, isTrue);
    },
  );

  testWidgets('comic catalog completes pages and centers the current chapter', (
    WidgetTester tester,
  ) async {
    tester.view
      ..physicalSize = const Size(400, 700)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final source = _PagedComicCatalogSource();
    final controller = ComicReaderController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: ComicReaderView(
          bookId: 'book',
          dataSource: source,
          controller: controller,
          stateStore: _MemoryComicStateStore(
            progress: const ComicReaderProgress(
              chapterId: 'chapter-76',
              imageId: 'image-1',
              chapterIndex: 75,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(controller.snapshot.chapter?.id, 'chapter-76');

    await tester.tap(
      find.byKey(const ValueKey<String>('comic-reader-content-surface')),
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey<String>('comic-reader-catalog')),
    );
    await tester.pumpAndSettle();

    expect(source.catalogCursors, <String?>[null, '50', '100']);
    expect(find.text('共 120 话'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('comic-reader-catalog-scrollbar')),
      findsOneWidget,
    );
    final ScrollableState catalogScrollable = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byKey(
              const ValueKey<String>('comic-reader-catalog-scrollbar'),
            ),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(catalogScrollable.position.pixels, greaterThan(0));
    final Finder currentChapter = find.byKey(
      const ValueKey<String>('comic-reader-catalog-chapter-chapter-76'),
    );
    expect(currentChapter, findsOneWidget);
    expect(tester.widget<ListTile>(currentChapter).selected, isTrue);
    expect(
      find.descendant(
        of: currentChapter,
        matching: find.text('1 张 · 未读 · 已缓存 1/1'),
      ),
      findsOneWidget,
    );
    final Rect chapterRect = tester.getRect(currentChapter);
    expect(chapterRect.top, greaterThan(100));
    expect(chapterRect.bottom, lessThan(700));
  });

  testWidgets('tapping the comic reader middle area closes visible controls', (
    WidgetTester tester,
  ) async {
    final controller = ComicReaderController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ComicReaderView(
          bookId: 'book',
          dataSource: _FakeComicSource(),
          stateStore: _MemoryComicStateStore(),
          controller: controller,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('comic-reader-content-surface')),
    );
    await tester.pump();
    expect(controller.snapshot.controlsVisible, isTrue);
    final regionWithControls = tester
        .widget<AnnotatedRegion<SystemUiOverlayStyle>>(
          find.byType(AnnotatedRegion<SystemUiOverlayStyle>),
        );
    expect(regionWithControls.value.statusBarColor, const Color(0xFF17191B));
    expect(
      regionWithControls.value.systemNavigationBarColor,
      const Color(0xFF17191B),
    );
    expect(
      find.byKey(
        const ValueKey<String>('comic-reader-controls-interaction-lock'),
      ),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(
        const ValueKey<String>('comic-reader-controls-interaction-lock'),
      ),
    );
    await tester.pump();
    expect(controller.snapshot.controlsVisible, isFalse);
    final regionWithoutControls = tester
        .widget<AnnotatedRegion<SystemUiOverlayStyle>>(
          find.byType(AnnotatedRegion<SystemUiOverlayStyle>),
        );
    expect(regionWithoutControls.value.statusBarColor, Colors.transparent);
    expect(
      regionWithoutControls.value.systemNavigationBarColor,
      Colors.transparent,
    );
    expect(
      find.byKey(
        const ValueKey<String>('comic-reader-controls-interaction-lock'),
      ),
      findsNothing,
    );
  });

  testWidgets(
    'comic edge taps turn pages, center opens controls, and drag still scrolls',
    (WidgetTester tester) async {
      tester.view
        ..physicalSize = const Size(400, 600)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = ComicReaderController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: ComicReaderView(
            bookId: 'book',
            dataSource: _LongComicSource(),
            stateStore: _MemoryComicStateStore(),
            controller: controller,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final Finder surface = find.byKey(
        const ValueKey<String>('comic-reader-content-surface'),
      );
      final Rect surfaceRect = tester.getRect(surface);
      final ScrollPosition position = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;

      await tester.tapAt(
        Offset(surfaceRect.center.dx, surfaceRect.bottom - 24),
      );
      for (var frame = 0; frame < 20; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final double afterDownTap = position.pixels;
      expect(afterDownTap, greaterThan(0));
      expect(controller.snapshot.controlsVisible, isFalse);

      await tester.tapAt(Offset(surfaceRect.center.dx, surfaceRect.top + 24));
      for (var frame = 0; frame < 20; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(position.pixels, lessThan(afterDownTap));
      expect(controller.snapshot.controlsVisible, isFalse);

      await tester.tapAt(surfaceRect.center);
      await tester.pump();
      expect(controller.snapshot.controlsVisible, isTrue);
      await tester.tap(
        find.byKey(
          const ValueKey<String>('comic-reader-controls-interaction-lock'),
        ),
      );
      await tester.pump();

      final double beforeDrag = position.pixels;
      await tester.drag(surface, const Offset(0, -180));
      await tester.pumpAndSettle();
      expect(position.pixels, greaterThan(beforeDrag));
      expect(controller.snapshot.controlsVisible, isFalse);
    },
  );

  testWidgets('next comic chapter responds while chapter metadata resolves', (
    WidgetTester tester,
  ) async {
    final source = _DelayedChapterInfoComicSource();
    final controller = ComicReaderController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ComicReaderView(
          bookId: 'book',
          dataSource: source,
          stateStore: _MemoryComicStateStore(),
          controller: controller,
        ),
      ),
    );
    for (
      var frame = 0;
      frame < 30 && controller.snapshot.chapter?.id != 'chapter-1';
      frame++
    ) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(controller.snapshot.chapter?.id, 'chapter-1');

    unawaited(controller.nextChapter());
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('comic-reader-chapter-loading')),
      findsOneWidget,
    );
    expect(controller.snapshot.isLoading, isTrue);

    source.completeNextChapter();
    for (
      var frame = 0;
      frame < 30 && controller.snapshot.chapter?.id != 'chapter-2';
      frame++
    ) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(controller.snapshot.chapter?.id, 'chapter-2');
    expect(controller.snapshot.isLoading, isFalse);
  });

  testWidgets('retrying a failed next chapter retries that chapter', (
    WidgetTester tester,
  ) async {
    final source = _FailingNextChapterComicSource();
    final controller = ComicReaderController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ComicReaderView(
          bookId: 'book',
          dataSource: source,
          stateStore: _MemoryComicStateStore(),
          controller: controller,
        ),
      ),
    );

    for (var frame = 0; frame < 60 && source.chapter2Calls < 1; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(source.chapter2Calls, greaterThanOrEqualTo(1));
    expect(controller.snapshot.chapter?.id, 'chapter-1');

    unawaited(controller.nextChapter());
    for (
      var frame = 0;
      frame < 60 && (source.chapter2Calls < 2 || controller.snapshot.isLoading);
      frame++
    ) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(source.chapter2Calls, greaterThanOrEqualTo(2));
    expect(controller.snapshot.chapter?.id, 'chapter-1');
    expect(controller.snapshot.failure, isNotNull);
    expect(controller.snapshot.isLoading, isFalse);

    await controller.refreshCurrentChapter();
    for (
      var frame = 0;
      frame < 60 && controller.snapshot.chapter?.id != 'chapter-2';
      frame++
    ) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(source.chapter2Calls, 3);
    expect(controller.snapshot.chapter?.id, 'chapter-2');
    expect(controller.snapshot.failure, isNull);
  });

  testWidgets(
    'opening a saved middle chapter only stitches following chapters',
    (WidgetTester tester) async {
      tester.view
        ..physicalSize = const Size(400, 600)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final source = _TrackedAdjacentComicSource();
      final controller = ComicReaderController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: ComicReaderView(
            bookId: 'book',
            dataSource: source,
            controller: controller,
            stateStore: _MemoryComicStateStore(
              progress: const ComicReaderProgress(
                chapterId: 'chapter-2',
                imageId: 'chapter-2-image-1',
                chapterIndex: 1,
              ),
            ),
          ),
        ),
      );
      for (int frame = 0; frame < 12; frame++) {
        await tester.pump(const Duration(milliseconds: 25));
      }
      expect(
        source.requestedChapters,
        containsAll(<String>['chapter-2', 'chapter-3']),
      );
      expect(source.requestedChapters, isNot(contains('chapter-1')));

      final ScrollPosition position = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      position.jumpTo(position.maxScrollExtent - 200);
      await tester.pump(const Duration(milliseconds: 100));
      expect(source.requestedChapters, contains('chapter-4'));

      position.jumpTo(0);
      await tester.pump();
      position.jumpTo(1);
      await tester.pump(const Duration(milliseconds: 100));
      expect(controller.snapshot.chapter?.id, 'chapter-2');

      position.jumpTo(position.maxScrollExtent - 1200);
      await tester.pump();
      position.jumpTo(position.pixels + 1);
      await tester.pump(const Duration(milliseconds: 100));
      expect(controller.snapshot.chapter?.id, 'chapter-4');

      position.jumpTo(position.maxScrollExtent - 200);
      await tester.pump(const Duration(milliseconds: 100));
      expect(source.requestedChapters, contains('chapter-5'));

      position.jumpTo(0);
      await tester.pump();
      position.jumpTo(1);
      await tester.pump(const Duration(milliseconds: 100));
      expect(controller.snapshot.chapter?.id, 'chapter-3');
    },
  );
}
