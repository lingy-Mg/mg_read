import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';

void main() {
  testWidgets('opens the first chapter when no reading progress exists', (
    WidgetTester tester,
  ) async {
    final controller = TextReaderController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TextReaderView(
            bookId: 'new-book',
            controller: controller,
            dataSource: const _InitialChapterDataSource(),
            stateStore: const _EmptyStateStore(),
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pumpAndSettle();

    expect(controller.snapshot.isReady, isTrue);
    expect(controller.snapshot.chapter?.id, 'chapter-1');
    expect(controller.snapshot.progress?.chapterIndex, 0);
    expect(find.text('开始阅读'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('presents real first text once without an intermediate loader', (
    WidgetTester tester,
  ) async {
    final _FirstFrameObserver observer = _FirstFrameObserver();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TextReaderView(
            bookId: 'first-frame-book',
            dataSource: const _InitialChapterDataSource(),
            stateStore: const _AnchoredStateStore(),
            observer: observer,
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    await tester.pumpAndSettle();

    await tester.pump(const Duration(milliseconds: 16));
    await tester.pumpAndSettle();
    for (var index = 0; index < 5; index++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(find.textContaining('第一章正文。'), findsOneWidget);
    expect(find.text('正在打开书籍…'), findsNothing);
    expect(observer.presentations, hasLength(1));
    expect(observer.presentations.single.anchor, isNotNull);
    expect(observer.presentations.single.anchor?.characterOffset, 3);
  });

  testWidgets(
    'clamps a stale offset and keeps the semantic anchor after scale',
    (WidgetTester tester) async {
      final _ClampedStateStore store = _ClampedStateStore();
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1)),
          child: MaterialApp(
            home: Scaffold(
              body: TextReaderView(
                bookId: 'anchor-book',
                dataSource: const _InitialChapterDataSource(),
                stateStore: store,
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pumpAndSettle();
      for (var index = 0; index < 5; index++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(store.lastProgress?.paragraphId, 'paragraph-1');
      expect(store.lastProgress?.characterOffset, 6);

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
          child: MaterialApp(
            home: Scaffold(
              body: TextReaderView(
                bookId: 'anchor-book',
                dataSource: const _InitialChapterDataSource(),
                stateStore: store,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pumpAndSettle();
      expect(store.lastProgress?.paragraphId, 'paragraph-1');
      expect(store.lastProgress?.characterOffset, 6);
    },
  );
}

final class _FirstFrameObserver extends ReaderObserver {
  final List<ReaderFirstContentPresentation> presentations =
      <ReaderFirstContentPresentation>[];
  @override
  void onFirstContentPresented(ReaderFirstContentPresentation presentation) {
    presentations.add(presentation);
  }
}

final class _InitialChapterDataSource implements TextReaderDataSource {
  const _InitialChapterDataSource();

  static const ReaderChapterInfo _chapter = ReaderChapterInfo(
    id: 'chapter-1',
    title: '第一章',
    index: 0,
  );

  @override
  Future<ReaderBookInfo> loadBookInfo(String bookId) async =>
      ReaderBookInfo(id: bookId, title: '新书');

  @override
  Future<ChapterCatalogPage> loadChapterCatalog(
    String bookId, {
    String? cursor,
    int pageSize = 100,
  }) async => ChapterCatalogPage(
    items: <ReaderChapterInfo>[_chapter],
    total: 1,
    hasMore: false,
  );

  @override
  Future<ReaderChapterInfo> loadChapterAtIndex(String bookId, int index) async {
    if (index != 0) throw RangeError.index(index, const <int>[0]);
    return _chapter;
  }

  @override
  Future<TextChapterContent> loadChapterContent(
    String bookId,
    String chapterId,
  ) async => TextChapterContent(
    chapterId: 'chapter-1',
    title: '第一章',
    paragraphs: <TextParagraph>[
      TextParagraph(id: 'paragraph-1', text: '第一章正文。'),
    ],
  );
}

class _EmptyStateStore implements TextReaderStateStore {
  const _EmptyStateStore();

  @override
  Future<List<ReaderBookmark>> loadBookmarks(String bookId) async =>
      const <ReaderBookmark>[];

  @override
  Future<TextReaderPreferences?> loadPreferences() async =>
      const TextReaderPreferences(keepScreenOn: false);

  @override
  Future<ReaderProgress?> loadProgress(String bookId) async => null;

  @override
  Future<void> addBookmark(ReaderBookmark bookmark) async {}

  @override
  Future<void> removeBookmark(String bookId, String bookmarkId) async {}

  @override
  Future<void> savePreferences(TextReaderPreferences preferences) async {}

  @override
  Future<void> saveProgress(String bookId, ReaderProgress progress) async {}
}

final class _AnchoredStateStore extends _EmptyStateStore {
  const _AnchoredStateStore();

  @override
  Future<ReaderProgress?> loadProgress(String bookId) async =>
      const ReaderProgress(
        chapterId: 'chapter-1',
        paragraphId: 'paragraph-1',
        characterOffset: 3,
      );
}

final class _ClampedStateStore extends _EmptyStateStore {
  ReaderProgress? lastProgress;

  @override
  Future<ReaderProgress?> loadProgress(String bookId) async =>
      const ReaderProgress(
        chapterId: 'chapter-1',
        paragraphId: 'paragraph-1',
        characterOffset: 999,
      );

  @override
  Future<void> saveProgress(String bookId, ReaderProgress progress) async {
    lastProgress = progress;
  }
}
