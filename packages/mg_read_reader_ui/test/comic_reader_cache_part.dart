/// Comic image cache and chapter preloading behavior.
part of 'comic_reader_test.dart';

void _registerComicCacheTests() {
  testWidgets('owns transparent system bars while the comic chapter loads', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ComicReaderView(
          bookId: 'system-ui-book',
          dataSource: _FakeComicSource(),
          stateStore: _MemoryComicStateStore(),
        ),
      ),
    );

    final region = tester.widget<AnnotatedRegion<SystemUiOverlayStyle>>(
      find.byType(AnnotatedRegion<SystemUiOverlayStyle>),
    );
    expect(region.value.statusBarColor, Colors.transparent);
    expect(region.value.statusBarIconBrightness, Brightness.light);
    expect(region.value.systemNavigationBarColor, Colors.transparent);
    expect(region.value.systemStatusBarContrastEnforced, isFalse);
  });

  testWidgets('uses a light chapter header for comic chapter transitions', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ComicReaderView(
          bookId: 'book',
          dataSource: _FakeComicSource(),
          stateStore: _MemoryComicStateStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final ScrollPosition position = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    position.jumpTo(0);
    await tester.pump();

    final List<ColoredBox> headers = tester
        .widgetList<ColoredBox>(
          find.byKey(const ValueKey<String>('comic-reader-chapter-header')),
        )
        .toList();
    final List<Text> titles = tester
        .widgetList<Text>(
          find.descendant(
            of: find.byKey(
              const ValueKey<String>('comic-reader-chapter-header'),
            ),
            matching: find.byType(Text),
          ),
        )
        .toList();

    expect(headers, isNotEmpty);
    expect(
      headers.every((ColoredBox header) => header.color == Colors.white),
      isTrue,
    );
    expect(titles, isNotEmpty);
    expect(
      titles.every(
        (Text title) => title.style?.color == const Color(0xFF242424),
      ),
      isTrue,
    );
  });

  test('comic progress is anchored by chapter, image and fraction', () {
    const progress = ComicReaderProgress(
      chapterId: 'chapter-1',
      imageId: 'image-2',
      imageFraction: .45,
    );
    expect(
      progress.copyWith(imageFraction: .9),
      equals(
        const ComicReaderProgress(
          chapterId: 'chapter-1',
          imageId: 'image-2',
          imageFraction: .9,
        ),
      ),
    );
    expect(progress.chapterId, 'chapter-1');
    expect(progress.imageId, 'image-2');
  });

  test('comic book metadata keeps an optional source link', () {
    final Uri sourceUrl = Uri.parse('https://source.example/comics/book');
    final info = ComicBookInfo(
      id: 'book',
      title: '漫画',
      sourceName: '测试漫画源',
      sourceUrl: sourceUrl,
    );

    expect(info.sourceUrl, sourceUrl);
    expect(
      info,
      ComicBookInfo(
        id: 'book',
        title: '漫画',
        sourceName: '测试漫画源',
        sourceUrl: sourceUrl,
      ),
    );
  });

  testWidgets('failed comic images expose a background retry callback', (
    WidgetTester tester,
  ) async {
    final source = _RetryingComicSource(failures: 1);
    final cache = ComicImageByteCache(bookId: 'book', dataSource: source);
    Future<void> Function()? retry;
    addTearDown(cache.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: ComicProgressiveImageTile(
          cache: cache,
          chapterId: 'chapter-1',
          image: _image('image-1', null),
          width: 320,
          placeholderHeight: 240,
          palette: ReaderPalette.fromPreset(ReaderThemePreset.day),
          onFailure: (_) {},
          decodeBudget: ComicDecodedImageBudget(),
          onAutomaticRetryAvailable: (callback) => retry = callback,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(retry, isNotNull);
    await retry!();
    await tester.pump();
    expect(source.imageCalls, 2);
  });

  test(
    'comic image cache enforces single-flight, byte LRU and the shared single-image limit',
    () async {
      final source = _FakeComicSource();
      final cache = ComicImageByteCache(
        bookId: 'book',
        dataSource: source,
        maxEntries: 2,
        maxBytes: 10,
      );
      expect(cache.maxSingleImageBytes, ReaderContentLimits.imageBytes);
      final image = _image('one', 2);
      final first = cache.load('chapter-1', image);
      final second = cache.load('chapter-1', image);
      expect(identical(first, second), isTrue);
      await Future.wait(<Future<Uint8List>>[first, second]);
      expect(source.imageCalls, 1);
      await cache.load('chapter-1', _image('two', 2));
      await cache.load('chapter-1', _image('three', 8));
      expect(cache.entryCount, 2);
      expect(cache.byteCount, 10);
      final limited = ComicImageByteCache(bookId: 'book', dataSource: source);
      await expectLater(
        limited.load(
          'chapter-1',
          _image('too-large', ReaderContentLimits.imageBytes + 1),
        ),
        throwsStateError,
      );
    },
  );

  test(
    'single-image loading accepts 9 MiB and exactly 50 MiB while cache retention stays independent',
    () async {
      final cache = ComicImageByteCache(
        bookId: 'book',
        dataSource: _FakeComicSource(),
      );
      addTearDown(cache.dispose);
      expect(
        (await cache.load(
          'chapter-1',
          _image('above-old-limit', 9 * 1024 * 1024),
        )).length,
        9 * 1024 * 1024,
      );
      expect(
        (await cache.load(
          'chapter-1',
          _image('at-limit', 50 * 1024 * 1024),
        )).length,
        50 * 1024 * 1024,
      );
    },
  );

  test('comic image cache has a lazy 1000-entry safety cap', () {
    final source = _FakeComicSource();
    final cache = ComicImageByteCache(bookId: 'book', dataSource: source);
    addTearDown(cache.dispose);

    expect(cache.maxEntries, 1000);
    expect(cache.maxBytes, 48 * 1024 * 1024);
    expect(cache.entryCount, 0);
    expect(cache.byteCount, 0);
    expect(
      source.imageCalls,
      0,
      reason: 'constructing the reader cache must not start image work',
    );
  });

  testWidgets(
    'comic reader preloads the whole chapter while the first image is blocked',
    (WidgetTester tester) async {
      tester.view
        ..physicalSize = const Size(400, 600)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final source = _GatedFirstImageComicSource();

      await tester.pumpWidget(
        MaterialApp(
          home: ComicReaderView(
            bookId: 'book',
            dataSource: source,
            stateStore: _MemoryComicStateStore(),
          ),
        ),
      );
      for (
        var frame = 0;
        frame < 20 && source.requestedImages.isEmpty;
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 10));
      }

      expect(
        source.requestedImages,
        List.generate(9, (index) => 'image-${index + 1}'),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        source.requestedImages,
        List.generate(9, (index) => 'image-${index + 1}'),
      );

      source.releaseFirstImage();
      await tester.pumpAndSettle();
      expect(source.requestedImages, contains('image-2'));
    },
  );

  testWidgets(
    'comic reader caches configured following chapter manifests and images',
    (WidgetTester tester) async {
      final source = _MultiChapterPreloadComicSource();

      await tester.pumpWidget(
        MaterialApp(
          home: ComicReaderView(
            bookId: 'book',
            dataSource: source,
            stateStore: _MemoryComicStateStore(),
            chapterPreloadCount: 2,
          ),
        ),
      );
      for (
        var frame = 0;
        frame < 30 && !source.requestedImages.contains('chapter-3/image-3');
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 10));
      }

      expect(source.requestedContent, <String>[
        'chapter-1',
        'chapter-2',
        'chapter-3',
      ]);
      expect(source.requestedImages, <String>[
        'chapter-1/image-1',
        'chapter-2/image-2',
        'chapter-3/image-3',
      ]);
      expect(source.requestedContent, isNot(contains('chapter-4')));
    },
  );

  test(
    'memory pressure cancels prefetch and rejects late cache insertion',
    () async {
      final source = _BlockingComicSource();
      final cache = ComicImageByteCache(
        bookId: 'book',
        dataSource: source,
        maxConcurrentLoads: 1,
      );
      addTearDown(cache.dispose);

      cache.prefetch('chapter-1', _image('one', null));
      cache.prefetch('chapter-1', _image('two', null));
      await Future<void>.delayed(Duration.zero);
      expect(source.started, <String>['one']);

      cache.handleMemoryPressure();
      source.complete('one');
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(source.started, <String>['one']);
      expect(cache.entryCount, 0);
      expect(cache.byteCount, 0);
    },
  );

  test(
    'comic image cache schedules distinct images with a bounded concurrency',
    () async {
      final source = _BlockingComicSource();
      final cache = ComicImageByteCache(
        bookId: 'book',
        dataSource: source,
        maxConcurrentLoads: 2,
      );
      final first = cache.load('chapter-1', _image('one', null));
      final second = cache.load('chapter-1', _image('two', null));
      final third = cache.load('chapter-1', _image('three', null));

      await Future<void>.delayed(Duration.zero);
      expect(source.started, unorderedEquals(<String>['one', 'two']));
      expect(source.peakActive, 2);

      source.complete('one');
      await first;
      await Future<void>.delayed(Duration.zero);
      expect(source.started, contains('three'));
      expect(source.peakActive, 2);

      source
        ..complete('two')
        ..complete('three');
      await Future.wait(<Future<Uint8List>>[second, third]);
    },
  );

  test(
    'chapter preload is ordered, bounded and obeys the following chapter count',
    () async {
      final source = _BlockingComicSource();
      final cache = ComicImageByteCache(bookId: 'book', dataSource: source);
      final preloader = ComicChapterPreloader(cache);
      addTearDown(cache.dispose);
      final nextCalls = <int>[];
      final chapter = ComicChapterContent(
        chapterId: 'chapter-1',
        title: '第一章',
        images: [
          for (var i = 0; i < 10; i++) ComicImageInfo(id: 'page-$i', index: i),
        ],
      );
      preloader.start(
        chapter,
        followingChapterCount: 2,
        followingChapter: (int offset) async {
          nextCalls.add(offset);
          return ComicChapterContent(
            chapterId: 'chapter-${offset + 1}',
            title: '后续第 $offset 章',
            images: [_image('next-$offset', null)],
          );
        },
      );
      await Future<void>.delayed(Duration.zero);
      expect(source.started, ['page-0', 'page-1', 'page-2', 'page-3']);
      source.complete('page-2');
      await Future<void>.delayed(Duration.zero);
      expect(source.started.last, 'page-4');
      for (final i in [0, 1, 3, 4, 5, 6, 7, 8]) {
        source.complete('page-$i');
        await Future<void>.delayed(Duration.zero);
      }
      expect(nextCalls, isEmpty);
      expect(source.started, List.generate(10, (i) => 'page-$i'));
      source.complete('page-9');
      await Future<void>.delayed(Duration.zero);
      expect(nextCalls, <int>[1]);
      expect(source.started.last, 'next-1');
      expect(source.peakActive, 4);
      source.complete('next-1');
      await Future<void>.delayed(Duration.zero);
      expect(nextCalls, <int>[1, 2]);
      expect(source.started.last, 'next-2');
      source.complete('next-2');
      await Future<void>.delayed(Duration.zero);
      preloader.cancel();
    },
  );

  test('chapter preload reports image-level cache progress', () async {
    final source = _FakeComicSource();
    final cache = ComicImageByteCache(bookId: 'book', dataSource: source);
    final progress = <(int, int)>[];
    final preloader = ComicChapterPreloader(
      cache,
      onProgress: (chapter, cached, failed) {
        progress.add((cached, failed));
      },
    );
    addTearDown(cache.dispose);

    preloader.start(
      ComicChapterContent(
        chapterId: 'chapter-1',
        title: '第一章',
        images: <ComicImageInfo>[
          _image('one', null),
          ComicImageInfo(id: 'two', index: 1),
        ],
      ),
      followingChapterCount: 0,
      followingChapter: (_) async => null,
    );
    for (
      var attempt = 0;
      attempt < 20 && (progress.isEmpty || progress.last != (2, 0));
      attempt++
    ) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(progress.first, (0, 0));
    expect(progress.last, (2, 0));
  });

  test(
    'cancelling chapter preload stops replenishment and preserves visible work',
    () async {
      final source = _BlockingComicSource();
      final cache = ComicImageByteCache(bookId: 'book', dataSource: source);
      final preloader = ComicChapterPreloader(cache);
      addTearDown(cache.dispose);
      final chapter = ComicChapterContent(
        chapterId: 'chapter-1',
        title: '第一章',
        images: [
          for (var i = 0; i < 10; i++) ComicImageInfo(id: 'page-$i', index: i),
        ],
      );
      var nextCalls = 0;
      preloader.start(
        chapter,
        followingChapterCount: 1,
        followingChapter: (int offset) async {
          nextCalls++;
          return null;
        },
      );
      final visible = cache.load('chapter-1', chapter.images.first);
      preloader.cancel();
      for (var i = 0; i < 4; i++) {
        source.complete('page-$i');
      }
      expect(await visible, [1]);
      await Future<void>.delayed(Duration.zero);
      expect(source.started.length, 4);
      expect(nextCalls, 0);
      expect(cache.contains('chapter-1', chapter.images.first), isTrue);
    },
  );

  testWidgets(
    'unknown dimensions remain stable when scrolling up after byte eviction',
    (tester) async {
      tester.view
        ..physicalSize = const Size(400, 600)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final source = _LongComicSource();
      await tester.pumpWidget(
        MaterialApp(
          home: ComicReaderView(
            bookId: 'book',
            dataSource: source,
            stateStore: _MemoryComicStateStore(),
          ),
        ),
      );
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      final cache = tester
          .widget<ComicProgressiveImageTile>(
            find.byType(ComicProgressiveImageTile).first,
          )
          .cache;
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      position.jumpTo(10000);
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      cache.handleMemoryPressure();
      for (var i = 0; i < 12; i++) {
        final expected = position.pixels - 450;
        position.jumpTo(expected);
        for (var frame = 0; frame < 4; frame++) {
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(
          position.pixels,
          closeTo(expected, .1),
          reason: 'upward step $i must not bounce',
        );
      }
      final before = position.pixels;
      await tester.drag(find.byType(ListView).first, const Offset(0, 300));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(position.pixels, lessThan(before - 100));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a late image above the viewport preserves the visible anchor', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(400, 600)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final source = _GatedFirstImageComicSource();
    await tester.pumpWidget(
      MaterialApp(
        home: ComicReaderView(
          bookId: 'book',
          dataSource: source,
          stateStore: _MemoryComicStateStore(),
        ),
      ),
    );
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    position.jumpTo(4500);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    final page = find.byKey(
      const ValueKey<String>('comic-reader-image-chapter-1-image-3'),
    );
    final before = tester.getRect(page);
    source.releaseFirstImage();
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(tester.getRect(page).top, closeTo(before.top, .1));
    expect(tester.takeException(), isNull);
  });
}
