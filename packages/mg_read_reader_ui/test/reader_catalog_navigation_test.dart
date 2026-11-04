import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';

void main() {
  testWidgets(
    'hides text continuation segments and selects their logical entry',
    (WidgetTester tester) async {
      final source = _ContinuationCatalogDataSource();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TextReaderView(
              bookId: 'continuation-book',
              dataSource: source,
              stateStore: const _ContinuationCatalogStateStore(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('reader-content-surface')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('目录'));
      await tester.pumpAndSettle();

      expect(find.text('内部续段'), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('reader-catalog-chapter-segment-15')),
        findsNothing,
      );
      final tile = tester.widget<ListTile>(
        find.byKey(const ValueKey<String>('reader-catalog-chapter-logical-14')),
      );
      expect(tile.selected, isTrue);
      final scrollable = tester.state<ScrollableState>(
        find.descendant(
          of: find.byKey(
            const PageStorageKey<String>(
              'reader-catalog-scroll-continuation-book',
            ),
          ),
          matching: find.byType(Scrollable),
        ),
      );
      expect(scrollable.position.pixels, greaterThan(0));
      final centerY =
          tester.view.physicalSize.height / tester.view.devicePixelRatio / 2;
      expect(
        (tester.getCenter(find.byWidget(tile)).dy - centerY).abs(),
        lessThan(180),
      );
    },
  );

  testWidgets(
    'catalog selection closes reader chrome and shows loading until an unavailable chapter arrives',
    (WidgetTester tester) async {
      final _DelayedCatalogChapterDataSource dataSource =
          _DelayedCatalogChapterDataSource();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TextReaderView(
              bookId: 'catalog-navigation-book',
              dataSource: dataSource,
              stateStore: const _CatalogNavigationStateStore(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final Finder readerSurface = find.byKey(
        const ValueKey<String>('reader-content-surface'),
      );
      await tester.tapAt(tester.getCenter(readerSurface));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('reader-controls-interaction-lock')),
        findsOneWidget,
      );

      await tester.tap(find.text('目录'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('reader-catalog-chapter-chapter-3')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.byKey(const ValueKey<String>('reader-catalog-chapter-chapter-3')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('reader-controls-interaction-lock')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('reader-chapter-loading-mask')),
        findsOneWidget,
      );
      expect(find.text('正在加载章节…'), findsOneWidget);

      dataSource.completeThirdChapter();
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('reader-chapter-loading-mask')),
        findsNothing,
      );
      expect(find.textContaining('第三章正文'), findsOneWidget);
    },
  );
}

final class _ContinuationCatalogDataSource implements TextReaderDataSource {
  late final List<ReaderChapterInfo> _chapters = List.generate(36, (index) {
    if (index == 15) {
      return const ReaderChapterInfo(
        id: 'segment-15',
        title: '内部续段',
        index: 15,
        isContinuation: true,
      );
    }
    final logicalIndex = index > 15 ? index - 1 : index;
    return ReaderChapterInfo(
      id: 'logical-$logicalIndex',
      title: '第${logicalIndex + 1}章',
      index: index,
    );
  });

  @override
  Future<ReaderBookInfo> loadBookInfo(String bookId) async => ReaderBookInfo(
    id: bookId,
    title: '分段目录测试书',
    chapterCount: _chapters.length,
  );

  @override
  Future<ChapterCatalogPage> loadChapterCatalog(
    String bookId, {
    String? cursor,
    int pageSize = 100,
  }) async => ChapterCatalogPage(
    items: _chapters,
    total: _chapters.length,
    hasMore: false,
  );

  @override
  Future<ReaderChapterInfo> loadChapterAtIndex(
    String bookId,
    int index,
  ) async => _chapters[index];

  @override
  Future<TextChapterContent> loadChapterContent(
    String bookId,
    String chapterId,
  ) async => TextChapterContent(
    chapterId: chapterId,
    title: chapterId,
    paragraphs: [TextParagraph(id: '$chapterId-body', text: '测试正文。')],
  );
}

final class _ContinuationCatalogStateStore implements TextReaderStateStore {
  const _ContinuationCatalogStateStore();

  @override
  Future<ReaderProgress?> loadProgress(String bookId) async =>
      const ReaderProgress(
        chapterId: 'segment-15',
        paragraphId: 'segment-15-body',
        chapterIndex: 15,
      );

  @override
  Future<List<ReaderBookmark>> loadBookmarks(String bookId) async => const [];

  @override
  Future<TextReaderPreferences?> loadPreferences() async => null;

  @override
  Future<void> addBookmark(ReaderBookmark bookmark) async {}

  @override
  Future<void> removeBookmark(String bookId, String bookmarkId) async {}

  @override
  Future<void> savePreferences(TextReaderPreferences preferences) async {}

  @override
  Future<void> saveProgress(String bookId, ReaderProgress progress) async {}
}

final class _DelayedCatalogChapterDataSource implements TextReaderDataSource {
  static const ReaderChapterInfo _first = ReaderChapterInfo(
    id: 'chapter-1',
    title: '第一章',
    index: 0,
    availability: ReaderChapterAvailability.downloaded,
  );
  static const ReaderChapterInfo _second = ReaderChapterInfo(
    id: 'chapter-2',
    title: '第二章',
    index: 1,
    availability: ReaderChapterAvailability.downloaded,
  );
  static const ReaderChapterInfo _third = ReaderChapterInfo(
    id: 'chapter-3',
    title: '第三章',
    index: 2,
    availability: ReaderChapterAvailability.notDownloaded,
  );

  final Completer<TextChapterContent> _thirdChapter =
      Completer<TextChapterContent>();

  void completeThirdChapter() {
    if (_thirdChapter.isCompleted) return;
    _thirdChapter.complete(
      TextChapterContent(
        chapterId: 'chapter-3',
        title: '第三章',
        paragraphs: <TextParagraph>[
          TextParagraph(id: 'chapter-3-body', text: '第三章正文已经加载完成。'),
        ],
      ),
    );
  }

  @override
  Future<ReaderBookInfo> loadBookInfo(String bookId) async =>
      ReaderBookInfo(id: bookId, title: '目录跳章测试书', chapterCount: 3);

  @override
  Future<ChapterCatalogPage> loadChapterCatalog(
    String bookId, {
    String? cursor,
    int pageSize = 100,
  }) async => ChapterCatalogPage(
    items: <ReaderChapterInfo>[_first, _second, _third],
    total: 3,
    hasMore: false,
  );

  @override
  Future<ReaderChapterInfo> loadChapterAtIndex(
    String bookId,
    int index,
  ) async => switch (index) {
    0 => _first,
    1 => _second,
    2 => _third,
    _ => throw RangeError.index(index, const <int>[0, 1, 2]),
  };

  @override
  Future<TextChapterContent> loadChapterContent(
    String bookId,
    String chapterId,
  ) {
    if (chapterId == 'chapter-3') return _thirdChapter.future;
    if (chapterId == 'chapter-2') {
      return Future<TextChapterContent>.value(
        TextChapterContent(
          chapterId: 'chapter-2',
          title: '第二章',
          paragraphs: <TextParagraph>[
            TextParagraph(id: 'chapter-2-body', text: '第二章正文。'),
          ],
        ),
      );
    }
    return Future<TextChapterContent>.value(
      TextChapterContent(
        chapterId: 'chapter-1',
        title: '第一章',
        paragraphs: <TextParagraph>[
          TextParagraph(id: 'chapter-1-body', text: '第一章正文。'),
        ],
      ),
    );
  }
}

final class _CatalogNavigationStateStore implements TextReaderStateStore {
  const _CatalogNavigationStateStore();

  @override
  Future<List<ReaderBookmark>> loadBookmarks(String bookId) async =>
      const <ReaderBookmark>[];

  @override
  Future<TextReaderPreferences?> loadPreferences() async => null;

  @override
  Future<ReaderProgress?> loadProgress(String bookId) async =>
      const ReaderProgress(
        chapterId: 'chapter-1',
        paragraphId: 'chapter-1-body',
        chapterIndex: 0,
      );

  @override
  Future<void> addBookmark(ReaderBookmark bookmark) async {}

  @override
  Future<void> removeBookmark(String bookId, String bookmarkId) async {}

  @override
  Future<void> savePreferences(TextReaderPreferences preferences) async {}

  @override
  Future<void> saveProgress(String bookId, ReaderProgress progress) async {}
}
