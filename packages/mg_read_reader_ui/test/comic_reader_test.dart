import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';
import 'package:novel_reader_ui/src/ui/comic/comic_image_cache.dart';

void main() {
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
    'comic reader does not prefetch while the first image is still loading',
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

      expect(source.requestedImages, <String>['image-1']);
      await tester.pump(const Duration(milliseconds: 100));
      expect(source.requestedImages, <String>['image-1']);

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
    expect(observer.firstPresentation?.cacheHit, isFalse);
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
