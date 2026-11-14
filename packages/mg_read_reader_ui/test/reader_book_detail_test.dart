import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';

void main() {
  testWidgets('reader source row and book details expose source metadata', (
    WidgetTester tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TextReaderView(
            bookId: 'detail-book',
            coverBytes: _onePixelPng,
            dataSource: const _DetailDataSource(),
            stateStore: const _DetailStateStore(
              preferences: TextReaderPreferences(
                theme: ReaderThemePreset.night,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(TextReaderView));
    await tester.pumpAndSettle();
    expect(find.text('演示数据源'), findsOneWidget);
    expect(
      find.bySemanticsLabel(
        '在外部浏览器打开来源链接: https://source.example/books/detail-book',
      ),
      findsOneWidget,
    );
    semantics.dispose();

    await tester.tap(find.text('目录'));
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.byType(TabBar))).brightness,
      Brightness.dark,
    );
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
    expect(readTile.tileColor, isNull);
    expect(unreadTile.tileColor, isNull);
    expect(readTile.hoverColor, isNotNull);
    expect(unreadTile.hoverColor, isNotNull);
    expect(
      find.descendant(
        of: readTileFinder,
        matching: find.byIcon(Icons.done_rounded),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: readTileFinder,
        matching: find.byIcon(Icons.download_done_rounded),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(
          const ValueKey<String>('reader-catalog-chapter-chapter-2'),
        ),
        matching: find.byIcon(Icons.radio_button_unchecked_rounded),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(
          const ValueKey<String>('reader-catalog-chapter-chapter-2'),
        ),
        matching: find.byIcon(Icons.cloud_download_outlined),
      ),
      findsOneWidget,
    );
    expect(tester.getSize(readTileFinder).height, 54);
    await tester.tap(find.text('书籍详情'));
    await tester.pumpAndSettle();

    expect(find.text('详情测试书'), findsWidgets);
    expect(find.text('测试作者'), findsWidgets);
    expect(find.text('测试简介'), findsOneWidget);
    expect(find.text('玄幻'), findsOneWidget);
    expect(find.text('连载'), findsOneWidget);
    expect(find.text('内容来源'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('reader-book-detail-cover-image')),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const ValueKey<String>('reader-book-detail-cover-placeholder'),
      ),
      findsNothing,
    );
    final Image cover = tester.widget<Image>(
      find.byKey(const ValueKey<String>('reader-book-detail-cover-image')),
    );
    expect(cover.image, isA<MemoryImage>());
  });
}

const List<int> _onePixelPng = <int>[
  137,
  80,
  78,
  71,
  13,
  10,
  26,
  10,
  0,
  0,
  0,
  13,
  73,
  72,
  68,
  82,
  0,
  0,
  0,
  1,
  0,
  0,
  0,
  1,
  8,
  6,
  0,
  0,
  0,
  31,
  21,
  196,
  137,
  0,
  0,
  0,
  13,
  73,
  68,
  65,
  84,
  120,
  156,
  99,
  248,
  207,
  192,
  240,
  31,
  0,
  5,
  0,
  1,
  255,
  137,
  153,
  61,
  29,
  0,
  0,
  0,
  0,
  73,
  69,
  78,
  68,
  174,
  66,
  96,
  130,
];

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
    coverUrl: Uri.parse('https://temporary.example/expired-cover-token'),
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
  const _DetailStateStore({this.preferences});

  final TextReaderPreferences? preferences;

  @override
  Future<List<ReaderBookmark>> loadBookmarks(String bookId) async =>
      const <ReaderBookmark>[];

  @override
  Future<TextReaderPreferences?> loadPreferences() async => preferences;

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
