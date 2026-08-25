/// 阅读器相邻章节空闲预排版 Android 验收。
///
/// 职责：
/// - 验证预排版命中时跨章不出现边界加载动画。
/// - 验证预排版未完成时保留加载动画和可恢复路径。
/// - 记录跨章耗时、缓存命中方式与测试绑定截图。
///
/// 注意：
/// - 交互仅通过稳定 Key 和 WidgetTester 手势完成。
/// - 耗时只作为机器可读证据，不设置主观毫秒门槛。
///
/// TODO:
/// - 无。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final results = <String, Object?>{};

  testWidgets('预排版命中后直接跨章，并支持快速反向操作', (tester) async {
    final controller = TextReaderController();
    final source = _AdjacentDataSource();
    final observer = _PerformanceObserver();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.light(),
        home: TextReaderView(
          bookId: 'integration-adjacent-hit',
          dataSource: source,
          stateStore: const _MemoryStateStore(),
          controller: controller,
          observer: observer,
        ),
      ),
    );

    await _pumpUntil(
      tester,
      () => observer.hasTerminal(ReaderChapterPerformancePhase.adjacentPreparation, ReaderChapterPerformanceOutcome.success),
    );
    expect(source.chapterTwoRequests, 1);

    await _swipeLeft(tester);
    await _pumpUntil(tester, () => controller.snapshot.chapter?.id == 'chapter-2');
    expect(find.byType(CircularProgressIndicator), findsNothing);
    final hitTransition = observer.latestSuccessfulTransition;
    expect(hitTransition, isNotNull);
    expect(hitTransition!.cacheHit, isTrue);
    expect(hitTransition.preparationKind, ReaderChapterPreparationKind.cachedLayout);
    await binding.takeScreenshot('reader_adjacent_prelayout_hit_light');

    await _swipeRight(tester);
    await _pumpUntil(tester, () => controller.snapshot.chapter?.id == 'chapter-1');
    await _swipeLeft(tester);
    await _pumpUntil(tester, () => controller.snapshot.chapter?.id == 'chapter-2');
    expect(tester.takeException(), isNull);

    results['prelayoutHit'] = <String, Object?>{
      'chapterTwoContentRequests': source.chapterTwoRequests,
      'cacheHit': hitTransition.cacheHit,
      'preparationKind': hitTransition.preparationKind.name,
      'transitionDurationMicros': hitTransition.duration.inMicroseconds,
      'pageCount': hitTransition.pageCount,
      'spinnerObserved': false,
      'rapidReverseCompleted': true,
    };
  });

  testWidgets('预排版未完成时显示边界加载并在正文到达后恢复', (tester) async {
    final controller = TextReaderController();
    final source = _AdjacentDataSource(chapterTwoDelay: const Duration(milliseconds: 900));
    final observer = _PerformanceObserver();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.light(),
        home: TextReaderView(
          bookId: 'integration-adjacent-miss',
          dataSource: source,
          stateStore: const _MemoryStateStore(),
          controller: controller,
          observer: observer,
        ),
      ),
    );
    await _pumpUntil(tester, () => controller.snapshot.chapter?.id == 'chapter-1');

    await _swipeLeft(tester);
    await tester.pump(const Duration(milliseconds: 80));
    expect(controller.snapshot.chapter?.id, 'chapter-1');
    expect(find.byType(CircularProgressIndicator), findsWidgets);
    await binding.takeScreenshot('reader_adjacent_prelayout_fallback_light');

    await tester.pump(const Duration(seconds: 1));
    await _pumpUntil(tester, () => controller.snapshot.chapter?.id == 'chapter-2');
    final fallbackTransition = observer.latestSuccessfulTransition;
    expect(fallbackTransition, isNotNull);
    expect(fallbackTransition!.cacheHit, isFalse);
    expect(fallbackTransition.preparationKind, ReaderChapterPreparationKind.foregroundLayout);
    expect(source.chapterTwoRequests, 1);

    results['foregroundFallback'] = <String, Object?>{
      'chapterTwoContentRequests': source.chapterTwoRequests,
      'cacheHit': fallbackTransition.cacheHit,
      'preparationKind': fallbackTransition.preparationKind.name,
      'transitionDurationMicros': fallbackTransition.duration.inMicroseconds,
      'pageCount': fallbackTransition.pageCount,
      'spinnerObserved': true,
      'recovered': true,
    };
    binding.reportData = <String, Object?>{
      'schemaVersion': 1,
      'metric': 'readerAdjacentChapterTransition',
      'thresholdMicros': null,
      'scenarios': results,
    };
  });
}

Future<void> _swipeLeft(WidgetTester tester) async {
  final surface = find.byKey(const ValueKey<String>('reader-content-surface')).hitTestable().first;
  expect(surface, findsOneWidget);
  await tester.drag(surface, const Offset(-700, 0));
  await tester.pump(const Duration(milliseconds: 20));
}

Future<void> _swipeRight(WidgetTester tester) async {
  final surface = find.byKey(const ValueKey<String>('reader-content-surface')).hitTestable().first;
  expect(surface, findsOneWidget);
  await tester.drag(surface, const Offset(700, 0));
  await tester.pump(const Duration(milliseconds: 20));
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() predicate) async {
  for (var attempt = 0; attempt < 600; attempt += 1) {
    if (predicate()) return;
    await tester.pump(const Duration(milliseconds: 16));
  }
  fail('Timed out waiting for adjacent chapter state.');
}

final class _PerformanceObserver extends ReaderObserver {
  final List<ReaderChapterPerformanceEvent> events = <ReaderChapterPerformanceEvent>[];

  @override
  void onChapterPerformance(ReaderChapterPerformanceEvent event) {
    events.add(event);
  }

  bool hasTerminal(ReaderChapterPerformancePhase phase, ReaderChapterPerformanceOutcome outcome) =>
      events.any((event) => event.phase == phase && event.outcome == outcome);

  ReaderChapterPerformanceEvent? get latestSuccessfulTransition {
    for (final event in events.reversed) {
      if (event.phase == ReaderChapterPerformancePhase.chapterTransition && event.outcome == ReaderChapterPerformanceOutcome.success) {
        return event;
      }
    }
    return null;
  }
}

final class _AdjacentDataSource implements TextReaderDataSource {
  _AdjacentDataSource({this.chapterTwoDelay = Duration.zero});

  static const _first = ReaderChapterInfo(id: 'chapter-1', title: '第一章', index: 0);
  static const _second = ReaderChapterInfo(id: 'chapter-2', title: '第二章', index: 1);

  final Duration chapterTwoDelay;
  int chapterTwoRequests = 0;

  @override
  Future<ReaderBookInfo> loadBookInfo(String bookId) => SynchronousFuture(ReaderBookInfo(id: bookId, title: '跨章验收'));

  @override
  Future<ChapterCatalogPage> loadChapterCatalog(String bookId, {String? cursor, int pageSize = 100}) =>
      SynchronousFuture(ChapterCatalogPage(items: const <ReaderChapterInfo>[_first, _second], total: 2, hasMore: false));

  @override
  Future<ReaderChapterInfo> loadChapterAtIndex(String bookId, int index) {
    if (index == 0) return SynchronousFuture(_first);
    if (index == 1) return SynchronousFuture(_second);
    throw RangeError.index(index, const <int>[0, 1]);
  }

  @override
  Future<TextChapterContent> loadChapterContent(String bookId, String chapterId) async {
    if (chapterId == 'chapter-1') {
      return TextChapterContent(
        chapterId: 'chapter-1',
        title: '第一章',
        paragraphs: const <TextParagraph>[TextParagraph(id: 'chapter-1-body', text: '第一章末页。')],
      );
    }
    chapterTwoRequests += 1;
    if (chapterTwoDelay > Duration.zero) {
      await Future<void>.delayed(chapterTwoDelay);
    }
    return TextChapterContent(
      chapterId: 'chapter-2',
      title: '第二章',
      paragraphs: <TextParagraph>[
        for (var index = 0; index < 33; index += 1) TextParagraph(id: 'chapter-2-$index', text: List<String>.filled(80, '第二章正文').join()),
      ],
    );
  }
}

final class _MemoryStateStore implements TextReaderStateStore {
  const _MemoryStateStore();

  @override
  Future<List<ReaderBookmark>> loadBookmarks(String bookId) => SynchronousFuture(const <ReaderBookmark>[]);

  @override
  Future<TextReaderPreferences?> loadPreferences() => SynchronousFuture(const TextReaderPreferences(keepScreenOn: false));

  @override
  Future<ReaderProgress?> loadProgress(String bookId) => SynchronousFuture(null);

  @override
  Future<void> addBookmark(ReaderBookmark bookmark) async {}

  @override
  Future<void> removeBookmark(String bookId, String bookmarkId) async {}

  @override
  Future<void> savePreferences(TextReaderPreferences preferences) async {}

  @override
  Future<void> saveProgress(String bookId, ReaderProgress progress) async {}
}
