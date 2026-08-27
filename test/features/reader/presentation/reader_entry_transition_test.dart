/// 阅读器入场承载层测试。
///
/// 职责：
/// - 验证首帧、慢加载、失败、返回与减少动态效果的宿主交接。
/// - 只通过 Widget Finder 和公开阅读器契约驱动会话。
///
/// 注意：
/// - 测试不依赖真实 Runtime、网络、正文持久化或平台动画时钟。
///
/// TODO:
/// - 无。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/reader/application/reader_launch_request.dart';
import 'package:mg_read/features/reader/presentation/reader_entry_transition.dart';

void main() {
  testWidgets('hands off the first text frame once without a blank reader', (WidgetTester tester) async {
    final _RecordingObserver observer = _RecordingObserver();
    await tester.pumpWidget(_readerApp(_request(dataSource: const _ImmediateDataSource(), observer: observer)));

    await _pumpReader(tester);

    expect(find.textContaining('第一章正文'), findsOneWidget);
    expect(find.byKey(const Key('reader-entry-back')), findsNothing);
    expect(observer.firstFrames, hasLength(1));
    expect(find.text('正在准备正文'), findsNothing);
  });

  testWidgets('keeps the supplied cover visible while text is still loading', (WidgetTester tester) async {
    final _ControlledDataSource dataSource = _ControlledDataSource();
    final _RecordingObserver observer = _RecordingObserver();
    await tester.pumpWidget(_readerApp(_request(dataSource: dataSource, observer: observer)));
    await tester.pump(const Duration(milliseconds: 480));

    expect(find.byKey(const Key('reader-entry-status')), findsNothing);
    expect(find.textContaining('第一章正文'), findsNothing);

    await tester.tap(find.byKey(const Key('reader-entry-back')));
    await tester.pump();
    expect(observer.exitRequests, 1);
    dataSource.complete();
  });

  testWidgets('renders the entry cover from local bytes without network loading', (WidgetTester tester) async {
    await tester.pumpWidget(_readerApp(_request(dataSource: _ControlledDataSource(), coverBytes: _onePixelPng)));
    await tester.pump();

    expect(find.byWidgetPredicate((Widget widget) => widget is Image && widget.image is MemoryImage), findsOneWidget);
    expect(find.byKey(const Key('reader-entry-status')), findsNothing);
  });

  testWidgets('keeps initial failures in the carrier and retries the reader', (WidgetTester tester) async {
    final _FailThenSucceedDataSource dataSource = _FailThenSucceedDataSource();
    await tester.pumpWidget(_readerApp(_request(dataSource: dataSource)));

    await _pumpReader(tester);
    expect(find.byKey(const Key('reader-entry-retry')), findsOneWidget);

    dataSource.succeedOnNextRequest = true;
    await tester.tap(find.byKey(const Key('reader-entry-retry')));
    await _pumpReader(tester);
    expect(find.textContaining('第一章正文'), findsOneWidget);
  });

  testWidgets('reduce motion completes the handoff without waiting for a tween', (WidgetTester tester) async {
    await tester.pumpWidget(_readerApp(_request(dataSource: const _ImmediateDataSource()), reduceMotion: true));

    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('第一章正文'), findsOneWidget);
    expect(find.byKey(const Key('reader-entry-back')), findsNothing);
  });
}

Widget _readerApp(ReaderLaunchRequest request, {bool reduceMotion = false}) => MaterialApp(
  theme: AppTheme.light(),
  builder: (BuildContext context, Widget? child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
    child: child!,
  ),
  home: ReaderEntryTransition(request: request),
);

Future<void> _pumpReader(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 160));
  await tester.pump(const Duration(milliseconds: 220));
  await tester.pump(const Duration(milliseconds: 220));
}

ReaderLaunchRequest _request({required TextReaderDataSource dataSource, ReaderObserver? observer, List<int>? coverBytes}) =>
    ReaderLaunchRequest(
      bookId: 'reader-entry-test-book',
      dataSource: dataSource,
      stateStore: const _StateStore(),
      observer: observer,
      entryCoverBytes: coverBytes,
    );

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

class _RecordingObserver extends ReaderObserver {
  final List<ReaderFirstContentPresentation> firstFrames = <ReaderFirstContentPresentation>[];
  int exitRequests = 0;

  @override
  void onFirstContentPresented(ReaderFirstContentPresentation presentation) {
    firstFrames.add(presentation);
  }

  @override
  void onExitRequested(ReaderProgress? progress) {
    exitRequests++;
  }
}

class _ImmediateDataSource implements TextReaderDataSource {
  const _ImmediateDataSource();

  static const ReaderChapterInfo _chapter = ReaderChapterInfo(id: 'chapter-1', title: '第一章', index: 0);

  @override
  Future<ReaderBookInfo> loadBookInfo(String bookId) async => ReaderBookInfo(id: bookId, title: '测试书籍');

  @override
  Future<ChapterCatalogPage> loadChapterCatalog(String bookId, {String? cursor, int pageSize = 100}) async =>
      ChapterCatalogPage(items: const <ReaderChapterInfo>[_chapter], total: 1, hasMore: false);

  @override
  Future<ReaderChapterInfo> loadChapterAtIndex(String bookId, int index) async => _chapter;

  @override
  Future<TextChapterContent> loadChapterContent(String bookId, String chapterId) async => _content();
}

class _ControlledDataSource extends _ImmediateDataSource {
  final Completer<TextChapterContent> _content = Completer<TextChapterContent>();

  @override
  Future<TextChapterContent> loadChapterContent(String bookId, String chapterId) => _content.future;

  void complete() {
    if (!_content.isCompleted) _content.complete(_contentValue());
  }
}

class _FailThenSucceedDataSource extends _ImmediateDataSource {
  bool succeedOnNextRequest = false;

  @override
  Future<TextChapterContent> loadChapterContent(String bookId, String chapterId) async {
    if (!succeedOnNextRequest) throw StateError('expected reader test failure');
    return _content();
  }
}

TextChapterContent _content() => TextChapterContent(
  chapterId: 'chapter-1',
  title: '第一章',
  paragraphs: <TextParagraph>[TextParagraph(id: 'paragraph-1', text: '第一章正文。用于验证首次交接。')],
);

TextChapterContent _contentValue() => _content();

class _StateStore implements TextReaderStateStore {
  const _StateStore();

  @override
  Future<void> addBookmark(ReaderBookmark bookmark) async {}

  @override
  Future<ReaderProgress?> loadProgress(String bookId) async => null;

  @override
  Future<List<ReaderBookmark>> loadBookmarks(String bookId) async => const <ReaderBookmark>[];

  @override
  Future<TextReaderPreferences?> loadPreferences() async => const TextReaderPreferences(keepScreenOn: false);

  @override
  Future<void> removeBookmark(String bookId, String bookmarkId) async {}

  @override
  Future<void> savePreferences(TextReaderPreferences preferences) async {}

  @override
  Future<void> saveProgress(String bookId, ReaderProgress progress) async {}
}
