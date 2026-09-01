import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';

void main() {
  testWidgets('preloads exactly the configured following chapter window', (
    WidgetTester tester,
  ) async {
    final _TrackingDataSource source = _TrackingDataSource(chapterCount: 6);
    await tester.pumpWidget(
      MaterialApp(
        home: TextReaderView(
          bookId: 'preload-book',
          dataSource: source,
          stateStore: const _VerticalStateStore(),
          chapterPreloadCount: 3,
        ),
      ),
    );

    for (var attempt = 0; attempt < 40 && source.loaded.length < 4; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }

    expect(source.loaded, <String>[
      'chapter-0',
      'chapter-1',
      'chapter-2',
      'chapter-3',
    ]);
    expect(source.loaded, isNot(contains('chapter-4')));
  });

  testWidgets('refreshes the catalog state after a chapter is preloaded', (
    WidgetTester tester,
  ) async {
    final _TrackingDataSource source = _TrackingDataSource(chapterCount: 3);
    final _TrackingChapterStateCapability capability =
        _TrackingChapterStateCapability(source);
    await tester.pumpWidget(
      MaterialApp(
        home: TextReaderView(
          bookId: 'preload-state-book',
          dataSource: source,
          stateStore: const _VerticalStateStore(),
          extensions: ReaderExtensions(chapterStateCapability: capability),
        ),
      ),
    );

    for (
      var attempt = 0;
      attempt < 80 && !source.loaded.contains('chapter-1');
      attempt++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }

    expect(source.loaded, contains('chapter-1'));
    expect(capability.queriedChapterIds, contains('chapter-1'));

    final Finder readerSurface = find.byKey(
      const ValueKey<String>('reader-content-surface'),
    );
    await tester.tapAt(tester.getCenter(readerSurface));
    await tester.pumpAndSettle();
    await tester.tap(find.text('目录'));
    await tester.pumpAndSettle();

    final Finder nextChapter = find.byKey(
      const ValueKey<String>('reader-catalog-chapter-chapter-1'),
    );
    expect(
      find.descendant(of: nextChapter, matching: find.text('已下载')),
      findsOneWidget,
    );

    final Finder followingChapter = find.byKey(
      const ValueKey<String>('reader-catalog-chapter-chapter-2'),
    );
    final ListTile nextTile = tester.widget<ListTile>(nextChapter);
    final ListTile followingTile = tester.widget<ListTile>(followingChapter);
    expect(nextTile.tileColor, equals(followingTile.tileColor));
    expect(tester.getSize(nextChapter).height, 54);
  });

  testWidgets('zero disables speculative chapter loading', (
    WidgetTester tester,
  ) async {
    final _TrackingDataSource source = _TrackingDataSource(chapterCount: 3);
    await tester.pumpWidget(
      MaterialApp(
        home: TextReaderView(
          bookId: 'no-preload-book',
          dataSource: source,
          stateStore: const _VerticalStateStore(),
          chapterPreloadCount: 0,
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await tester.pump();

    expect(source.loaded, <String>['chapter-0']);
  });

  testWidgets('horizontal mode extends the window after adjacent preparation', (
    WidgetTester tester,
  ) async {
    final _TrackingDataSource source = _TrackingDataSource(chapterCount: 5);
    await tester.pumpWidget(
      MaterialApp(
        home: TextReaderView(
          bookId: 'horizontal-preload-book',
          dataSource: source,
          stateStore: const _HorizontalStateStore(),
          chapterPreloadCount: 3,
        ),
      ),
    );

    for (var attempt = 0; attempt < 80 && source.loaded.length < 4; attempt++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
    }

    expect(source.loaded, <String>[
      'chapter-0',
      'chapter-1',
      'chapter-2',
      'chapter-3',
    ]);
    expect(source.loaded, isNot(contains('chapter-4')));
  });
}

final class _TrackingDataSource implements TextReaderDataSource {
  _TrackingDataSource({required this.chapterCount});

  final int chapterCount;
  final List<String> loaded = <String>[];

  ReaderChapterInfo _chapter(int index) => ReaderChapterInfo(
    id: 'chapter-$index',
    title: '第 ${index + 1} 章',
    index: index,
  );

  @override
  Future<ReaderBookInfo> loadBookInfo(String bookId) async =>
      ReaderBookInfo(id: bookId, title: '预加载测试');

  @override
  Future<ChapterCatalogPage> loadChapterCatalog(
    String bookId, {
    String? cursor,
    int pageSize = 100,
  }) async => ChapterCatalogPage(
    items: <ReaderChapterInfo>[
      for (var index = 0; index < chapterCount; index++) _chapter(index),
    ],
    total: chapterCount,
    hasMore: false,
  );

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
    loaded.add(chapterId);
    return TextChapterContent(
      chapterId: chapterId,
      title: chapterId,
      paragraphs: <TextParagraph>[
        TextParagraph(id: '$chapterId-paragraph', text: '$chapterId 正文'),
      ],
    );
  }
}

final class _TrackingChapterStateCapability
    implements ReaderChapterStateCapability {
  _TrackingChapterStateCapability(this.source);

  final _TrackingDataSource source;
  final Set<String> queriedChapterIds = <String>{};

  @override
  Future<Map<String, ReaderChapterState>> loadChapterStates(
    String bookId,
    List<String> chapterIds,
  ) async {
    queriedChapterIds.addAll(chapterIds);
    return <String, ReaderChapterState>{
      for (final String chapterId in chapterIds)
        chapterId: ReaderChapterState(
          chapterId: chapterId,
          availability: source.loaded.contains(chapterId)
              ? ReaderChapterAvailability.downloaded
              : ReaderChapterAvailability.notDownloaded,
        ),
    };
  }

  @override
  Future<void> markRead(String bookId, String chapterId) async {}
}

class _VerticalStateStore implements TextReaderStateStore {
  const _VerticalStateStore();

  @override
  Future<ReaderProgress?> loadProgress(String bookId) async => null;

  @override
  Future<void> saveProgress(String bookId, ReaderProgress progress) async {}

  @override
  Future<TextReaderPreferences?> loadPreferences() async =>
      const TextReaderPreferences(
        navigationMode: ReaderNavigationMode.verticalScroll,
        keepScreenOn: false,
      );

  @override
  Future<void> savePreferences(TextReaderPreferences preferences) async {}

  @override
  Future<List<ReaderBookmark>> loadBookmarks(String bookId) async =>
      const <ReaderBookmark>[];

  @override
  Future<void> addBookmark(ReaderBookmark bookmark) async {}

  @override
  Future<void> removeBookmark(String bookId, String bookmarkId) async {}
}

final class _HorizontalStateStore extends _VerticalStateStore {
  const _HorizontalStateStore();

  @override
  Future<TextReaderPreferences?> loadPreferences() async =>
      const TextReaderPreferences(keepScreenOn: false);
}
