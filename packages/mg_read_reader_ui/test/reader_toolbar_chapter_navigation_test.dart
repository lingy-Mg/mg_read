import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';

void main() {
  for (final scenario in <_ToolbarChapterScenario>[
    const _ToolbarChapterScenario(
      name: 'next',
      targetIndex: 2,
      buttonKey: 'reader-toolbar-next-chapter',
    ),
    const _ToolbarChapterScenario(
      name: 'previous',
      targetIndex: 0,
      buttonKey: 'reader-toolbar-previous-chapter',
    ),
  ]) {
    testWidgets(
      'toolbar ${scenario.name} chapter closes controls and shows loading',
      (WidgetTester tester) async {
        final _DelayedToolbarChapterDataSource dataSource =
            _DelayedToolbarChapterDataSource(scenario.targetIndex);
        final TextReaderController controller = TextReaderController();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TextReaderView(
                bookId: 'toolbar-${scenario.name}-chapter-book',
                controller: controller,
                dataSource: dataSource,
                stateStore: const _ToolbarChapterStateStore(),
              ),
            ),
          ),
        );
        final Finder readerSurface = find.byKey(
          const ValueKey<String>('reader-content-surface'),
        );
        await _pumpUntil(
          tester,
          () =>
              controller.snapshot.chapter?.index == 1 &&
              readerSurface.evaluate().isNotEmpty,
        );
        await dataSource.primeTargetMiss();

        await tester.tapAt(tester.getCenter(readerSurface));
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          find.byKey(
            const ValueKey<String>('reader-controls-interaction-lock'),
          ),
          findsOneWidget,
        );

        await tester.tap(find.byKey(ValueKey<String>(scenario.buttonKey)));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(
          find.byKey(
            const ValueKey<String>('reader-controls-interaction-lock'),
          ),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey<String>('reader-chapter-loading-mask')),
          findsOneWidget,
        );
        expect(find.text('正在加载章节…'), findsOneWidget);

        dataSource.completeTarget();
        await _pumpUntil(
          tester,
          () => controller.snapshot.chapter?.index == scenario.targetIndex,
        );
        expect(
          find.byKey(const ValueKey<String>('reader-chapter-loading-mask')),
          findsNothing,
        );

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 16));
        controller.dispose();
      },
    );
  }
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var attempt = 0; attempt < 80 && !condition(); attempt++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(condition(), isTrue);
}

final class _ToolbarChapterScenario {
  const _ToolbarChapterScenario({
    required this.name,
    required this.targetIndex,
    required this.buttonKey,
  });

  final String name;
  final int targetIndex;
  final String buttonKey;
}

final class _DelayedToolbarChapterDataSource implements TextReaderDataSource {
  _DelayedToolbarChapterDataSource(this.targetIndex);

  static const List<ReaderChapterInfo> _chapters = <ReaderChapterInfo>[
    ReaderChapterInfo(id: 'chapter-1', title: '第一章', index: 0),
    ReaderChapterInfo(id: 'chapter-2', title: '第二章', index: 1),
    ReaderChapterInfo(id: 'chapter-3', title: '第三章', index: 2),
  ];

  final int targetIndex;
  final Completer<TextChapterContent> _target = Completer<TextChapterContent>();
  int _targetAttempts = 0;

  Future<void> primeTargetMiss() async {
    if (_targetAttempts > 0) return;
    try {
      await loadChapterContent('toolbar-prime-book', _chapters[targetIndex].id);
    } on ReaderFailure {
      // The first miss models an unavailable adjacent chapter. The toolbar
      // action below owns the visible retry and its loading state.
    }
  }

  void completeTarget() {
    if (_target.isCompleted) return;
    _target.complete(_contentFor(targetIndex));
  }

  @override
  Future<ReaderBookInfo> loadBookInfo(String bookId) async => ReaderBookInfo(
    id: bookId,
    title: '工具栏跨章测试书',
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
    final int index = _chapters.indexWhere(
      (ReaderChapterInfo chapter) => chapter.id == chapterId,
    );
    if (index == targetIndex) {
      _targetAttempts++;
      if (_targetAttempts == 1) {
        return Future<TextChapterContent>.error(
          const ReaderFailure(ReaderFailureKind.data, '模拟相邻预取尚未取得章节'),
        );
      }
      return _target.future;
    }
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

final class _ToolbarChapterStateStore implements TextReaderStateStore {
  const _ToolbarChapterStateStore();

  @override
  Future<List<ReaderBookmark>> loadBookmarks(String bookId) async =>
      const <ReaderBookmark>[];

  @override
  Future<TextReaderPreferences?> loadPreferences() async => null;

  @override
  Future<ReaderProgress?> loadProgress(String bookId) async =>
      const ReaderProgress(
        chapterId: 'chapter-2',
        paragraphId: 'paragraph-2',
        chapterIndex: 1,
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
