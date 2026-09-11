import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';
import 'package:novel_reader_ui/src/ui/comic/comic_image_cache.dart';
import 'package:novel_reader_ui/src/ui/comic/comic_image_tile.dart';
import 'package:novel_reader_ui/src/ui/comic/comic_chapter_preloader.dart';

void main() {
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

  test(
    'comic image cache enforces single-flight, byte LRU and 8 MiB default',
    () async {
      final source = _FakeComicSource();
      final cache = ComicImageByteCache(
        bookId: 'book',
        dataSource: source,
        maxEntries: 2,
        maxBytes: 10,
      );
      expect(cache.maxSingleImageBytes, 8 * 1024 * 1024);
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
        limited.load('chapter-1', _image('too-large', 8 * 1024 * 1024 + 1)),
        throwsStateError,
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
    'chapter preload is ordered, bounded and waits before the next chapter',
    () async {
      final source = _BlockingComicSource();
      final cache = ComicImageByteCache(bookId: 'book', dataSource: source);
      final preloader = ComicChapterPreloader(cache);
      addTearDown(cache.dispose);
      var nextCalls = 0;
      final chapter = ComicChapterContent(
        chapterId: 'chapter-1',
        title: '第一章',
        images: [
          for (var i = 0; i < 10; i++) ComicImageInfo(id: 'page-$i', index: i),
        ],
      );
      preloader.start(
        chapter,
        nextChapter: () async {
          nextCalls++;
          return ComicChapterContent(
            chapterId: 'chapter-2',
            title: '第二章',
            images: [_image('next', null)],
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
      expect(nextCalls, 0);
      expect(source.started, List.generate(10, (i) => 'page-$i'));
      source.complete('page-9');
      await Future<void>.delayed(Duration.zero);
      expect(nextCalls, 1);
      expect(source.started.last, 'next');
      expect(source.peakActive, 4);
      source.complete('next');
      await Future<void>.delayed(Duration.zero);
      preloader.cancel();
    },
  );

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
        nextChapter: () async {
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

  test('comic preferences always normalize image spacing to zero', () {
    expect(
      const ComicReaderPreferences(imageSpacing: 24).normalized().imageSpacing,
      0,
    );
  });

  testWidgets(
    'comic images use decoded dimensions and meet without fixed-extent gaps',
    (WidgetTester tester) async {
      tester.view
        ..physicalSize = const Size(400, 800)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final Uint8List wide = Uint8List.fromList(
        base64Decode('UklGRh4AAABXRUJQVlA4TBEAAAAvAwAAAAdQs840s/+BiOh/AAA='),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ComicReaderView(
            bookId: 'book',
            dataSource: _MismatchedAspectComicSource(wide),
            stateStore: _MemoryComicStateStore(),
          ),
        ),
      );
      for (int frame = 0; frame < 20; frame++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      final Rect first = tester.getRect(
        find.byKey(const ValueKey<String>('comic-reader-image-chapter-1-one')),
      );
      final Rect second = tester.getRect(
        find.byKey(const ValueKey<String>('comic-reader-image-chapter-1-two')),
      );
      expect(first.height, closeTo(100, .1));
      expect(second.top, closeTo(first.bottom, .1));
    },
  );

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

ComicImageInfo _image(String id, int? size) =>
    ComicImageInfo(id: id, index: 0, width: 1, height: 1, byteLength: size);

class _FakeComicSource implements ComicReaderDataSource {
  int imageCalls = 0;

  @override
  Future<ComicBookInfo> loadBookInfo(String bookId) async =>
      const ComicBookInfo(id: 'book', title: '漫画');

  @override
  Future<ComicChapterCatalogPage> loadChapterCatalog(
    String bookId, {
    String? cursor,
    int pageSize = 50,
  }) async => ComicChapterCatalogPage(
    items: const <ComicChapterInfo>[
      ComicChapterInfo(id: 'chapter-1', title: '第一章', index: 0, imageCount: 1),
    ],
    total: 1,
    hasMore: false,
  );

  @override
  Future<ComicChapterInfo> loadChapterAtIndex(String bookId, int index) async =>
      const ComicChapterInfo(
        id: 'chapter-1',
        title: '第一章',
        index: 0,
        imageCount: 1,
      );

  @override
  Future<ComicChapterContent> loadChapterContent(
    String bookId,
    String chapterId,
  ) async => ComicChapterContent(
    chapterId: chapterId,
    title: '第一章',
    images: <ComicImageInfo>[_image('image-1', null)],
  );

  @override
  Future<Uint8List> loadImageBytes(
    String bookId,
    String chapterId,
    String imageId,
  ) async {
    imageCalls++;
    final int size = switch (imageId) {
      'one' || 'two' => 2,
      'three' => 8,
      'too-large' => 8 * 1024 * 1024 + 1,
      _ => 1,
    };
    if (imageId == 'image-1') {
      return Uint8List.fromList(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
        ),
      );
    }
    return Uint8List(size);
  }
}

class _BlockingComicSource extends _FakeComicSource {
  final List<String> started = <String>[];
  final Map<String, Completer<Uint8List>> _pending =
      <String, Completer<Uint8List>>{};
  int _active = 0;
  int peakActive = 0;

  @override
  Future<Uint8List> loadImageBytes(
    String bookId,
    String chapterId,
    String imageId,
  ) async {
    started.add(imageId);
    _active++;
    if (_active > peakActive) peakActive = _active;
    try {
      return await (_pending[imageId] ??= Completer<Uint8List>()).future;
    } finally {
      _active--;
    }
  }

  void complete(String imageId) {
    final Completer<Uint8List>? pending = _pending[imageId];
    if (pending != null && !pending.isCompleted) {
      pending.complete(Uint8List.fromList(<int>[1]));
    }
  }
}

class _GatedFirstImageComicSource extends _FakeComicSource {
  final Completer<void> _firstImageRelease = Completer<void>();
  final List<String> requestedImages = <String>[];

  void releaseFirstImage() => _firstImageRelease.complete();

  @override
  Future<ComicChapterCatalogPage> loadChapterCatalog(
    String bookId, {
    String? cursor,
    int pageSize = 50,
  }) async => ComicChapterCatalogPage(
    items: const <ComicChapterInfo>[
      ComicChapterInfo(id: 'chapter-1', title: '第一章', index: 0, imageCount: 9),
    ],
    total: 1,
    hasMore: false,
  );

  @override
  Future<ComicChapterContent> loadChapterContent(
    String bookId,
    String chapterId,
  ) async => ComicChapterContent(
    chapterId: chapterId,
    title: '第一章',
    images: <ComicImageInfo>[
      for (var index = 0; index < 9; index++)
        ComicImageInfo(
          id: 'image-${index + 1}',
          index: index,
          width: 100,
          height: 1000,
        ),
    ],
  );

  @override
  Future<Uint8List> loadImageBytes(
    String bookId,
    String chapterId,
    String imageId,
  ) async {
    requestedImages.add(imageId);
    if (imageId == 'image-1') await _firstImageRelease.future;
    return Uint8List.fromList(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      ),
    );
  }
}

class _MismatchedAspectComicSource extends _FakeComicSource {
  _MismatchedAspectComicSource(this._bytes);

  final Uint8List _bytes;

  @override
  Future<ComicChapterCatalogPage> loadChapterCatalog(
    String bookId, {
    String? cursor,
    int pageSize = 50,
  }) async => ComicChapterCatalogPage(
    items: <ComicChapterInfo>[
      ComicChapterInfo(id: 'chapter-1', title: '第一章', index: 0, imageCount: 2),
    ],
    total: 1,
    hasMore: false,
  );

  @override
  Future<ComicChapterContent> loadChapterContent(
    String bookId,
    String chapterId,
  ) async => ComicChapterContent(
    chapterId: 'chapter-1',
    title: '第一章',
    images: <ComicImageInfo>[
      ComicImageInfo(id: 'one', index: 0, width: 1, height: 1),
      ComicImageInfo(id: 'two', index: 1, width: 1, height: 1),
    ],
  );

  @override
  Future<Uint8List> loadImageBytes(
    String bookId,
    String chapterId,
    String imageId,
  ) async => _bytes;
}

class _TrackedAdjacentComicSource extends _FakeComicSource {
  final List<String> requestedChapters = <String>[];

  @override
  Future<ComicChapterCatalogPage> loadChapterCatalog(
    String bookId, {
    String? cursor,
    int pageSize = 50,
  }) async => ComicChapterCatalogPage(
    items: List<ComicChapterInfo>.generate(
      5,
      (int index) => ComicChapterInfo(
        id: 'chapter-${index + 1}',
        title: '第${index + 1}章',
        index: index,
        imageCount: 4,
      ),
    ),
    total: 5,
    hasMore: false,
  );

  @override
  Future<ComicChapterInfo> loadChapterAtIndex(String bookId, int index) async =>
      ComicChapterInfo(
        id: 'chapter-${index + 1}',
        title: '第${index + 1}章',
        index: index,
        imageCount: 4,
      );

  @override
  Future<ComicChapterContent> loadChapterContent(
    String bookId,
    String chapterId,
  ) {
    requestedChapters.add(chapterId);
    return Future<ComicChapterContent>.value(_content(chapterId));
  }

  ComicChapterContent _content(String chapterId) => ComicChapterContent(
    chapterId: chapterId,
    title: chapterId,
    images: List<ComicImageInfo>.generate(
      4,
      (int index) => ComicImageInfo(
        id: '$chapterId-image-${index + 1}',
        index: index,
        width: 1,
        height: 1,
      ),
    ),
  );
}

class _MemoryComicStateStore implements ComicReaderStateStore {
  _MemoryComicStateStore({this.progress});

  final ComicReaderProgress? progress;

  @override
  Future<ComicReaderProgress?> loadProgress(String bookId) async => progress;
  @override
  Future<void> saveProgress(
    String bookId,
    ComicReaderProgress progress,
  ) async {}
  @override
  Future<ComicReaderPreferences?> loadPreferences() async => null;
  @override
  Future<void> savePreferences(ComicReaderPreferences preferences) async {}
  @override
  Future<List<ComicReaderBookmark>> loadBookmarks(String bookId) async =>
      const <ComicReaderBookmark>[];
  @override
  Future<void> addBookmark(ComicReaderBookmark bookmark) async {}
  @override
  Future<void> removeBookmark(String bookId, String bookmarkId) async {}
}

class _RecordingComicObserver extends ComicReaderObserver {
  int exitCount = 0;
  int firstContentCount = 0;
  ComicFirstContentPresentation? firstPresentation;

  @override
  Future<void> onFirstContentPresented(
    ComicFirstContentPresentation presentation,
  ) async {
    firstContentCount++;
    firstPresentation = presentation;
  }

  @override
  Future<void> onExitRequested(ComicReaderProgress? progress) async {
    exitCount++;
  }
}

class _LongComicSource extends _FakeComicSource {
  @override
  Future<ComicChapterCatalogPage> loadChapterCatalog(
    String bookId, {
    String? cursor,
    int pageSize = 50,
  }) async => ComicChapterCatalogPage(
    items: const [
      ComicChapterInfo(id: 'chapter-1', title: '第一章', index: 0, imageCount: 40),
    ],
    total: 1,
    hasMore: false,
  );

  @override
  Future<ComicChapterContent> loadChapterContent(
    String bookId,
    String chapterId,
  ) async => ComicChapterContent(
    chapterId: chapterId,
    title: '第一章',
    images: [
      for (var i = 0; i < 40; i++) ComicImageInfo(id: 'image-$i', index: i),
    ],
  );

  @override
  Future<Uint8List> loadImageBytes(
    String bookId,
    String chapterId,
    String imageId,
  ) => super.loadImageBytes(bookId, chapterId, 'image-1');
}
