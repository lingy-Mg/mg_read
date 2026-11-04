import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';
import 'package:novel_reader_ui/src/ui/comic/comic_image_tile.dart';

void main() {
  testWidgets(
    'local comic restores and debounces exact progress after decoding unknown-size image',
    (WidgetTester tester) async {
      tester.view
        ..physicalSize = const Size(400, 600)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      const ComicReaderProgress initial = ComicReaderProgress(
        chapterId: 'chapter-1',
        imageId: 'image-1',
        imageFraction: .45,
      );
      final _MemoryComicStore store = _MemoryComicStore(initial);
      const _LocalComicSource source = _LocalComicSource();
      expect(source, isA<ComicReaderPreciseProgressDataSource>());
      final ComicReaderController controller = ComicReaderController();
      addTearDown(controller.dispose);

      Widget reader(Key key, {double topInset = 0}) => MaterialApp(
        home: Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(padding: EdgeInsets.only(top: topInset)),
            child: ComicReaderView(
              key: key,
              bookId: 'local-book',
              dataSource: source,
              stateStore: store,
              controller: controller,
              chapterPreloadCount: 0,
            ),
          ),
        ),
      );

      await tester.pumpWidget(
        reader(const ValueKey<String>('first'), topInset: 27),
      );
      await tester.pumpAndSettle();

      final Finder tile = find.byType(ComicProgressiveImageTile);
      expect(tile, findsOneWidget);
      expect(tester.getSize(tile).height, closeTo(1600, 1));
      expect(controller.snapshot.progress?.imageId, 'image-1');
      expect(controller.snapshot.progress?.imageFraction, closeTo(.45, .01));
      final Rect firstTileRect = tester.getRect(tile);
      final Rect firstViewportRect = tester.getRect(
        find.byKey(const ValueKey<String>('comic-reader-content-surface')),
      );
      expect(
        firstTileRect.top + firstTileRect.height * .45,
        closeTo(firstViewportRect.top + 600 * .34, 2),
      );

      final ScrollableState scrollable = tester.state<ScrollableState>(
        find.descendant(
          of: find.byKey(
            const ValueKey<String>('comic-reader-content-surface'),
          ),
          matching: find.byType(Scrollable),
        ),
      );
      scrollable.position.jumpTo(scrollable.position.pixels + 120);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 100));
      final double jumpedFraction =
          controller.snapshot.progress?.imageFraction ?? 0;
      expect(jumpedFraction, greaterThan(.45));

      await tester.drag(
        find.byKey(const ValueKey<String>('comic-reader-content-surface')),
        const Offset(0, -100),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 100));
      final double scrolledFraction =
          controller.snapshot.progress?.imageFraction ?? 0;
      expect(scrolledFraction, greaterThan(jumpedFraction));
      await tester.pump(const Duration(milliseconds: 900));
      expect(store.savedProgress?.imageId, 'image-1');
      expect(
        store.savedProgress?.imageFraction,
        closeTo(scrolledFraction, .02),
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        reader(const ValueKey<String>('cold-reopen'), topInset: 0),
      );
      await tester.pumpAndSettle();
      expect(controller.snapshot.progress?.imageId, 'image-1');
      expect(
        controller.snapshot.progress?.imageFraction,
        closeTo(scrolledFraction, .02),
      );
      final Rect restoredTileRect = tester.getRect(tile);
      final Rect restoredViewportRect = tester.getRect(
        find.byKey(const ValueKey<String>('comic-reader-content-surface')),
      );
      expect(
        restoredTileRect.top + restoredTileRect.height * scrolledFraction,
        closeTo(restoredViewportRect.top + 600 * .34, 2),
      );

      for (final double topInset in <double>[27, 0, 27, 0]) {
        await tester.pumpWidget(
          reader(const ValueKey<String>('cold-reopen'), topInset: topInset),
        );
        await tester.pumpAndSettle();
        expect(
          controller.snapshot.progress?.imageFraction,
          closeTo(scrolledFraction, .0001),
        );
        final Rect tileRect = tester.getRect(tile);
        final Rect viewportRect = tester.getRect(
          find.byKey(const ValueKey<String>('comic-reader-content-surface')),
        );
        expect(
          tileRect.top + tileRect.height * scrolledFraction,
          closeTo(viewportRect.top + 600 * .34, 2),
        );
      }
      for (final double height in <double>[520, 600, 540, 600]) {
        tester.view.physicalSize = Size(400, height);
        await tester.pumpAndSettle();
        expect(
          controller.snapshot.progress?.imageFraction,
          closeTo(scrolledFraction, .0001),
        );
        final Rect tileRect = tester.getRect(tile);
        final Rect viewportRect = tester.getRect(
          find.byKey(const ValueKey<String>('comic-reader-content-surface')),
        );
        expect(
          tileRect.top + tileRect.height * scrolledFraction,
          closeTo(viewportRect.top + viewportRect.height * .34, 2),
        );
      }
      await tester.pump(const Duration(milliseconds: 900));
      expect(
        store.savedProgress?.imageFraction,
        closeTo(scrolledFraction, .0001),
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'pending exact restore survives inset changes and rapid exit before image decode',
    (WidgetTester tester) async {
      tester.view
        ..physicalSize = const Size(3840, 2160)
        ..devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      const double savedFraction = .4491960032259;
      const ComicReaderProgress saved = ComicReaderProgress(
        chapterId: 'chapter-1',
        imageId: 'image-4',
        imageFraction: savedFraction,
      );
      final _MemoryComicStore store = _MemoryComicStore(saved);
      final Completer<void> imageBytesGate = Completer<void>();
      final _LocalComicSource source = _LocalComicSource(
        imageBytesGate: imageBytesGate,
        imageCount: 4,
      );
      final ComicReaderController controller = ComicReaderController();
      addTearDown(controller.dispose);

      Widget reader(Key key, {required double topInset}) => MaterialApp(
        home: Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(padding: EdgeInsets.only(top: topInset)),
            child: ComicReaderView(
              key: key,
              bookId: 'local-book',
              dataSource: source,
              stateStore: store,
              controller: controller,
              chapterPreloadCount: 0,
            ),
          ),
        ),
      );

      await tester.pumpWidget(
        reader(const ValueKey<String>('delayed-first'), topInset: 27),
      );
      for (var frame = 0; frame < 12 && !controller.snapshot.isReady; frame++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(controller.snapshot.chapter?.id, 'chapter-1');
      expect(controller.snapshot.progress?.imageId, 'image-4');
      expect(
        controller.snapshot.progress?.imageFraction,
        closeTo(savedFraction, .000001),
      );

      // Change the status-bar inset while the restored image is still gated.
      await tester.pumpWidget(
        reader(const ValueKey<String>('delayed-first'), topInset: 0),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(controller.snapshot.progress?.imageId, 'image-4');
      expect(
        controller.snapshot.progress?.imageFraction,
        closeTo(savedFraction, .000001),
      );

      // Let the normal debounce fire and then leave before bytes are available.
      await tester.pump(const Duration(milliseconds: 900));
      expect(store.savedProgress?.imageId, 'image-4');
      expect(
        store.savedProgress?.imageFraction,
        closeTo(savedFraction, .000001),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(store.savedProgress?.imageId, 'image-4');
      expect(
        store.savedProgress?.imageFraction,
        closeTo(savedFraction, .000001),
      );

      imageBytesGate.complete();
      await tester.pumpWidget(
        reader(const ValueKey<String>('decoded-cold-reopen'), topInset: 0),
      );
      await tester.pumpAndSettle();
      final Finder restoredTile = find.byWidgetPredicate(
        (Widget widget) =>
            widget is ComicProgressiveImageTile && widget.image.id == 'image-4',
      );
      expect(restoredTile, findsOneWidget);
      final Rect tileRect = tester.getRect(restoredTile);
      final Rect viewportRect = tester.getRect(
        find.byKey(const ValueKey<String>('comic-reader-content-surface')),
      );
      expect(tileRect.height, closeTo(1280 * 4, 2));
      expect(controller.snapshot.progress?.imageId, 'image-4');
      expect(
        controller.snapshot.progress?.imageFraction,
        closeTo(savedFraction, .000001),
      );
      expect(
        tileRect.top + tileRect.height * savedFraction,
        closeTo(viewportRect.top + viewportRect.height * .34, 3),
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'remote comic sources keep the legacy chapter-start save policy',
    (WidgetTester tester) async {
      const ComicReaderProgress savedAtImage = ComicReaderProgress(
        chapterId: 'chapter-1',
        imageId: 'image-1',
        imageFraction: .45,
      );
      final _MemoryComicStore store = _MemoryComicStore(savedAtImage);
      final ComicReaderController controller = ComicReaderController();
      addTearDown(controller.dispose);
      expect(
        const _BaseComicSource(),
        isNot(isA<ComicReaderPreciseProgressDataSource>()),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: ComicReaderView(
            bookId: 'remote-book',
            dataSource: const _BaseComicSource(),
            stateStore: store,
            controller: controller,
            chapterPreloadCount: 0,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(store.savedProgress?.imageFraction, 0);
    },
  );
}

class _BaseComicSource implements ComicReaderDataSource {
  const _BaseComicSource();

  static final Uint8List _imageBytes = Uint8List.fromList(
    base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAGQAAAGQCAIAAADX9FK4AAADRElEQVR4nO3SMRHAMBADQTsIAydgDSYU/gp3u7WqG+3zvYuZZ7hDrMazArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxxLrDswKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArHEusOzArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKxArECsQKx1twPpDAExH2uY50AAAAASUVORK5CYII=',
    ),
  );

  @override
  Future<ComicBookInfo> loadBookInfo(String bookId) async =>
      ComicBookInfo(id: bookId, title: '本地样本');

  @override
  Future<ComicChapterCatalogPage> loadChapterCatalog(
    String bookId, {
    String? cursor,
    int pageSize = 50,
  }) async => ComicChapterCatalogPage(
    items: <ComicChapterInfo>[
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
    images: const <ComicImageInfo>[ComicImageInfo(id: 'image-1', index: 0)],
  );

  @override
  Future<Uint8List> loadImageBytes(
    String bookId,
    String chapterId,
    String imageId,
  ) async => Uint8List.fromList(_imageBytes);
}

class _LocalComicSource extends _BaseComicSource
    implements ComicReaderPreciseProgressDataSource {
  const _LocalComicSource({this.imageBytesGate, this.imageCount = 1});
  final Completer<void>? imageBytesGate;
  final int imageCount;

  @override
  Future<ComicChapterCatalogPage> loadChapterCatalog(
    String bookId, {
    String? cursor,
    int pageSize = 50,
  }) async => ComicChapterCatalogPage(
    items: [await loadChapterAtIndex(bookId, 0)],
    total: 1,
    hasMore: false,
  );

  @override
  Future<ComicChapterInfo> loadChapterAtIndex(String bookId, int index) async =>
      ComicChapterInfo(
        id: 'chapter-1',
        title: '第一章',
        index: 0,
        imageCount: imageCount,
      );

  @override
  Future<ComicChapterContent> loadChapterContent(
    String bookId,
    String chapterId,
  ) async => ComicChapterContent(
    chapterId: chapterId,
    title: '第一章',
    images: [
      for (var index = 0; index < imageCount; index++)
        ComicImageInfo(id: 'image-${index + 1}', index: index),
    ],
  );

  @override
  Future<Uint8List> loadImageBytes(
    String bookId,
    String chapterId,
    String imageId,
  ) async {
    await imageBytesGate?.future;
    return super.loadImageBytes(bookId, chapterId, imageId);
  }
}

class _MemoryComicStore implements ComicReaderStateStore {
  _MemoryComicStore(this.savedProgress);

  ComicReaderProgress? savedProgress;

  @override
  Future<ComicReaderProgress?> loadProgress(String bookId) async =>
      savedProgress;

  @override
  Future<void> saveProgress(String bookId, ComicReaderProgress progress) async {
    savedProgress = progress;
  }

  @override
  Future<ComicReaderPreferences?> loadPreferences() async =>
      const ComicReaderPreferences(keepScreenOn: false);

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
