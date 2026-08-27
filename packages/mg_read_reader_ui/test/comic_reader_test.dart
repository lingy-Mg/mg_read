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
    expect(progress.copyWith(imageFraction: .9), equals(const ComicReaderProgress(
      chapterId: 'chapter-1',
      imageId: 'image-2',
      imageFraction: .9,
    )));
    expect(progress.chapterId, 'chapter-1');
    expect(progress.imageId, 'image-2');
  });

  test('comic image cache enforces single-flight, byte LRU and 8 MiB default', () async {
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
  });

  testWidgets('comic reader exposes stable actions and sends exit observer', (
    WidgetTester tester,
  ) async {
    final observer = _RecordingComicObserver();
    await tester.pumpWidget(MaterialApp(
      home: ComicReaderView(
        bookId: 'book',
        dataSource: _FakeComicSource(),
        stateStore: _MemoryComicStateStore(),
        observer: observer,
      ),
    ));
    await tester.pumpAndSettle();
    expect(observer.firstContentCount, 1);
    expect(observer.firstPresentation?.anchor?.imageId, 'image-1');
    expect(observer.firstPresentation?.cacheHit, isFalse);
    expect(find.byKey(const ValueKey<String>('comic-reader-content-surface')), findsOneWidget);
    expect(find.bySemanticsLabel('漫画图片 1'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('comic-reader-content-surface')));
    await tester.pump();
    expect(find.byKey(const ValueKey<String>('comic-reader-back-action')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('comic-reader-add-bookmark')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('comic-reader-catalog')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('comic-reader-bookmarks')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('comic-reader-settings')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('comic-reader-back-action')));
    await tester.pump();
    expect(observer.exitCount, 1);
    expect(observer.firstContentCount, 1);
  });
}

ComicImageInfo _image(String id, int? size) => ComicImageInfo(
  id: id,
  index: 0,
  width: 1,
  height: 1,
  byteLength: size,
);

class _FakeComicSource implements ComicReaderDataSource {
  int imageCalls = 0;

  @override
  Future<ComicBookInfo> loadBookInfo(String bookId) async => const ComicBookInfo(
    id: 'book',
    title: '漫画',
  );

  @override
  Future<ComicChapterCatalogPage> loadChapterCatalog(String bookId, {String? cursor, int pageSize = 50}) async => ComicChapterCatalogPage(
    items: const <ComicChapterInfo>[
      ComicChapterInfo(id: 'chapter-1', title: '第一章', index: 0, imageCount: 1),
    ],
    total: 1,
    hasMore: false,
  );

  @override
  Future<ComicChapterInfo> loadChapterAtIndex(String bookId, int index) async => const ComicChapterInfo(
    id: 'chapter-1', title: '第一章', index: 0, imageCount: 1,
  );

  @override
  Future<ComicChapterContent> loadChapterContent(String bookId, String chapterId) async => ComicChapterContent(
    chapterId: chapterId,
    title: '第一章',
    images: <ComicImageInfo>[_image('image-1', null)],
  );

  @override
  Future<Uint8List> loadImageBytes(String bookId, String chapterId, String imageId) async {
    imageCalls++;
    final int size = switch (imageId) {
      'one' || 'two' => 2,
      'three' => 8,
      'too-large' => 8 * 1024 * 1024 + 1,
      _ => 1,
    };
    if (imageId == 'image-1') {
      return Uint8List.fromList(base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      ));
    }
    return Uint8List(size);
  }
}

class _MemoryComicStateStore implements ComicReaderStateStore {
  @override
  Future<ComicReaderProgress?> loadProgress(String bookId) async => null;
  @override
  Future<void> saveProgress(String bookId, ComicReaderProgress progress) async {}
  @override
  Future<ComicReaderPreferences?> loadPreferences() async => null;
  @override
  Future<void> savePreferences(ComicReaderPreferences preferences) async {}
  @override
  Future<List<ComicReaderBookmark>> loadBookmarks(String bookId) async => const <ComicReaderBookmark>[];
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
  Future<void> onFirstContentPresented(ComicFirstContentPresentation presentation) async {
    firstContentCount++;
    firstPresentation = presentation;
  }

  @override
  Future<void> onExitRequested(ComicReaderProgress? progress) async { exitCount++; }
}
