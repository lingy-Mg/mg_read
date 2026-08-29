import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';

void main() {
  testWidgets('Windows reader chrome keeps hover hints and semantics stable', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    try {
      await _pumpReader(tester);
      await _showControls(tester);
      await mouse.moveTo(
        tester.getCenter(
          find.byKey(const ValueKey<String>('reader-content-surface')),
        ),
      );
      await tester.pumpAndSettle();

      expect(_explicitSemanticsLabel('返回'), findsOneWidget);
      expect(_explicitSemanticsLabel('删除书签'), findsOneWidget);
      expect(_explicitSemanticsLabel('刷新本章'), findsOneWidget);
      expect(_explicitSemanticsLabel('更多'), findsOneWidget);

      await mouse.moveTo(
        tester.getCenter(
          find.byKey(const ValueKey<String>('reader-toolbar-bookmark')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('删除书签'), findsOneWidget);
      _expectOnlySliderOverlayPortal();

      await mouse.moveTo(
        tester.getCenter(
          find.byKey(const ValueKey<String>('reader-top-overflow')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('更多'), findsOneWidget);
      _expectOnlySliderOverlayPortal();

      await mouse.moveTo(
        tester.getCenter(
          find.byKey(const ValueKey<String>('reader-content-surface')),
        ),
      );
      await tester.pumpAndSettle();
      await tester.longPress(
        find.byKey(const ValueKey<String>('reader-toolbar-bookmark')),
      );
      await tester.pump();
      expect(find.text('删除书签'), findsOneWidget);
      _expectOnlySliderOverlayPortal();

      for (final String key in <String>[
        'reader-back-action',
        'reader-toolbar-bookmark',
        'reader-toolbar-refresh-chapter',
        'reader-top-overflow',
        'reader-source-url-region',
      ]) {
        await mouse.moveTo(tester.getCenter(find.byKey(ValueKey<String>(key))));
        await tester.pump(const Duration(milliseconds: 20));
        expect(tester.takeException(), isNull, reason: key);
      }
      await tester.pumpAndSettle();

      for (int cycle = 0; cycle < 4; cycle += 1) {
        await tester.tap(
          find.byKey(const ValueKey<String>('reader-top-overflow')),
        );
        await tester.pumpAndSettle();
        expect(find.text('缓存章节'), findsOneWidget);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'menu cycle $cycle');
      }

      final Finder surface = find.byKey(
        const ValueKey<String>('reader-content-surface'),
      );
      for (int cycle = 0; cycle < 4; cycle += 1) {
        await tester.tapAt(tester.getCenter(surface));
        await tester.pumpAndSettle();
        await tester.tapAt(tester.getCenter(surface));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'chrome cycle $cycle');
      }
    } finally {
      await mouse.removePointer();
      semantics.dispose();
    }
  });

  testWidgets('Windows catalog and bookmarks keep tooltip semantics stable', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    try {
      await _pumpReader(tester);

      for (int cycle = 0; cycle < 3; cycle += 1) {
        await _showControls(tester);
        await tester.tap(find.text('目录'));
        await tester.pumpAndSettle();

        final Finder failedState = find.text('下载失败').first;
        expect(failedState, findsOneWidget);
        await mouse.moveTo(tester.getCenter(failedState));
        await tester.pumpAndSettle();
        expect(find.text('重试加载章节状态'), findsOneWidget);
        _expectOnlySliderOverlayPortal();

        final Finder catalog = find.byKey(
          const ValueKey<String>('reader-catalog-count-12'),
        );
        await tester.drag(catalog, const Offset(0, -220));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'catalog cycle $cycle');

        await tester.tap(find.widgetWithText(Tab, '书签'));
        await tester.pumpAndSettle();
        final Finder removeBookmark = find.byKey(
          const ValueKey<String>('reader-bookmark-remove-bookmark-1'),
        );
        await mouse.moveTo(tester.getCenter(removeBookmark));
        await tester.pumpAndSettle();
        expect(find.text('删除书签'), findsOneWidget);
        _expectOnlySliderOverlayPortal();

        await tester.tap(find.widgetWithText(Tab, '书籍详情'));
        await tester.pumpAndSettle();
        final Finder externalAction = find
            .byIcon(Icons.open_in_new_rounded)
            .last;
        await mouse.moveTo(tester.getCenter(externalAction));
        await tester.pumpAndSettle();
        expect(find.text('在外部浏览器打开来源链接'), findsOneWidget);

        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'sheet cycle $cycle');
      }
    } finally {
      await mouse.removePointer();
      semantics.dispose();
    }
  });
}

Finder _explicitSemanticsLabel(String label) {
  return find.byWidgetPredicate(
    (Widget widget) => widget is Semantics && widget.properties.label == label,
  );
}

void _expectOnlySliderOverlayPortal() {
  final Finder portals = find.byType(OverlayPortal);
  expect(portals, findsOneWidget);
  expect(
    find.ancestor(of: portals, matching: find.byType(Slider)),
    findsOneWidget,
  );
}

Future<void> _pumpReader(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(platform: TargetPlatform.windows),
      home: const Scaffold(
        body: SizedBox(
          width: 400,
          height: 700,
          child: TextReaderView(
            bookId: 'semantics-book',
            dataSource: _SemanticsDataSource(),
            stateStore: _SemanticsStateStore(),
            extensions: ReaderExtensions(
              chapterStateCapability: _FailedChapterStateCapability(),
              chapterCacheCapability: _ChapterCacheCapability(),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _showControls(WidgetTester tester) async {
  final Finder surface = find.byKey(
    const ValueKey<String>('reader-content-surface'),
  );
  if (find
      .byKey(const ValueKey<String>('reader-controls-interaction-lock'))
      .evaluate()
      .isEmpty) {
    await tester.tapAt(tester.getCenter(surface));
    await tester.pumpAndSettle();
  }
}

final class _SemanticsDataSource implements TextReaderDataSource {
  const _SemanticsDataSource();

  static final List<ReaderChapterInfo> _chapters =
      List<ReaderChapterInfo>.generate(
        12,
        (int index) => ReaderChapterInfo(
          id: 'chapter-${index + 1}',
          title: '第 ${index + 1} 章',
          index: index,
        ),
        growable: false,
      );

  @override
  Future<ReaderBookInfo> loadBookInfo(String bookId) async => ReaderBookInfo(
    id: bookId,
    title: '语义回归测试书',
    sourceName: '测试数据源',
    sourceUrl: Uri.parse('https://source.example/semantics-book'),
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
  ) async => TextChapterContent(
    chapterId: chapterId,
    title: _chapters
        .firstWhere((ReaderChapterInfo chapter) => chapter.id == chapterId)
        .title,
    chapterUrl: 'https://source.example/$chapterId',
    paragraphs: <TextParagraph>[
      TextParagraph(id: '$chapterId-body', text: '用于验证 Windows 语义树稳定性。'),
    ],
  );
}

final class _SemanticsStateStore implements TextReaderStateStore {
  const _SemanticsStateStore();

  @override
  Future<List<ReaderBookmark>> loadBookmarks(String bookId) async =>
      <ReaderBookmark>[
        ReaderBookmark(
          id: 'bookmark-1',
          bookId: bookId,
          chapterId: 'chapter-1',
          paragraphId: 'chapter-1-body',
          characterOffset: 0,
          chapterTitle: '第 1 章',
          excerpt: '书签正文',
          createdAt: DateTime(2026),
        ),
      ];

  @override
  Future<TextReaderPreferences?> loadPreferences() async => null;

  @override
  Future<ReaderProgress?> loadProgress(String bookId) async =>
      const ReaderProgress(
        chapterId: 'chapter-1',
        paragraphId: 'chapter-1-body',
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

final class _FailedChapterStateCapability
    implements ReaderChapterStateCapability {
  const _FailedChapterStateCapability();

  @override
  Future<Map<String, ReaderChapterState>> loadChapterStates(
    String bookId,
    List<String> chapterIds,
  ) async => <String, ReaderChapterState>{
    for (final String chapterId in chapterIds)
      chapterId: ReaderChapterState(
        chapterId: chapterId,
        availability: ReaderChapterAvailability.failed,
      ),
  };

  @override
  Future<void> markRead(String bookId, String chapterId) async {}
}

final class _ChapterCacheCapability implements ReaderChapterCacheCapability {
  const _ChapterCacheCapability();

  @override
  Future<void> startCaching(
    String bookId,
    ReaderChapterCacheRequest request,
  ) async {}
}
