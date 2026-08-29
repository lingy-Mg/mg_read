/// 相邻章节空闲预排版取消状态测试。
///
/// 职责：
/// - 验证后台、内存压力、宿主卸载、布局变化和快速导航取消旧任务。
/// - 验证每个被取消任务只有一个 start 和一个 cancelled 终态。
///
/// 注意：
/// - 在 started 回调内触发失效条件，避免依赖测试调度器的 idle 时序。
///
/// TODO:
/// - 无。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
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

  testWidgets('real interaction restarts the adjacent quiet window', (
    WidgetTester tester,
  ) async {
    final observer = _CancellationObserver(onStarted: () {});
    final controller = TextReaderController();
    await tester.pumpWidget(
      MaterialApp(
        home: TextReaderView(
          bookId: 'interaction-quiet-window',
          dataSource: const _ShortInitialAdjacentDataSource(),
          stateStore: const _CancellationStateStore(),
          observer: observer,
          controller: controller,
        ),
      ),
    );
    for (var index = 0; index < 12 && !controller.snapshot.isReady; index++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(controller.snapshot.isReady, isTrue);
    await tester.pump(const Duration(milliseconds: 16));
    await tester.tap(
      find.byKey(const ValueKey<String>('reader-content-surface')),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(observer.adjacentOutcomes, isEmpty);
    await tester.pump(const Duration(milliseconds: 60));
    expect(observer.adjacentOutcomes, isNotEmpty);
    await _disposeAndDrain(tester);
  });

  testWidgets('long adjacent layout yields a painted frame before completion', (
    WidgetTester tester,
  ) async {
    final observer = _FrameYieldObserver();
    await tester.pumpWidget(
      MaterialApp(
        home: TextReaderView(
          bookId: 'adjacent-frame-yield',
          dataSource: const _CancellationDataSource(),
          stateStore: const _CancellationStateStore(),
          observer: observer,
        ),
      ),
    );
    for (var index = 0; index < 240 && !observer.completed; index += 1) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(observer.completed, isTrue);
    expect(observer.frameRanBeforeCompletion, isTrue);
    await _disposeAndDrain(tester);
  });

  testWidgets('background cancels adjacent preparation exactly once', (
    WidgetTester tester,
  ) async {
    late _CancellationObserver observer;
    observer = _CancellationObserver(
      onStarted: () => tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.paused,
      ),
    );
    await _pumpCancellationReader(tester, 'background-cancel', observer);
    expect(observer.adjacentOutcomes, _startedThenCancelled);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _disposeAndDrain(tester);
  });

  testWidgets('background cancellation resumes on foreground', (
    WidgetTester tester,
  ) async {
    var firstStart = true;
    final observer = _CancellationObserver(
      onStarted: () {
        if (firstStart) {
          firstStart = false;
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.paused,
          );
        }
      },
    );
    final controller = TextReaderController();
    await _pumpCancellationReader(
      tester,
      'background-resume',
      observer,
      controller: controller,
    );
    expect(observer.adjacentOutcomes, _startedThenCancelled);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    for (var index = 0; index < 60; index += 1) {
      await tester.pump(const Duration(milliseconds: 16));
      if (observer.adjacentOutcomes.length >= 4) break;
    }
    expect(observer.adjacentOutcomes, <ReaderChapterPerformanceOutcome>[
      ReaderChapterPerformanceOutcome.started,
      ReaderChapterPerformanceOutcome.cancelled,
      ReaderChapterPerformanceOutcome.started,
      ReaderChapterPerformanceOutcome.success,
    ]);
    expect(controller.snapshot.isReady, isTrue);
    await _disposeAndDrain(tester);
  });

  testWidgets('memory pressure cancels adjacent preparation exactly once', (
    WidgetTester tester,
  ) async {
    late _CancellationObserver observer;
    observer = _CancellationObserver(
      onStarted: tester.binding.handleMemoryPressure,
    );
    await _pumpCancellationReader(tester, 'pressure-cancel', observer);
    expect(observer.adjacentOutcomes, _startedThenCancelled);
    await _disposeAndDrain(tester);
  });

  testWidgets('memory pressure resumes on a later page change', (
    WidgetTester tester,
  ) async {
    late _CancellationObserver observer;
    final controller = TextReaderController();
    observer = _CancellationObserver(
      onStarted: tester.binding.handleMemoryPressure,
    );
    await _pumpCancellationReader(
      tester,
      'pressure-resume',
      observer,
      controller: controller,
    );
    expect(observer.adjacentOutcomes, _startedThenCancelled);
    unawaited(controller.nextPage());
    for (var index = 0; index < 180; index += 1) {
      await tester.pump(const Duration(milliseconds: 16));
      if (observer.adjacentOutcomes.length >= 4) break;
    }
    expect(observer.adjacentOutcomes, <ReaderChapterPerformanceOutcome>[
      ReaderChapterPerformanceOutcome.started,
      ReaderChapterPerformanceOutcome.cancelled,
      ReaderChapterPerformanceOutcome.started,
      ReaderChapterPerformanceOutcome.success,
    ]);
    unawaited(controller.nextChapter());
    await tester.pump();
    expect(controller.snapshot.chapter?.id, 'chapter-2');
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await _disposeAndDrain(tester);
  });

  testWidgets(
    'failed adjacent content retries only after an explicit trigger',
    (WidgetTester tester) async {
      final source = _RetryAdjacentDataSource(failures: 1);
      final observer = _CancellationObserver(onStarted: () {});
      final controller = TextReaderController();
      await tester.pumpWidget(
        MaterialApp(
          home: TextReaderView(
            bookId: 'adjacent-retry',
            dataSource: source,
            stateStore: const _CancellationStateStore(),
            observer: observer,
            controller: controller,
          ),
        ),
      );
      for (
        var index = 0;
        index < 60 && source.chapter2Attempts < 1;
        index += 1
      ) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(source.chapter2Attempts, 1);
      await tester.pump(const Duration(milliseconds: 160));
      expect(source.chapter2Attempts, 1);
      unawaited(controller.nextPage());
      for (
        var index = 0;
        index < 80 && observer.adjacentOutcomes.length < 2;
        index += 1
      ) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(source.chapter2Attempts, 2);
      expect(observer.adjacentOutcomes, <ReaderChapterPerformanceOutcome>[
        ReaderChapterPerformanceOutcome.started,
        ReaderChapterPerformanceOutcome.success,
      ]);
      unawaited(controller.nextChapter());
      await tester.pump();
      expect(controller.snapshot.chapter?.id, 'chapter-2');
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await _disposeAndDrain(tester);
    },
  );

  testWidgets('repeated adjacent content failure does not self-loop', (
    WidgetTester tester,
  ) async {
    final source = _RetryAdjacentDataSource(failures: 3);
    final observer = _CancellationObserver(onStarted: () {});
    await tester.pumpWidget(
      MaterialApp(
        home: TextReaderView(
          bookId: 'adjacent-no-loop',
          dataSource: source,
          stateStore: const _CancellationStateStore(),
          observer: observer,
        ),
      ),
    );
    for (var index = 0; index < 60 && source.chapter2Attempts < 1; index += 1) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pump(const Duration(milliseconds: 500));
    expect(source.chapter2Attempts, 1);
    expect(observer.adjacentOutcomes, isEmpty);
    await _disposeAndDrain(tester);
  });

  testWidgets('dispose cancels adjacent preparation exactly once', (
    WidgetTester tester,
  ) async {
    var visible = true;
    late StateSetter updateHost;
    late _CancellationObserver observer;
    observer = _CancellationObserver(
      onStarted: () => updateHost(() => visible = false),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) {
            updateHost = setState;
            return visible
                ? TextReaderView(
                    bookId: 'dispose-cancel',
                    dataSource: const _CancellationDataSource(),
                    stateStore: const _CancellationStateStore(),
                    observer: observer,
                  )
                : const SizedBox();
          },
        ),
      ),
    );
    await _pumpForAdjacentTerminal(tester, observer);
    expect(observer.adjacentOutcomes, _startedThenCancelled);
  });

  testWidgets('text scaling invalidates adjacent preparation exactly once', (
    WidgetTester tester,
  ) async {
    var scale = 1.0;
    late StateSetter updateHost;
    late _CancellationObserver observer;
    observer = _CancellationObserver(
      onStarted: () => updateHost(() => scale = 1.25),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) {
            updateHost = setState;
            return MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: TextReaderView(
                bookId: 'scale-cancel',
                dataSource: const _CancellationDataSource(),
                stateStore: const _CancellationStateStore(),
                observer: observer,
              ),
            );
          },
        ),
      ),
    );
    await _pumpForAdjacentTerminal(tester, observer);
    expect(observer.adjacentOutcomes.take(2), _startedThenCancelled);
    expect(
      observer.adjacentOutcomes
          .where(
            (outcome) => outcome == ReaderChapterPerformanceOutcome.cancelled,
          )
          .length,
      1,
    );
    for (
      var index = 0;
      index < 80 && observer.adjacentOutcomes.length < 4;
      index += 1
    ) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(observer.adjacentOutcomes, <ReaderChapterPerformanceOutcome>[
      ReaderChapterPerformanceOutcome.started,
      ReaderChapterPerformanceOutcome.cancelled,
      ReaderChapterPerformanceOutcome.started,
      ReaderChapterPerformanceOutcome.success,
    ]);
    await _disposeAndDrain(tester);
  });

  testWidgets('rapid chapter navigation cancels stale adjacent preparation', (
    WidgetTester tester,
  ) async {
    final controller = TextReaderController();
    late _CancellationObserver observer;
    observer = _CancellationObserver(
      onStarted: () => unawaited(controller.nextChapter()),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: TextReaderView(
          bookId: 'navigation-cancel',
          dataSource: const _CancellationDataSource(),
          stateStore: const _CancellationStateStore(),
          observer: observer,
          controller: controller,
        ),
      ),
    );
    await _pumpForAdjacentTerminal(tester, observer);
    expect(observer.adjacentOutcomes, _startedThenCancelled);
    await _disposeAndDrain(tester);
  });
}

const List<ReaderChapterPerformanceOutcome> _startedThenCancelled =
    <ReaderChapterPerformanceOutcome>[
      ReaderChapterPerformanceOutcome.started,
      ReaderChapterPerformanceOutcome.cancelled,
    ];

Future<void> _pumpCancellationReader(
  WidgetTester tester,
  String bookId,
  _CancellationObserver observer, {
  TextReaderController? controller,
}) async {
  final TextReaderController readerController =
      controller ?? TextReaderController();
  await tester.pumpWidget(
    MaterialApp(
      home: TextReaderView(
        bookId: bookId,
        dataSource: const _CancellationDataSource(),
        stateStore: const _CancellationStateStore(),
        observer: observer,
        controller: readerController,
      ),
    ),
  );
  await _pumpForAdjacentTerminal(
    tester,
    observer,
    controller: readerController,
  );
}

Future<void> _pumpForAdjacentTerminal(
  WidgetTester tester,
  _CancellationObserver observer, {
  TextReaderController? controller,
}) async {
  for (var index = 0; index < 60; index += 1) {
    await tester.pump(const Duration(milliseconds: 16));
    if (observer.adjacentOutcomes.length >= 2) {
      await tester.pump(const Duration(milliseconds: 1));
      return;
    }
  }
  fail(
    'Adjacent preparation did not emit a terminal event: '
    '${observer.adjacentOutcomes}; ready=${controller?.snapshot.isReady}; '
    'chapter=${controller?.snapshot.chapter?.id}; '
    'failure=${controller?.snapshot.failure?.kind}; '
    'cause=${observer.failures.lastOrNull?.cause}.',
  );
}

Future<void> _disposeAndDrain(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(milliseconds: 1));
}

final class _CancellationObserver extends ReaderObserver {
  _CancellationObserver({required this.onStarted});

  final VoidCallback onStarted;
  final List<ReaderChapterPerformanceEvent> events =
      <ReaderChapterPerformanceEvent>[];
  final List<ReaderFailure> failures = <ReaderFailure>[];
  bool _actionInvoked = false;

  List<ReaderChapterPerformanceOutcome> get adjacentOutcomes => events
      .where(
        (event) =>
            event.phase == ReaderChapterPerformancePhase.adjacentPreparation,
      )
      .map((event) => event.outcome)
      .toList(growable: false);

  @override
  void onChapterPerformance(ReaderChapterPerformanceEvent event) {
    events.add(event);
    if (!_actionInvoked &&
        event.phase == ReaderChapterPerformancePhase.adjacentPreparation &&
        event.outcome == ReaderChapterPerformanceOutcome.started) {
      _actionInvoked = true;
      onStarted();
    }
  }

  @override
  void onFailure(ReaderFailure failure) {
    failures.add(failure);
  }
}

final class _FrameYieldObserver extends ReaderObserver {
  bool completed = false;
  bool frameRanBeforeCompletion = false;
  bool _frameRan = false;

  @override
  void onChapterPerformance(ReaderChapterPerformanceEvent event) {
    if (event.phase != ReaderChapterPerformancePhase.adjacentPreparation) {
      return;
    }
    if (event.outcome == ReaderChapterPerformanceOutcome.started) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _frameRan = true);
      WidgetsBinding.instance.scheduleFrame();
    } else if (event.outcome == ReaderChapterPerformanceOutcome.success) {
      completed = true;
      frameRanBeforeCompletion = _frameRan;
    }
  }
}

class _CancellationDataSource implements TextReaderDataSource {
  const _CancellationDataSource();

  static const _first = ReaderChapterInfo(
    id: 'chapter-1',
    title: '第一章',
    index: 0,
  );
  static const _second = ReaderChapterInfo(
    id: 'chapter-2',
    title: '第二章',
    index: 1,
  );

  @override
  Future<ReaderBookInfo> loadBookInfo(String bookId) async =>
      ReaderBookInfo(id: bookId, title: '取消测试');

  @override
  Future<ChapterCatalogPage> loadChapterCatalog(
    String bookId, {
    String? cursor,
    int pageSize = 100,
  }) async => ChapterCatalogPage(
    items: const <ReaderChapterInfo>[_first, _second],
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
  ) => SynchronousFuture(
    TextChapterContent(
      chapterId: chapterId,
      title: chapterId == 'chapter-1' ? '第一章' : '第二章',
      paragraphs: chapterId == 'chapter-1'
          ? <TextParagraph>[
              for (var index = 0; index < 8; index += 1)
                TextParagraph(
                  id: 'chapter-1-$index',
                  text: List<String>.filled(80, '正文').join(),
                ),
              const TextParagraph(id: 'chapter-1-tail', text: '第一章末尾'),
            ]
          : <TextParagraph>[
              for (var index = 0; index < 33; index += 1)
                TextParagraph(
                  id: 'chapter-2-$index',
                  text: List<String>.filled(80, '第二章正文').join(),
                ),
            ],
    ),
  );
}

final class _RetryAdjacentDataSource extends _CancellationDataSource {
  _RetryAdjacentDataSource({required this.failures});

  final int failures;
  int chapter2Attempts = 0;

  @override
  Future<TextChapterContent> loadChapterContent(
    String bookId,
    String chapterId,
  ) {
    if (chapterId == 'chapter-2') {
      chapter2Attempts += 1;
      if (chapter2Attempts <= failures) {
        return Future<TextChapterContent>.error(StateError('retry'));
      }
    }
    return super.loadChapterContent(bookId, chapterId);
  }
}

final class _ShortInitialAdjacentDataSource extends _CancellationDataSource {
  const _ShortInitialAdjacentDataSource();

  @override
  Future<TextChapterContent> loadChapterContent(
    String bookId,
    String chapterId,
  ) {
    if (chapterId == 'chapter-1') {
      return SynchronousFuture(
        TextChapterContent(
          chapterId: chapterId,
          title: '第一章',
          paragraphs: const <TextParagraph>[
            TextParagraph(id: 'chapter-1-short', text: '短正文'),
          ],
        ),
      );
    }
    return super.loadChapterContent(bookId, chapterId);
  }
}

final class _CancellationStateStore implements TextReaderStateStore {
  const _CancellationStateStore();

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
