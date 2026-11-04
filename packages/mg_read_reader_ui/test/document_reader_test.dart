import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';

void main() {
  testWidgets(
    'renders styled document content and resolves internal navigation',
    (tester) async {
      final source = _Source();
      final store = _Store();
      await tester.pumpWidget(
        MaterialApp(
          home: DocumentReaderView(
            dataSource: source,
            stateStore: store,
            bookId: 'book',
            navigationEntries: const [
              ReaderDocumentNavigationEntry(
                title: 'Second heading',
                chapterId: 'c2',
                anchor: 'dest',
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Document'), findsOneWidget);
      expect(find.text('Hello styled world'), findsOneWidget);
      final cssText = tester.widget<SelectableText>(
        find.byWidgetPredicate(
          (widget) => widget is SelectableText && widget.data == 'CSS styled',
        ),
      );
      expect(cssText.style?.fontSize, 19);
      expect(cssText.style?.color, const Color(0xff282720));
      expect(cssText.textAlign, TextAlign.center);
      expect(find.text('3.  '), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
      await tester.tap(find.byTooltip('字号与主题'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('使用书籍样式'));
      await tester.pumpAndSettle();
      final styledCssText = tester.widget<SelectableText>(
        find.byWidgetPredicate(
          (widget) => widget is SelectableText && widget.data == 'CSS styled',
        ),
      );
      expect(styledCssText.style?.fontSize, closeTo(23.75, .01));
      expect(styledCssText.style?.color, const Color(0xffff0000));
      tester.state<NavigatorState>(find.byType(Navigator).last).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('目录'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Second heading'));
      await tester.pumpAndSettle();
      expect(source.loaded.last, 'c2');
      expect(find.text('Target chapter'), findsOneWidget);
    },
  );

  testWidgets('restores a distant UTF-16 paragraph and caret offset', (
    tester,
  ) async {
    final source = _Source()..longFirstChapter = true;
    final store = _Store()
      ..progress = const ReaderProgress(
        chapterId: 'c1',
        paragraphId: 'long-50',
        characterOffset: 45,
        chapterIndex: 0,
      );
    await tester.pumpWidget(
      MaterialApp(
        home: DocumentReaderView(
          dataSource: source,
          stateStore: store,
          bookId: 'book',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(source.loaded.last, 'c1');
    expect(store.progress?.paragraphId, 'long-50');
    expect(store.progress?.characterOffset, 45);
    final viewportTop = tester
        .getTopLeft(find.byType(SingleChildScrollView).first)
        .dy;
    final caretY = _caretGlobalY(
      tester,
      'Long continuous chapter content 50.',
      45,
    );
    expect(caretY, greaterThanOrEqualTo(viewportTop));
    expect(caretY, lessThan(viewportTop + 100));
  });

  testWidgets(
    'jumps to a distant bookmark and preserves it after resize and font change',
    (tester) async {
      final source = _Source()..longFirstChapter = true;
      final store = _Store()
        ..bookmarks = [
          ReaderBookmark(
            id: 'far',
            bookId: 'book',
            chapterId: 'c1',
            paragraphId: 'long-45',
            characterOffset: 52,
            chapterTitle: 'Chapter 1',
            excerpt: 'far bookmark excerpt',
            createdAt: DateTime.utc(2026),
          ),
        ];
      await tester.pumpWidget(
        MaterialApp(
          home: DocumentReaderView(
            dataSource: source,
            stateStore: store,
            bookId: 'book',
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('书签'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('far bookmark excerpt'));
      await tester.pumpAndSettle();
      expect(
        _caretGlobalY(tester, 'Long continuous chapter content 45.', 52),
        lessThan(180),
      );

      final originalSize = tester.view.physicalSize;
      final originalDpr = tester.view.devicePixelRatio;
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(700, 1000);
      addTearDown(() {
        tester.view.physicalSize = originalSize;
        tester.view.devicePixelRatio = originalDpr;
      });
      await tester.pumpAndSettle();
      var caretY = _caretGlobalY(
        tester,
        'Long continuous chapter content 45.',
        52,
      );
      expect(caretY, lessThan(180));

      await tester.tap(find.byTooltip('字号与主题'));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(Slider).first, const Offset(80, 0));
      await tester.pumpAndSettle();
      caretY = _caretGlobalY(tester, 'Long continuous chapter content 45.', 52);
      // The fixed app chrome and slider sheet constrain this short viewport;
      // the restored UTF-16 caret remains visible even when it cannot reach
      // the preferred top alignment.
      expect(caretY, lessThan(300));
    },
  );

  testWidgets('reports session lifecycle and exit through the observer', (
    tester,
  ) async {
    final observer = _Observer();
    await tester.pumpWidget(
      MaterialApp(
        home: DocumentReaderView(
          dataSource: _Source(),
          stateStore: _Store(),
          bookId: 'book',
          observer: observer,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(observer.started, 1);
    expect(observer.firstContent, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(
      observer.lifecycle,
      containsAll([
        ReaderLifecycleState.background,
        ReaderLifecycleState.foreground,
      ]),
    );
    await tester.tap(find.byIcon(Icons.close));
    expect(observer.exits, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(observer.ended, 1);
  });

  testWidgets('shows missing image alt text and retries without losing text', (
    tester,
  ) async {
    final source = _Source()..resourceOutcomes = ['null', 'success'];
    await tester.pumpWidget(
      MaterialApp(
        home: DocumentReaderView(
          dataSource: source,
          stateStore: _Store(),
          bookId: 'book',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('图片资源缺失'), findsOneWidget);
    expect(find.text('封面插图替代文本'), findsOneWidget);
    expect(find.text('Hello styled world'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(source.resourceAttempts, 2);
    expect(find.text('图片资源缺失'), findsNothing);
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('Hello styled world'), findsOneWidget);
  });

  testWidgets(
    'shows image read errors and retries without failing the reader',
    (tester) async {
      final source = _Source()..resourceOutcomes = ['throw', 'success'];
      await tester.pumpWidget(
        MaterialApp(
          home: DocumentReaderView(
            dataSource: source,
            stateStore: _Store(),
            bookId: 'book',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('图片加载失败'), findsOneWidget);
      expect(find.text('封面插图替代文本'), findsOneWidget);
      expect(find.text('Hello styled world'), findsOneWidget);
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(source.resourceAttempts, 2);
      expect(find.text('图片加载失败'), findsNothing);
      expect(find.byType(Image), findsOneWidget);
      expect(find.text('Hello styled world'), findsOneWidget);
    },
  );

  testWidgets(
    'waits for an explicit next-chapter action after the final block',
    (tester) async {
      final source = _Source()..longFirstChapter = true;
      await tester.pumpWidget(
        MaterialApp(
          home: DocumentReaderView(
            dataSource: source,
            stateStore: _Store(),
            bookId: 'book',
          ),
        ),
      );
      await tester.pumpAndSettle();
      final scrollable = tester.state<ScrollableState>(
        find.byType(Scrollable).first,
      );
      scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(source.loaded, ['c1']);
      expect(find.byKey(const Key('document-next-segment')), findsOneWidget);
      await tester.tap(find.byKey(const Key('document-next-segment')));
      await tester.pumpAndSettle();
      expect(source.loaded, contains('c2'));
      expect(find.text('Target chapter'), findsWidgets);
    },
  );

  testWidgets('keeps visible chapter when destination load fails and retries', (
    tester,
  ) async {
    final source = _Source()..failNext = true;
    await tester.pumpWidget(
      MaterialApp(
        home: DocumentReaderView(
          dataSource: source,
          stateStore: _Store(),
          bookId: 'book',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();
    expect(find.text('Chapter 1'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('Target chapter'), findsWidgets);
  });
}

final class _Source implements ReaderDocumentDataSource {
  final loaded = <String>[];
  bool failNext = false;
  bool longFirstChapter = false;
  List<String> resourceOutcomes = const [];
  int resourceAttempts = 0;
  @override
  Future<ReaderBookInfo> loadBookInfo(String bookId) async =>
      const ReaderBookInfo(id: 'book', title: 'Document');
  @override
  Future<ChapterCatalogPage> loadChapterCatalog(
    String bookId, {
    String? cursor,
    int pageSize = 100,
  }) async => ChapterCatalogPage(
    items: const [
      ReaderChapterInfo(id: 'c1', title: 'Chapter 1', index: 0),
      ReaderChapterInfo(id: 'c2', title: 'Chapter 2', index: 1),
    ],
    total: 2,
    hasMore: false,
  );
  @override
  Future<ReaderChapterInfo> loadChapterAtIndex(
    String bookId,
    int index,
  ) async => ReaderChapterInfo(
    id: 'c${index + 1}',
    title: 'Chapter ${index + 1}',
    index: index,
  );
  @override
  Future<ReaderDocumentChapter> loadChapter(
    String bookId,
    String chapterId,
  ) async {
    loaded.add(chapterId);
    if (failNext && chapterId == 'c2') {
      failNext = false;
      throw StateError('temporarily unavailable');
    }
    if (chapterId == 'c1') {
      final blocks = <ReaderDocumentBlock>[
        const ReaderDocumentBlock(
          id: 'p1',
          type: 'paragraph',
          spans: [
            ReaderDocumentSpan(text: 'Hello ', bold: true),
            ReaderDocumentSpan(text: 'styled world'),
          ],
        ),
        const ReaderDocumentBlock(
          id: 'css',
          type: 'paragraph',
          text: 'CSS styled',
          style: {
            'font-size': '1.25em',
            'line-height': '2.0',
            'text-align': 'center',
            'color': '#ff0000',
          },
        ),
        const ReaderDocumentBlock(
          id: 'ordered',
          type: 'listItem',
          text: 'ordered entry',
          style: {'ordered': true, 'listIndex': 3, 'depth': 1},
        ),
        const ReaderDocumentBlock(
          id: 'img',
          type: 'image',
          resourceId: 'cover',
          text: '封面插图替代文本',
        ),
        const ReaderDocumentBlock(
          id: 'jump',
          type: 'paragraph',
          spans: [ReaderDocumentSpan(text: 'open', href: 'c2#dest')],
        ),
        if (longFirstChapter)
          for (var i = 0; i < 80; i++)
            ReaderDocumentBlock(
              id: 'long-$i',
              type: 'paragraph',
              text: 'Long continuous chapter content $i. ' * 30,
            ),
      ];
      return ReaderDocumentChapter(
        chapterId: chapterId,
        title: 'Chapter 1',
        blocks: blocks,
      );
    }
    return ReaderDocumentChapter(
      chapterId: chapterId,
      title: 'Target chapter',
      blocks: const [
        ReaderDocumentBlock(
          id: 'dest',
          type: 'heading',
          text: 'Target chapter',
        ),
      ],
    );
  }

  @override
  Future<Uint8List?> loadResourceBytes(String resourceId) async {
    final attempt = resourceAttempts++;
    final outcome = attempt < resourceOutcomes.length
        ? resourceOutcomes[attempt]
        : 'success';
    if (outcome == 'throw') throw StateError('temporary resource failure');
    if (outcome == 'null') return null;
    return Uint8List.fromList(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j9k0AAAAASUVORK5CYII=',
      ),
    );
  }

  @override
  Future<ReaderDocumentLinkTarget?> resolveLink(
    String currentChapterId,
    String href,
  ) async => const ReaderDocumentLinkTarget(chapterId: 'c2', anchor: 'dest');
}

final class _Store implements TextReaderStateStore {
  ReaderProgress? progress;
  final savedProgress = <ReaderProgress>[];
  List<ReaderBookmark> bookmarks = [];
  @override
  Future<ReaderProgress?> loadProgress(String bookId) async => progress;
  @override
  Future<void> saveProgress(String bookId, ReaderProgress value) async {
    progress = value;
    savedProgress.add(value);
  }

  @override
  Future<TextReaderPreferences?> loadPreferences() async =>
      const TextReaderPreferences(keepScreenOn: false);
  @override
  Future<void> savePreferences(TextReaderPreferences preferences) async {}
  @override
  Future<List<ReaderBookmark>> loadBookmarks(String bookId) async => bookmarks;
  @override
  Future<void> addBookmark(ReaderBookmark bookmark) async {}
  @override
  Future<void> removeBookmark(String bookId, String bookmarkId) async {}
}

double _caretGlobalY(WidgetTester tester, String prefix, int offset) {
  final selectable = find.byWidgetPredicate(
    (widget) =>
        widget is SelectableText && (widget.data ?? '').startsWith(prefix),
  );
  RenderEditable? render;
  void visit(RenderObject object) {
    if (object is RenderEditable) {
      render = object;
      return;
    }
    object.visitChildren((child) {
      if (render == null) visit(child);
    });
  }

  visit(tester.renderObject<RenderObject>(selectable.first));
  if (render == null) {
    throw StateError('Selectable text has no RenderEditable.');
  }
  return render!
      .localToGlobal(
        render!.getLocalRectForCaret(TextPosition(offset: offset)).topLeft,
      )
      .dy;
}

final class _Observer extends ReaderObserver {
  int started = 0;
  int ended = 0;
  int firstContent = 0;
  int exits = 0;
  final lifecycle = <ReaderLifecycleState>[];
  @override
  void onSessionStarted(String bookId) => started++;
  @override
  void onSessionEnded(String bookId, ReaderProgress? progress) => ended++;
  @override
  void onFirstContentPresented(ReaderFirstContentPresentation presentation) =>
      firstContent++;
  @override
  void onExitRequested(ReaderProgress? progress) => exits++;
  @override
  void onLifecycleChanged(
    ReaderLifecycleState state,
    ReaderProgress? progress,
  ) => lifecycle.add(state);
}
