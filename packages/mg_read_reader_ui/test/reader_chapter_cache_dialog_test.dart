import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';

void main() {
  testWidgets(
    'chapter cache dialog uses bounded defaults and forwards the request',
    (WidgetTester tester) async {
      final capability = _RecordingChapterCacheCapability();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TextReaderView(
              bookId: 'cache-dialog-book',
              dataSource: const _CacheDialogDataSource(),
              stateStore: const _CacheDialogStateStore(),
              extensions: ReaderExtensions(chapterCacheCapability: capability),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(TextReaderView));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey<String>('reader-top-overflow')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('缓存章节'));
      await tester.pumpAndSettle();

      expect(find.text('可选范围：0–3 章'), findsOneWidget);
      final Finder sliderFinder = find.byKey(
        const ValueKey<String>('reader-cache-chapter-slider'),
      );
      final Slider initialSlider = tester.widget<Slider>(sliderFinder);
      expect(initialSlider.value, 0);
      expect(initialSlider.min, 0);
      expect(initialSlider.max, 3);
      expect(initialSlider.divisions, 3);
      expect(_fieldText(tester, 'reader-cache-concurrency'), '1');
      expect(_fieldText(tester, 'reader-cache-delay'), '3');

      initialSlider.onChanged!(2);
      await tester.pump();
      expect(find.text('2 / 3'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey<String>('reader-cache-start')),
      );
      await tester.pumpAndSettle();

      expect(capability.bookId, 'cache-dialog-book');
      expect(capability.request?.chapterCount, 2);
      expect(capability.request?.concurrency, 1);
      expect(capability.request?.delay, const Duration(seconds: 3));
    },
  );

  testWidgets(
    'dialog grows to available width and keeps concurrency and delay in one row',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final capability = _RecordingChapterCacheCapability();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TextReaderView(
              bookId: 'cache-range-book',
              dataSource: const _CacheDialogDataSource(),
              stateStore: const _CacheDialogStateStore(),
              extensions: ReaderExtensions(chapterCacheCapability: capability),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(TextReaderView));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('reader-top-overflow')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('缓存章节'));
      await tester.pumpAndSettle();

      final Rect dialogRect = tester.getRect(find.byType(AlertDialog));
      expect(dialogRect.left, lessThanOrEqualTo(16));
      expect(dialogRect.right, greaterThanOrEqualTo(484));

      final Finder concurrency = find.byKey(
        const ValueKey<String>('reader-cache-concurrency'),
      );
      final Finder delay = find.byKey(
        const ValueKey<String>('reader-cache-delay'),
      );
      expect(
        tester.getTopLeft(concurrency).dy,
        closeTo(tester.getTopLeft(delay).dy, 1),
      );
      expect(
        tester.getTopLeft(concurrency).dx,
        lessThan(tester.getTopLeft(delay).dx),
      );

      final Slider slider = tester.widget<Slider>(
        find.byKey(const ValueKey<String>('reader-cache-chapter-slider')),
      );
      expect(slider.max, 3);
      expect(slider.divisions, 3);
    },
  );
}

String _fieldText(WidgetTester tester, String key) {
  final editable = find.descendant(
    of: find.byKey(ValueKey<String>(key)),
    matching: find.byType(EditableText),
  );
  return tester.widget<EditableText>(editable).controller.text;
}

final class _RecordingChapterCacheCapability
    implements ReaderChapterCacheCapability {
  String? bookId;
  ReaderChapterCacheRequest? request;

  @override
  Future<void> startCaching(
    String bookId,
    ReaderChapterCacheRequest request,
  ) async {
    this.bookId = bookId;
    this.request = request;
  }
}

final class _CacheDialogDataSource implements TextReaderDataSource {
  const _CacheDialogDataSource();

  static const chapters = <ReaderChapterInfo>[
    ReaderChapterInfo(id: 'chapter-1', title: '第一章', index: 0),
    ReaderChapterInfo(id: 'chapter-2', title: '第二章', index: 1),
    ReaderChapterInfo(id: 'chapter-3', title: '第三章', index: 2),
  ];

  @override
  Future<ReaderBookInfo> loadBookInfo(String bookId) async =>
      ReaderBookInfo(id: bookId, title: '缓存弹窗测试书', chapterCount: 3);

  @override
  Future<ChapterCatalogPage> loadChapterCatalog(
    String bookId, {
    String? cursor,
    int pageSize = 100,
  }) async => ChapterCatalogPage(
    items: chapters,
    total: chapters.length,
    hasMore: false,
  );

  @override
  Future<ReaderChapterInfo> loadChapterAtIndex(
    String bookId,
    int index,
  ) async => chapters[index];

  @override
  Future<TextChapterContent> loadChapterContent(
    String bookId,
    String chapterId,
  ) async => TextChapterContent(
    chapterId: chapterId,
    title: chapters.firstWhere((chapter) => chapter.id == chapterId).title,
    paragraphs: <TextParagraph>[
      TextParagraph(id: '$chapterId-body', text: '正文'),
    ],
  );
}

final class _CacheDialogStateStore implements TextReaderStateStore {
  const _CacheDialogStateStore();

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
