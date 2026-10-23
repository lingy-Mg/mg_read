import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';

void main() {
  for (final mode in ReaderNavigationMode.values) {
    testWidgets(
      'failed chapter can be retried without losing the anchor ($mode)',
      (tester) async {
        final source = _Source()..failure = StateError('网络波动');
        final controller = TextReaderController();
        await _mount(tester, source, controller, mode: mode);
        final before = controller.snapshot.progress;
        await controller.nextChapter();
        await tester.pump();

        expect(controller.snapshot.chapter?.id, 'c0');
        expect(controller.snapshot.progress?.paragraphId, before?.paragraphId);
        expect(find.text('章节加载失败'), findsOneWidget);
        expect(find.text('重试加载'), findsOneWidget);
        source.failure = null;
        await tester.tap(find.text('重试加载'));
        await _until(tester, () => controller.snapshot.chapter?.id == 'c1');
        expect(source.attempts['c1'], 2);
        expect(controller.snapshot.failure, isNull);
        expect(find.text('章节加载失败'), findsNothing);
        await _dispose(tester, controller);
      },
    );
  }

  testWidgets(
    'hung prefetch expires, manual retry starts fresh, late result is ignored',
    (tester) async {
      final old = Completer<TextChapterContent>();
      final source = _Source()..blocked = old;
      final controller = TextReaderController();
      await _mount(tester, source, controller, preload: 1);
      await _until(tester, () => source.attempts['c1'] == 1);
      await _until(tester, () => find.byType(PageView).evaluate().isNotEmpty);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.drag(find.byType(PageView), const Offset(-650, 0));
      await _until(
        tester,
        () =>
            (tester.widget<PageView>(find.byType(PageView)).controller!.page! -
                    2)
                .abs() <
            0.001,
      );
      for (var frame = 0; frame < 10; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(source.attempts['c1'], 1);
      await tester.pump(const Duration(seconds: 71));
      await tester.pump();
      expect(find.text('重试加载'), findsOneWidget);
      expect(controller.snapshot.chapter?.id, 'c0');

      source.blocked = null;
      await tester.tap(find.text('重试加载'));
      await _until(tester, () => controller.snapshot.chapter?.id == 'c1');
      expect(source.attempts['c1'], 2);
      old.complete(_content('c1', text: '迟到的旧正文'));
      await tester.pump();
      expect(find.textContaining('迟到的旧正文'), findsNothing);
      expect(controller.snapshot.chapter?.id, 'c1');
      expect(controller.snapshot.failure, isNull);
      await _dispose(tester, controller);
    },
  );

  testWidgets(
    'catalog lookup timeout releases navigation and retries the same index',
    (tester) async {
      final source = _Source()
        ..sparse = true
        ..blockInfo = true;
      final controller = TextReaderController();
      await _mount(tester, source, controller);
      unawaited(controller.nextChapter());
      await tester.pump();
      await tester.pump(const Duration(seconds: 71));
      await tester.pump();
      expect(find.text('重试加载'), findsOneWidget);
      expect(controller.snapshot.chapter?.id, 'c0');
      source.blockInfo = false;
      await tester.tap(find.text('重试加载'));
      await _until(tester, () => controller.snapshot.chapter?.id == 'c1');
      expect(source.infoAttempts, 2);
      await _dispose(tester, controller);
    },
  );

  testWidgets(
    'dismissing failure keeps the chapter readable and allows later navigation',
    (tester) async {
      final source = _Source()..failure = StateError('离线');
      final controller = TextReaderController();
      await _mount(tester, source, controller);
      await controller.nextChapter();
      await tester.pump();
      await tester.tap(find.text('继续阅读当前章'));
      await tester.pump();
      expect(controller.snapshot.chapter?.id, 'c0');
      expect(controller.snapshot.isReady, isTrue);
      expect(find.text('重试加载'), findsNothing);
      source.failure = null;
      await controller.nextChapter();
      await _until(tester, () => controller.snapshot.chapter?.id == 'c1');
      await _dispose(tester, controller);
    },
  );

  testWidgets('failure of an older navigation cannot cover a newer chapter', (
    tester,
  ) async {
    final old = Completer<TextChapterContent>();
    final source = _Source()..blocked = old;
    final controller = TextReaderController();
    await _mount(tester, source, controller);
    unawaited(controller.nextChapter());
    await tester.pump();
    await controller.openChapter('c2');
    await _until(tester, () => controller.snapshot.chapter?.id == 'c2');
    old.completeError(StateError('旧请求失败'));
    await tester.pump();
    expect(find.text('重试加载'), findsNothing);
    expect(controller.snapshot.failure, isNull);
    await _dispose(tester, controller);
  });

  testWidgets('first chapter failure retains the initial retry action', (
    tester,
  ) async {
    final source = _Source()..failInitial = true;
    final controller = TextReaderController();
    await _mount(tester, source, controller, expectReady: false);
    await _until(tester, () => find.text('重新加载').evaluate().isNotEmpty);
    source.failInitial = false;
    await tester.tap(find.text('重新加载'));
    await _until(tester, () => controller.snapshot.chapter?.id == 'c0');
    expect(controller.snapshot.failure, isNull);
    await _dispose(tester, controller);
  });

  testWidgets(
    'disposing a stalled reader cancels session timers and ignores late errors',
    (tester) async {
      final old = Completer<TextChapterContent>();
      final source = _Source()..blocked = old;
      final controller = TextReaderController();
      await _mount(tester, source, controller);
      unawaited(controller.nextChapter());
      await tester.pump();
      await _dispose(tester, controller);
      old.completeError(StateError('销毁后返回'));
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _mount(
  WidgetTester tester,
  _Source source,
  TextReaderController controller, {
  ReaderNavigationMode mode = ReaderNavigationMode.horizontalPages,
  int preload = 0,
  bool expectReady = true,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: TextReaderView(
          bookId: 'book',
          dataSource: source,
          controller: controller,
          stateStore: _Store(mode),
          chapterPreloadCount: preload,
        ),
      ),
    ),
  );
  if (expectReady)
    await _until(tester, () => controller.snapshot.chapter?.id == 'c0');
}

Future<void> _until(WidgetTester tester, bool Function() condition) async {
  for (var i = 0; i < 120 && !condition(); i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(condition(), isTrue);
  await tester.pump();
}

Future<void> _dispose(
  WidgetTester tester,
  TextReaderController controller,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  controller.dispose();
}

TextChapterContent _content(String id, {String? text}) => TextChapterContent(
  chapterId: id,
  title: id,
  paragraphs: <TextParagraph>[
    TextParagraph(id: '$id-p', text: text ?? '正文 $id。'),
  ],
);

class _Source implements TextReaderDataSource {
  final Map<String, int> attempts = <String, int>{};
  Object? failure;
  Completer<TextChapterContent>? blocked;
  bool sparse = false;
  bool blockInfo = false;
  bool failInitial = false;
  int infoAttempts = 0;
  final Completer<ReaderChapterInfo> _info = Completer<ReaderChapterInfo>();
  static final chapters = List<ReaderChapterInfo>.generate(
    3,
    (i) => ReaderChapterInfo(id: 'c$i', title: '第${i + 1}章', index: i),
  );

  @override
  Future<ReaderBookInfo> loadBookInfo(String bookId) async =>
      ReaderBookInfo(id: bookId, title: '测试小说');
  @override
  Future<ChapterCatalogPage> loadChapterCatalog(
    String bookId, {
    String? cursor,
    int pageSize = 100,
  }) async => ChapterCatalogPage(
    items: sparse ? chapters.take(1).toList() : chapters,
    total: 3,
    hasMore: sparse,
    nextCursor: sparse ? 'more' : null,
  );
  @override
  Future<ReaderChapterInfo> loadChapterAtIndex(String bookId, int index) {
    infoAttempts++;
    return blockInfo ? _info.future : Future.value(chapters[index]);
  }

  @override
  Future<TextChapterContent> loadChapterContent(
    String bookId,
    String chapterId,
  ) async {
    attempts.update(chapterId, (n) => n + 1, ifAbsent: () => 1);
    if (chapterId == 'c0' && failInitial) throw StateError('首章加载失败');
    if (chapterId == 'c1') {
      if (failure != null) throw failure!;
      if (blocked != null) return blocked!.future;
    }
    return _content(chapterId);
  }
}

class _Store implements TextReaderStateStore {
  const _Store(this.mode);
  final ReaderNavigationMode mode;
  @override
  Future<TextReaderPreferences?> loadPreferences() async =>
      TextReaderPreferences(navigationMode: mode);
  @override
  Future<ReaderProgress?> loadProgress(String bookId) async =>
      const ReaderProgress(chapterId: 'c0', paragraphId: 'c0-p');
  @override
  Future<List<ReaderBookmark>> loadBookmarks(String bookId) async =>
      const <ReaderBookmark>[];
  @override
  Future<void> saveProgress(String bookId, ReaderProgress progress) async {}
  @override
  Future<void> savePreferences(TextReaderPreferences preferences) async {}
  @override
  Future<void> addBookmark(ReaderBookmark bookmark) async {}
  @override
  Future<void> removeBookmark(String bookId, String bookmarkId) async {}
}
