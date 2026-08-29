import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';

void main() {
  testWidgets('catalog completes 5000 chapters and lazily centres the current one', (WidgetTester tester) async {
    final _CatalogPositionDataSource dataSource = _CatalogPositionDataSource();
    final _CatalogChapterStateCapability chapterStateCapability = _CatalogChapterStateCapability();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 700,
            child: TextReaderView(
              bookId: 'catalog-position-book',
              dataSource: dataSource,
              stateStore: const _CatalogPositionStateStore(),
              extensions: ReaderExtensions(chapterStateCapability: chapterStateCapability),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Finder readerSurface = find.byKey(const ValueKey<String>('reader-content-surface'));
    await tester.tapAt(tester.getCenter(readerSurface));
    await tester.pumpAndSettle();
    await tester.tap(find.text('目录'));
    await tester.pumpAndSettle();

    expect(dataSource.requestedPageSizes, <int>[100, ...List<int>.filled(10, 500)]);
    expect(dataSource.requestedOffsets, <int>[0, 100, 600, 1100, 1600, 2100, 2600, 3100, 3600, 4100, 4600]);
    expect(dataSource.loadedChapterIds, contains('chapter-4990'));
    expect(find.byKey(const ValueKey<String>('reader-catalog-count-5000')), findsOneWidget);
    expect(find.text('加载更多章节'), findsNothing);
    final RawScrollbar catalogScrollbar = tester.widget<RawScrollbar>(find.byKey(const ValueKey<String>('reader-catalog-scrollbar')));
    expect(catalogScrollbar.thumbVisibility, isTrue);
    expect(catalogScrollbar.interactive, isTrue);
    expect(catalogScrollbar.thickness, 18);
    expect(catalogScrollbar.minThumbLength, 52);
    final Finder catalogList = find.byType(ListView);
    expect(catalogList, findsOneWidget);
    expect(find.ancestor(of: catalogList, matching: find.bySubtype<RawScrollbar>()), findsOneWidget);
    expect(find.text('已下载'), findsWidgets);
    expect(chapterStateCapability.queriedChapterIds, hasLength(5000));
    final int queryCountAfterFirstOpen = chapterStateCapability.requests.length;
    final Finder catalogScrollable = find.descendant(of: catalogList, matching: find.byType(Scrollable));
    final ScrollPosition catalogPosition = tester.state<ScrollableState>(catalogScrollable).position;
    expect(catalogPosition.maxScrollExtent, greaterThan(300000));
    expect(catalogPosition.pixels, greaterThan(300000));
    final Finder currentChapter = find.byKey(const ValueKey<String>('reader-catalog-chapter-chapter-4990'));
    expect(currentChapter, findsOneWidget);
    expect(find.byType(ListTile).evaluate().length, lessThan(30));

    final Rect chapterRect = tester.getRect(currentChapter);
    final Rect listRect = tester.getRect(catalogList);
    expect((chapterRect.center.dy - listRect.center.dy).abs(), lessThanOrEqualTo(2));

    Navigator.of(tester.element(catalogList)).pop();
    await tester.pumpAndSettle();
    await tester.tap(find.text('目录'));
    await tester.pumpAndSettle();

    expect(find.text('已下载'), findsWidgets);
    expect(chapterStateCapability.requests, hasLength(queryCountAfterFirstOpen));
  });
}

final class _CatalogChapterStateCapability implements ReaderChapterStateCapability {
  final List<List<String>> requests = <List<String>>[];

  Set<String> get queriedChapterIds => requests.expand((List<String> ids) => ids).toSet();

  @override
  Future<Map<String, ReaderChapterState>> loadChapterStates(String bookId, List<String> chapterIds) async {
    requests.add(List<String>.of(chapterIds));
    return <String, ReaderChapterState>{
      for (final String chapterId in chapterIds)
        chapterId: ReaderChapterState(chapterId: chapterId, availability: ReaderChapterAvailability.downloaded, wordCount: 1200),
    };
  }

  @override
  Future<void> markRead(String bookId, String chapterId) async {}
}

final class _CatalogPositionDataSource implements TextReaderDataSource {
  static final List<ReaderChapterInfo> _chapters = List<ReaderChapterInfo>.generate(
    5000,
    (int index) => ReaderChapterInfo(id: 'chapter-${index + 1}', title: '第 ${index + 1} 章', index: index),
    growable: false,
  );
  final List<int> requestedPageSizes = <int>[];
  final List<int> requestedOffsets = <int>[];
  final List<String> loadedChapterIds = <String>[];

  @override
  Future<ReaderBookInfo> loadBookInfo(String bookId) async => ReaderBookInfo(id: bookId, title: '目录定位测试书');

  @override
  Future<ChapterCatalogPage> loadChapterCatalog(String bookId, {String? cursor, int pageSize = 100}) async {
    final int offset = cursor == null ? 0 : int.parse(cursor.split(':').last);
    final int end = (offset + pageSize).clamp(0, _chapters.length);
    requestedPageSizes.add(pageSize);
    requestedOffsets.add(offset);
    return ChapterCatalogPage(
      items: _chapters.sublist(offset, end),
      total: _chapters.length,
      hasMore: end < _chapters.length,
      nextCursor: end < _chapters.length ? 'offset:$end' : null,
    );
  }

  @override
  Future<ReaderChapterInfo> loadChapterAtIndex(String bookId, int index) async => _chapters[index];

  @override
  Future<TextChapterContent> loadChapterContent(String bookId, String chapterId) async {
    loadedChapterIds.add(chapterId);
    final int chapterNumber = int.parse(chapterId.split('-').last);
    return TextChapterContent(
      chapterId: chapterId,
      title: '第 $chapterNumber 章',
      paragraphs: <TextParagraph>[TextParagraph(id: 'paragraph-$chapterNumber', text: '用于验证远距离当前章节的目录定位。')],
    );
  }
}

final class _CatalogPositionStateStore implements TextReaderStateStore {
  const _CatalogPositionStateStore();

  @override
  Future<List<ReaderBookmark>> loadBookmarks(String bookId) async => const <ReaderBookmark>[];

  @override
  Future<TextReaderPreferences?> loadPreferences() async => null;

  @override
  Future<ReaderProgress?> loadProgress(String bookId) async =>
      const ReaderProgress(chapterId: 'chapter-4990', paragraphId: 'paragraph-4990', chapterIndex: 4989);

  @override
  Future<void> addBookmark(ReaderBookmark bookmark) async {}

  @override
  Future<void> removeBookmark(String bookId, String bookmarkId) async {}

  @override
  Future<void> savePreferences(TextReaderPreferences preferences) async {}

  @override
  Future<void> saveProgress(String bookId, ReaderProgress progress) async {}
}
