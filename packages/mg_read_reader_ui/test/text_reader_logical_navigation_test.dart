import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';

void main() {
  late SchedulingStrategy schedulingStrategy;

  setUp(() {
    schedulingStrategy = SchedulerBinding.instance.schedulingStrategy;
    SchedulerBinding.instance.schedulingStrategy =
        ({required int priority, required SchedulerBinding scheduler}) => true;
  });

  tearDown(() {
    SchedulerBinding.instance.schedulingStrategy = schedulingStrategy;
  });

  testWidgets(
    'toolbar chapter actions skip continuations while page turns visit each segment',
    (WidgetTester tester) async {
      final TextReaderController controller = TextReaderController();
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TextReaderView(
              bookId: 'logical-book',
              controller: controller,
              dataSource: const _SegmentDataSource(),
              stateStore: const _InitialSegmentStore(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.snapshot.chapter?.id, 'segment-2');

      await controller.showControls();
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('reader-toolbar-next-chapter')),
      );
      await tester.pumpAndSettle();
      expect(controller.snapshot.chapter?.id, 'chapter-b');
      expect(controller.snapshot.progress?.chapterIndex, 3);

      await controller.showControls();
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('reader-toolbar-previous-chapter')),
      );
      await tester.pumpAndSettle();
      expect(controller.snapshot.chapter?.id, 'chapter-a');
      expect(controller.snapshot.progress?.chapterIndex, 0);

      // Page navigation is physical: turn through chapter A until its next
      // stored segment becomes current, without skipping to chapter B.
      for (var attempt = 0; attempt < 8; attempt++) {
        if (controller.snapshot.chapter?.id != 'chapter-a') break;
        await controller.nextPage();
        await tester.pumpAndSettle();
      }
      expect(controller.snapshot.chapter?.id, 'segment-1');
      expect(controller.snapshot.progress?.chapterIndex, 1);

      await controller.showControls();
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('reader-toolbar-next-chapter')),
      );
      await tester.pumpAndSettle();
      expect(controller.snapshot.chapter?.id, 'chapter-b');
      expect(controller.snapshot.progress?.chapterIndex, 3);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    },
  );
}

class _SegmentDataSource implements TextReaderDataSource {
  const _SegmentDataSource();

  static const List<ReaderChapterInfo> _chapters = <ReaderChapterInfo>[
    ReaderChapterInfo(id: 'chapter-a', title: '第一部分', index: 0),
    ReaderChapterInfo(
      id: 'segment-1',
      title: '第一部分',
      index: 1,
      isContinuation: true,
    ),
    ReaderChapterInfo(
      id: 'segment-2',
      title: '第一部分',
      index: 2,
      isContinuation: true,
    ),
    ReaderChapterInfo(id: 'chapter-b', title: '第二部分', index: 3),
    ReaderChapterInfo(
      id: 'segment-b-1',
      title: '第二部分',
      index: 4,
      isContinuation: true,
    ),
    ReaderChapterInfo(id: 'chapter-c', title: '第三部分', index: 5),
  ];

  @override
  Future<ReaderBookInfo> loadBookInfo(String bookId) async => ReaderBookInfo(
    id: bookId,
    title: '逻辑章节测试',
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
    title: _chapters
        .firstWhere((ReaderChapterInfo chapter) => chapter.id == chapterId)
        .title,
    paragraphs: <TextParagraph>[
      TextParagraph(id: '$chapterId-p1', text: 'This is $chapterId.'),
    ],
  );
}

class _InitialSegmentStore implements TextReaderStateStore {
  const _InitialSegmentStore();

  @override
  Future<List<ReaderBookmark>> loadBookmarks(String bookId) async =>
      const <ReaderBookmark>[];

  @override
  Future<TextReaderPreferences?> loadPreferences() async =>
      const TextReaderPreferences(keepScreenOn: false);

  @override
  Future<ReaderProgress?> loadProgress(String bookId) async =>
      const ReaderProgress(
        chapterId: 'segment-2',
        paragraphId: 'segment-2-p1',
        chapterIndex: 2,
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
