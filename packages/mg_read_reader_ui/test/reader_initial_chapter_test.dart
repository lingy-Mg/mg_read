import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
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

  testWidgets('re-paginates at a new viewport and keeps its semantic anchor', (
    WidgetTester tester,
  ) async {
    final controller = TextReaderController();
    const ReaderProgress anchor = ReaderProgress(
      chapterId: 'chapter-1',
      paragraphId: 'paragraph-1',
      characterOffset: 120,
    );

    Widget readerAt(Size size) => MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: TextReaderView(
              key: const ValueKey<String>('resizable-reader'),
              bookId: 'resizable-book',
              controller: controller,
              dataSource: const _DenseChapterDataSource(),
              stateStore: const _FixedProgressStateStore(anchor),
            ),
          ),
        ),
      ),
    );

    await tester.pumpWidget(readerAt(const Size(360, 560)));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pumpAndSettle();
    for (var index = 0; index < 5; index++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(controller.snapshot.progress?.paragraphId, anchor.paragraphId);
    expect(
      controller.snapshot.progress?.characterOffset,
      anchor.characterOffset,
    );

    await tester.pumpWidget(readerAt(const Size(520, 720)));
    await tester.pumpAndSettle();
    for (var index = 0; index < 5; index++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(controller.snapshot.isReady, isTrue);
    expect(controller.snapshot.progress?.chapterId, anchor.chapterId);
    expect(controller.snapshot.progress?.paragraphId, anchor.paragraphId);
    expect(
      controller.snapshot.progress?.characterOffset,
      anchor.characterOffset,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('previous chapter opens at its tail after progressive layout', (
    WidgetTester tester,
  ) async {
    final controller = TextReaderController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TextReaderView(
            bookId: 'previous-chapter-book',
            controller: controller,
            dataSource: const _PreviousChapterDataSource(),
            stateStore: const _EmptyStateStore(),
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    for (var index = 0; index < 8; index++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.runAsync(controller.nextChapter);
    for (var index = 0; index < 8; index++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(controller.snapshot.chapter?.id, 'chapter-2');
    await tester.runAsync(controller.previousChapter);
    await tester.pump();
    expect(find.text('正在定位上一章末页'), findsOneWidget);

    for (var index = 0; index < 12; index++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(controller.snapshot.chapter?.id, 'chapter-1');
    expect(controller.snapshot.progress?.paragraphId, 'chapter-1-tail');
    expect(
      controller.snapshot.progress?.characterOffset,
      _PreviousChapterDataSource.tail.length,
    );
    final tail = find.textContaining(_PreviousChapterDataSource.tail);
    expect(tail, findsOneWidget);
    expect(
      tester
          .getRect(tail)
          .overlaps(
            tester.getRect(
              find.byKey(const ValueKey<String>('reader-content-surface')),
            ),
          ),
      isTrue,
    );
    expect(find.text('正在定位上一章末页'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 16));
  });

  testWidgets('idle adjacent layout hit crosses without a boundary spinner', (
    WidgetTester tester,
  ) async {
    final controller = TextReaderController();
    final observer = _PerformanceObserver();
    await tester.pumpWidget(
      MaterialApp(
        home: TextReaderView(
          controller: controller,
          bookId: 'adjacent-hit',
          dataSource: const _PreviousChapterDataSource(),
          stateStore: const _EmptyStateStore(),
          observer: observer,
        ),
      ),
    );
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 450));
    });
    for (var index = 0; index < 12; index++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    unawaited(controller.nextChapter());
    await tester.pump();
    expect(controller.snapshot.chapter?.id, 'chapter-2');
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pump(const Duration(milliseconds: 16));
    final transitions = observer.events
        .where(
          (event) =>
              event.phase == ReaderChapterPerformancePhase.chapterTransition,
        )
        .toList();
    expect(
      transitions.map((event) => event.outcome),
      <ReaderChapterPerformanceOutcome>[
        ReaderChapterPerformanceOutcome.started,
        ReaderChapterPerformanceOutcome.success,
      ],
    );
    expect(transitions.last.cacheHit, isTrue);
    expect(
      observer.events
          .where(
            (event) =>
                event.phase ==
                ReaderChapterPerformancePhase.adjacentPreparation,
          )
          .map((event) => event.outcome),
      <ReaderChapterPerformanceOutcome>[
        ReaderChapterPerformanceOutcome.started,
        ReaderChapterPerformanceOutcome.success,
      ],
    );
  });

  testWidgets('delayed adjacent content keeps the transition spinner', (
    WidgetTester tester,
  ) async {
    final controller = TextReaderController();
    await tester.pumpWidget(
      MaterialApp(
        home: TextReaderView(
          controller: controller,
          bookId: 'adjacent-miss',
          dataSource: const _DelayedAdjacentDataSource(),
          stateStore: const _EmptyStateStore(),
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    await tester.drag(
      find.byKey(const ValueKey<String>('reader-content-surface')),
      const Offset(-700, 0),
    );
    await tester.pump(const Duration(milliseconds: 80));
    expect(controller.snapshot.chapter?.id, 'chapter-1');
    expect(find.byType(CircularProgressIndicator), findsWidgets);
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 900));
    });
    for (var index = 0; index < 4; index++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pumpAndSettle();
    expect(controller.snapshot.chapter?.id, 'chapter-2');
  });

  testWidgets('vertical scrolling does not start adjacent text pagination', (
    WidgetTester tester,
  ) async {
    final observer = _PerformanceObserver();
    await tester.pumpWidget(
      MaterialApp(
        home: TextReaderView(
          bookId: 'vertical-no-adjacent-layout',
          dataSource: const _PreviousChapterDataSource(),
          stateStore: const _VerticalStateStore(),
          observer: observer,
        ),
      ),
    );
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    for (var index = 0; index < 20; index += 1) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(observer.adjacentOutcomes, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
}

final class _FirstFrameObserver extends ReaderObserver {
  final List<ReaderFirstContentPresentation> presentations =
      <ReaderFirstContentPresentation>[];
  @override
  void onFirstContentPresented(ReaderFirstContentPresentation presentation) {
    presentations.add(presentation);
  }
}

class _PerformanceObserver extends ReaderObserver {
  final List<ReaderChapterPerformanceEvent> events =
      <ReaderChapterPerformanceEvent>[];

  @override
  void onChapterPerformance(ReaderChapterPerformanceEvent event) {
    events.add(event);
  }

  List<ReaderChapterPerformanceOutcome> get adjacentOutcomes => events
      .where(
        (event) =>
            event.phase == ReaderChapterPerformancePhase.adjacentPreparation,
      )
      .map((event) => event.outcome)
      .toList(growable: false);
}

class _InitialChapterDataSource implements TextReaderDataSource {
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

final class _VerticalStateStore extends _EmptyStateStore {
  const _VerticalStateStore();

  @override
  Future<TextReaderPreferences?> loadPreferences() async =>
      const TextReaderPreferences(
        keepScreenOn: false,
        navigationMode: ReaderNavigationMode.verticalScroll,
      );
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

final class _FixedProgressStateStore extends _EmptyStateStore {
  const _FixedProgressStateStore(this.progress);

  final ReaderProgress progress;

  @override
  Future<ReaderProgress?> loadProgress(String bookId) async => progress;
}

final class _DenseChapterDataSource extends _InitialChapterDataSource {
  const _DenseChapterDataSource();

  @override
  Future<TextChapterContent> loadChapterContent(
    String bookId,
    String chapterId,
  ) async => TextChapterContent(
    chapterId: 'chapter-1',
    title: '第一章',
    paragraphs: <TextParagraph>[
      TextParagraph(
        id: 'paragraph-1',
        text: List<String>.filled(700, '正文').join(),
      ),
    ],
  );
}

class _PreviousChapterDataSource implements TextReaderDataSource {
  const _PreviousChapterDataSource();

  static const String tail = '第一章末尾标记';
  static const ReaderChapterInfo _first = ReaderChapterInfo(
    id: 'chapter-1',
    title: '第一章',
    index: 0,
  );
  static const ReaderChapterInfo _second = ReaderChapterInfo(
    id: 'chapter-2',
    title: '第二章',
    index: 1,
  );

  @override
  Future<ReaderBookInfo> loadBookInfo(String bookId) async =>
      ReaderBookInfo(id: bookId, title: '跨章测试书');

  @override
  Future<ChapterCatalogPage> loadChapterCatalog(
    String bookId, {
    String? cursor,
    int pageSize = 100,
  }) async => ChapterCatalogPage(
    items: <ReaderChapterInfo>[_first, _second],
    total: 2,
    hasMore: false,
  );

  @override
  Future<ReaderChapterInfo> loadChapterAtIndex(String bookId, int index) async {
    if (index == 0) return _first;
    if (index == 1) return _second;
    throw RangeError.index(index, const <int>[0, 1]);
  }

  @override
  Future<TextChapterContent> loadChapterContent(
    String bookId,
    String chapterId,
  ) => SynchronousFuture<TextChapterContent>(switch (chapterId) {
    'chapter-1' => TextChapterContent(
      chapterId: chapterId,
      title: '第一章',
      paragraphs: <TextParagraph>[
        for (var index = 0; index < 8; index++)
          TextParagraph(
            id: 'chapter-1-$index',
            text: List<String>.filled(80, '正文').join(),
          ),
        const TextParagraph(id: 'chapter-1-tail', text: tail),
      ],
    ),
    'chapter-2' => TextChapterContent(
      chapterId: 'chapter-2',
      title: '第二章',
      paragraphs: <TextParagraph>[
        TextParagraph(id: 'chapter-2-body', text: '第二章正文'),
      ],
    ),
    _ => throw StateError('Unknown chapter.'),
  });
}

final class _DelayedAdjacentDataSource extends _PreviousChapterDataSource {
  const _DelayedAdjacentDataSource();

  @override
  Future<TextChapterContent> loadChapterContent(
    String bookId,
    String chapterId,
  ) async {
    if (chapterId == 'chapter-1') {
      return TextChapterContent(
        chapterId: chapterId,
        title: '第一章',
        paragraphs: <TextParagraph>[
          TextParagraph(id: 'chapter-1-body', text: '第一章短正文'),
        ],
      );
    }
    if (chapterId == 'chapter-2') {
      await Future<void>.delayed(const Duration(milliseconds: 280));
    }
    return super.loadChapterContent(bookId, chapterId);
  }
}
