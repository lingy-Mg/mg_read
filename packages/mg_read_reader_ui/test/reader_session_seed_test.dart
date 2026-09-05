import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';

void main() {
  testWidgets(
    'seed renders before catalog I/O and defers 500-row completion until the catalog opens',
    (tester) async {
      final dataSource = _SeedDataSource();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TextReaderView(
              bookId: 'seed-book',
              dataSource: dataSource,
              stateStore: const _SeedStateStore(),
              chapterPreloadCount: 0,
              seed: ReaderSessionSeed(
                book: const ReaderBookInfo(id: 'seed-book', title: '种子书'),
                initialChapter: const ReaderChapterInfo(
                  id: 'chapter-0',
                  title: '第一章',
                  index: 0,
                ),
                initialContent: TextChapterContent(
                  chapterId: 'chapter-0',
                  title: '第一章',
                  paragraphs: <TextParagraph>[
                    TextParagraph(id: 'p-0', text: '种子首帧正文'),
                  ],
                ),
                catalogTotal: 600,
              ),
            ),
          ),
        ),
      );

      await _pumpUntil(
        tester,
        () => find.textContaining('种子首帧正文').evaluate().isNotEmpty,
      );
      expect(dataSource.bookLoads, 0);
      expect(dataSource.contentLoads, 0);
      await dataSource.firstPageStarted.future;
      expect(dataSource.pageSizes, <int>[100]);
      expect(find.textContaining('种子首帧正文'), findsWidgets);

      dataSource.releaseFirstPage();
      await tester.pumpAndSettle();
      final surface = find.byKey(
        const ValueKey<String>('reader-content-surface'),
      );
      await tester.tapAt(tester.getCenter(surface));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('reader-toolbar-refresh-chapter')),
        findsNothing,
      );
      await tester.tap(find.text('目录'));
      await _pumpUntil(tester, () => dataSource.pageSizes.length == 2);
      await tester.pumpAndSettle();

      expect(dataSource.pageSizes, <int>[100, 500]);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() predicate) async {
  for (var attempt = 0; attempt < 120 && !predicate(); attempt++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(predicate(), isTrue);
}

final class _SeedDataSource implements TextReaderDataSource {
  final firstPageStarted = Completer<void>();
  final _firstPageRelease = Completer<void>();
  final pageSizes = <int>[];
  var bookLoads = 0;
  var contentLoads = 0;

  void releaseFirstPage() => _firstPageRelease.complete();

  @override
  Future<ReaderBookInfo> loadBookInfo(String bookId) async {
    bookLoads++;
    return const ReaderBookInfo(id: 'seed-book', title: '不得读取');
  }

  @override
  Future<ChapterCatalogPage> loadChapterCatalog(
    String bookId, {
    String? cursor,
    int pageSize = 100,
  }) async {
    pageSizes.add(pageSize);
    if (cursor == null) {
      if (!firstPageStarted.isCompleted) firstPageStarted.complete();
      await _firstPageRelease.future;
      return ChapterCatalogPage(
        items: _chapters(0, 100),
        total: 600,
        hasMore: true,
        nextCursor: '99',
      );
    }
    return ChapterCatalogPage(
      items: _chapters(100, 600),
      total: 600,
      hasMore: false,
    );
  }

  @override
  Future<ReaderChapterInfo> loadChapterAtIndex(
    String bookId,
    int index,
  ) async => _chapter(index);

  @override
  Future<TextChapterContent> loadChapterContent(
    String bookId,
    String chapterId,
  ) async {
    contentLoads++;
    return TextChapterContent(
      chapterId: chapterId,
      title: chapterId,
      paragraphs: <TextParagraph>[
        TextParagraph(id: '$chapterId-p', text: '不得读取'),
      ],
    );
  }
}

List<ReaderChapterInfo> _chapters(int start, int end) => <ReaderChapterInfo>[
  for (var index = start; index < end; index++) _chapter(index),
];

ReaderChapterInfo _chapter(int index) => ReaderChapterInfo(
  id: 'chapter-$index',
  title: '第 ${index + 1} 章',
  index: index,
);

final class _SeedStateStore implements TextReaderStateStore {
  const _SeedStateStore();

  @override
  Future<void> addBookmark(ReaderBookmark bookmark) async {}

  @override
  Future<List<ReaderBookmark>> loadBookmarks(String bookId) async =>
      const <ReaderBookmark>[];

  @override
  Future<TextReaderPreferences?> loadPreferences() async => null;

  @override
  Future<ReaderProgress?> loadProgress(String bookId) async => null;

  @override
  Future<void> removeBookmark(String bookId, String bookmarkId) async {}

  @override
  Future<void> savePreferences(TextReaderPreferences preferences) async {}

  @override
  Future<void> saveProgress(String bookId, ReaderProgress progress) async {}
}
