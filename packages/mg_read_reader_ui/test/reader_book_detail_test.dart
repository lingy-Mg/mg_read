import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';

void main() {
  testWidgets('reader source row and book details expose source metadata', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TextReaderView(
            bookId: 'detail-book',
            dataSource: const _DetailDataSource(),
            stateStore: const _DetailStateStore(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(TextReaderView));
    await tester.pumpAndSettle();
    expect(find.text('演示数据源'), findsOneWidget);
    expect(
      find.text('https://source.example/books/detail-book'),
      findsOneWidget,
    );

    await tester.tap(find.text('目录'));
    await tester.pumpAndSettle();
    expect(find.text('已下载'), findsWidgets);
    expect(find.text('已读'), findsWidgets);
    expect(find.text('未下载'), findsOneWidget);
    expect(find.text('未读'), findsOneWidget);
    expect(find.text('1200 字'), findsOneWidget);
    final ListTile readTile = tester.widget<ListTile>(
      find.byKey(const ValueKey<String>('reader-catalog-chapter-chapter-3')),
    );
    final ListTile unreadTile = tester.widget<ListTile>(
      find.byKey(const ValueKey<String>('reader-catalog-chapter-chapter-2')),
    );
    final Finder readTileFinder = find.byKey(
      const ValueKey<String>('reader-catalog-chapter-chapter-3'),
    );
    expect(readTile.tileColor, isNot(equals(unreadTile.tileColor)));
    expect(tester.getSize(readTileFinder).height, 54);
    await tester.tap(find.text('书籍详情'));
    await tester.pumpAndSettle();

    expect(find.text('详情测试书'), findsWidgets);
    expect(find.text('测试作者'), findsWidgets);
    expect(find.text('测试简介'), findsOneWidget);
    expect(find.text('玄幻'), findsOneWidget);
    expect(find.text('连载'), findsOneWidget);
    expect(find.text('来源频道'), findsOneWidget);
  });
}

final class _DetailDataSource implements TextReaderDataSource {
  const _DetailDataSource();

  static const ReaderChapterInfo _downloadedChapter = ReaderChapterInfo(
    id: 'chapter-1',
    title: '第一章',
    index: 0,
    availability: ReaderChapterAvailability.downloaded,
    wordCount: 1200,
    hasBeenRead: true,
  );

  static const ReaderChapterInfo _unreadChapter = ReaderChapterInfo(
    id: 'chapter-2',
    title: '第二章',
    index: 1,
    availability: ReaderChapterAvailability.notDownloaded,
    wordCount: 900,
  );

  static const ReaderChapterInfo _readLaterChapter = ReaderChapterInfo(
    id: 'chapter-3',
    title: '第三章',
    index: 2,
    availability: ReaderChapterAvailability.downloaded,
    wordCount: 700,
    hasBeenRead: true,
  );

  @override
  Future<ReaderBookInfo> loadBookInfo(String bookId) async => ReaderBookInfo(
    id: 'detail-book',
    title: '详情测试书',
    author: '测试作者',
    description: '测试简介',
    sourceName: '演示数据源',
    sourceUrl: Uri.parse('https://source.example/books/detail-book'),
    wordCount: 120000,
    chapterCount: 12,
    statusLabel: '连载',
    labels: <String>['玄幻'],
    sourceKind: ReaderBookSourceKind.remote,
  );

  @override
  Future<ChapterCatalogPage> loadChapterCatalog(
    String bookId, {
    String? cursor,
    int pageSize = 100,
  }) async => ChapterCatalogPage(
    items: const <ReaderChapterInfo>[
      _downloadedChapter,
      _unreadChapter,
      _readLaterChapter,
    ],
    total: 3,
    hasMore: false,
  );

  @override
  Future<ReaderChapterInfo> loadChapterAtIndex(String bookId, int index) async {
    if (index == 0) return _downloadedChapter;
    if (index == 1) return _unreadChapter;
    if (index == 2) return _readLaterChapter;
    throw RangeError.index(index, const <int>[0, 1, 2]);
  }

  @override
  Future<TextChapterContent> loadChapterContent(
    String bookId,
    String chapterId,
  ) async => TextChapterContent(
    chapterId: 'chapter-1',
    title: '第一章',
    paragraphs: <TextParagraph>[TextParagraph(id: 'p1', text: '正文。')],
  );
}

final class _DetailStateStore implements TextReaderStateStore {
  const _DetailStateStore();

  @override
  Future<List<ReaderBookmark>> loadBookmarks(String bookId) async =>
      const <ReaderBookmark>[];

  @override
  Future<TextReaderPreferences?> loadPreferences() async => null;

  @override
  Future<ReaderProgress?> loadProgress(String bookId) async =>
      const ReaderProgress(chapterId: 'chapter-1', paragraphId: 'p1');

  @override
  Future<void> addBookmark(ReaderBookmark bookmark) async {}

  @override
  Future<void> removeBookmark(String bookId, String bookmarkId) async {}

  @override
  Future<void> savePreferences(TextReaderPreferences preferences) async {}

  @override
  Future<void> saveProgress(String bookId, ReaderProgress progress) async {}
}
