import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';

void main() {
  testWidgets(
    'bookmark jump closes chrome and waits behind the reader loader',
    (WidgetTester tester) async {
      final _ExplicitNavigationDataSource dataSource =
          _ExplicitNavigationDataSource(delayedChapterId: 'chapter-3');
      final TextReaderController controller = TextReaderController();
      await _mountReader(
        tester,
        dataSource: dataSource,
        controller: controller,
        store: _ExplicitNavigationStateStore(
          bookmarks: <ReaderBookmark>[
            ReaderBookmark(
              id: 'bookmark-3',
              bookId: _bookId,
              chapterId: 'chapter-3',
              paragraphId: 'paragraph-3',
              characterOffset: 2,
              chapterTitle: '第三章',
              excerpt: '第三章书签位置',
              createdAt: DateTime(2026, 8, 29),
            ),
          ],
        ),
      );

      await _showControls(tester);
      await tester.tap(find.text('书签'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('第三章书签位置'));

      await _expectDelayedNavigation(
        tester,
        dataSource: dataSource,
        controller: controller,
        targetChapterId: 'chapter-3',
        controlsShouldClose: true,
      );
      expect(controller.snapshot.progress?.characterOffset, 2);

      await _disposeReader(tester, controller);
    },
  );

  testWidgets('book progress jump closes chrome and waits behind the loader', (
    WidgetTester tester,
  ) async {
    final _ExplicitNavigationDataSource dataSource =
        _ExplicitNavigationDataSource(delayedChapterId: 'chapter-3');
    final TextReaderController controller = TextReaderController();
    await _mountReader(
      tester,
      dataSource: dataSource,
      controller: controller,
      store: const _ExplicitNavigationStateStore(),
    );

    await _showControls(tester);
    await tester.drag(find.byType(Slider), const Offset(1200, 0));

    await _expectDelayedNavigation(
      tester,
      dataSource: dataSource,
      controller: controller,
      targetChapterId: 'chapter-3',
      controlsShouldClose: true,
    );

    await _disposeReader(tester, controller);
  });

  testWidgets('toolbar refresh closes chrome and exposes the reader loader', (
    WidgetTester tester,
  ) async {
    final _ExplicitNavigationDataSource dataSource =
        _ExplicitNavigationDataSource(
          delayedChapterId: 'chapter-1',
          delayedFromAttempt: 2,
        );
    final TextReaderController controller = TextReaderController();
    await _mountReader(
      tester,
      dataSource: dataSource,
      controller: controller,
      store: const _ExplicitNavigationStateStore(),
      chapterRefreshCapability: _DataSourceRefreshCapability(dataSource),
    );

    await _showControls(tester);
    await tester.tap(
      find.byKey(const ValueKey<String>('reader-toolbar-refresh-chapter')),
    );

    await _expectDelayedNavigation(
      tester,
      dataSource: dataSource,
      controller: controller,
      targetChapterId: 'chapter-1',
      controlsShouldClose: true,
    );

    await _disposeReader(tester, controller);
  });

  testWidgets('controller chapter command uses the same visible transition', (
    WidgetTester tester,
  ) async {
    final _ExplicitNavigationDataSource dataSource =
        _ExplicitNavigationDataSource(delayedChapterId: 'chapter-3');
    final TextReaderController controller = TextReaderController();
    await _mountReader(
      tester,
      dataSource: dataSource,
      controller: controller,
      store: const _ExplicitNavigationStateStore(),
    );

    await _showControls(tester);
    unawaited(controller.openChapter('chapter-3'));

    await _expectDelayedNavigation(
      tester,
      dataSource: dataSource,
      controller: controller,
      targetChapterId: 'chapter-3',
      controlsShouldClose: true,
    );

    await _disposeReader(tester, controller);
  });

  testWidgets(
    'start reading shows the loader even without old chapter content',
    (WidgetTester tester) async {
      final _ExplicitNavigationDataSource dataSource =
          _ExplicitNavigationDataSource(
            delayedChapterId: 'chapter-1',
            delayedFromAttempt: 2,
          );
      final TextReaderController controller = TextReaderController();
      await _mountReader(
        tester,
        dataSource: dataSource,
        controller: controller,
        store: const _ExplicitNavigationStateStore(),
      );
      unawaited(controller.showBookPreview());
      await _pumpUntil(
        tester,
        () => find
            .byKey(const ValueKey<String>('reader-start-reading'))
            .evaluate()
            .isNotEmpty,
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('reader-start-reading')),
      );
      await _expectDelayedNavigation(
        tester,
        dataSource: dataSource,
        controller: controller,
        targetChapterId: 'chapter-1',
        controlsShouldClose: false,
      );

      await _disposeReader(tester, controller);
    },
  );

  testWidgets('vertical chapter-end action shows the loader while next loads', (
    WidgetTester tester,
  ) async {
    final _ExplicitNavigationDataSource dataSource =
        _ExplicitNavigationDataSource(delayedChapterId: 'chapter-2');
    final TextReaderController controller = TextReaderController();
    await _mountReader(
      tester,
      dataSource: dataSource,
      controller: controller,
      store: const _ExplicitNavigationStateStore(
        preferences: TextReaderPreferences(
          navigationMode: ReaderNavigationMode.verticalScroll,
          keepScreenOn: false,
        ),
      ),
    );

    final Finder nextChapter = find.byKey(
      const ValueKey<String>('reader-vertical-next-chapter'),
    );
    await tester.scrollUntilVisible(
      nextChapter,
      300,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(nextChapter);
    await _expectDelayedNavigation(
      tester,
      dataSource: dataSource,
      controller: controller,
      targetChapterId: 'chapter-2',
      controlsShouldClose: false,
    );

    await _disposeReader(tester, controller);
  });
}

const String _bookId = 'explicit-navigation-book';

Future<void> _mountReader(
  WidgetTester tester, {
  required _ExplicitNavigationDataSource dataSource,
  required TextReaderController controller,
  required TextReaderStateStore store,
  ReaderChapterRefreshCapability? chapterRefreshCapability,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: TextReaderView(
          bookId: _bookId,
          controller: controller,
          dataSource: dataSource,
          stateStore: store,
          extensions: ReaderExtensions(
            chapterRefreshCapability: chapterRefreshCapability,
          ),
        ),
      ),
    ),
  );
  await _pumpUntil(
    tester,
    () =>
        controller.snapshot.chapter?.id == 'chapter-1' &&
        find
            .byKey(const ValueKey<String>('reader-content-surface'))
            .evaluate()
            .isNotEmpty,
  );
}

final class _DataSourceRefreshCapability
    implements ReaderChapterRefreshCapability {
  const _DataSourceRefreshCapability(this._dataSource);

  final TextReaderDataSource _dataSource;

  @override
  Future<TextChapterContent> refreshChapter(String bookId, String chapterId) =>
      _dataSource.loadChapterContent(bookId, chapterId);
}

Future<void> _showControls(WidgetTester tester) async {
  final Finder readerSurface = find.byKey(
    const ValueKey<String>('reader-content-surface'),
  );
  await tester.tapAt(tester.getCenter(readerSurface));
  await tester.pump(const Duration(milliseconds: 300));
  expect(
    find.byKey(const ValueKey<String>('reader-controls-interaction-lock')),
    findsOneWidget,
  );
}

Future<void> _expectDelayedNavigation(
  WidgetTester tester, {
  required _ExplicitNavigationDataSource dataSource,
  required TextReaderController controller,
  required String targetChapterId,
  required bool controlsShouldClose,
}) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  if (controlsShouldClose) {
    expect(
      find.byKey(const ValueKey<String>('reader-controls-interaction-lock')),
      findsNothing,
    );
  }
  expect(
    find.byKey(const ValueKey<String>('reader-chapter-loading-mask')),
    findsOneWidget,
  );

  dataSource.completeDelayedChapter();
  await _pumpUntil(
    tester,
    () =>
        controller.snapshot.chapter?.id == targetChapterId &&
        find
            .byKey(const ValueKey<String>('reader-chapter-loading-mask'))
            .evaluate()
            .isEmpty,
  );
}

Future<void> _disposeReader(
  WidgetTester tester,
  TextReaderController controller,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 16));
  controller.dispose();
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var attempt = 0; attempt < 100 && !condition(); attempt++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(condition(), isTrue);
}

final class _ExplicitNavigationDataSource implements TextReaderDataSource {
  _ExplicitNavigationDataSource({
    required this.delayedChapterId,
    this.delayedFromAttempt = 1,
  });

  static const List<ReaderChapterInfo> _chapters = <ReaderChapterInfo>[
    ReaderChapterInfo(id: 'chapter-1', title: '第一章', index: 0),
    ReaderChapterInfo(id: 'chapter-2', title: '第二章', index: 1),
    ReaderChapterInfo(id: 'chapter-3', title: '第三章', index: 2),
  ];

  final String delayedChapterId;
  final int delayedFromAttempt;
  final Completer<TextChapterContent> _delayed =
      Completer<TextChapterContent>();
  final Map<String, int> _attempts = <String, int>{};

  void completeDelayedChapter() {
    if (_delayed.isCompleted) return;
    final int index = _chapters.indexWhere(
      (ReaderChapterInfo chapter) => chapter.id == delayedChapterId,
    );
    _delayed.complete(_contentFor(index));
  }

  @override
  Future<ReaderBookInfo> loadBookInfo(String bookId) async => ReaderBookInfo(
    id: bookId,
    title: '显式跳章测试书',
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
  ) {
    final int attempt = (_attempts[chapterId] ?? 0) + 1;
    _attempts[chapterId] = attempt;
    if (chapterId == delayedChapterId && attempt >= delayedFromAttempt) {
      return _delayed.future;
    }
    final int index = _chapters.indexWhere(
      (ReaderChapterInfo chapter) => chapter.id == chapterId,
    );
    return Future<TextChapterContent>.value(_contentFor(index));
  }

  TextChapterContent _contentFor(int index) => TextChapterContent(
    chapterId: _chapters[index].id,
    title: _chapters[index].title,
    paragraphs: <TextParagraph>[
      TextParagraph(id: 'paragraph-${index + 1}', text: '第 ${index + 1} 章正文。'),
    ],
  );
}

final class _ExplicitNavigationStateStore implements TextReaderStateStore {
  const _ExplicitNavigationStateStore({
    this.bookmarks = const <ReaderBookmark>[],
    this.preferences,
  });

  final List<ReaderBookmark> bookmarks;
  final TextReaderPreferences? preferences;

  @override
  Future<List<ReaderBookmark>> loadBookmarks(String bookId) async => bookmarks;

  @override
  Future<TextReaderPreferences?> loadPreferences() async => preferences;

  @override
  Future<ReaderProgress?> loadProgress(String bookId) async =>
      const ReaderProgress(
        chapterId: 'chapter-1',
        paragraphId: 'paragraph-1',
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
