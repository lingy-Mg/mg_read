import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';

void main() {
  testWidgets(
    'repeatedly opening and dismissing reader settings keeps semantics valid',
    (WidgetTester tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TextReaderView(
                bookId: 'settings-semantics-book',
                dataSource: const _SettingsSemanticsDataSource(),
                stateStore: const _SettingsSemanticsStateStore(),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byType(TextReaderView));
        await tester.pumpAndSettle();

        final Finder settings = find.byKey(
          const Key('reader-toolbar-settings'),
        );
        expect(settings, findsOneWidget);

        for (int cycle = 0; cycle < 4; cycle += 1) {
          await tester.tap(settings);
          await tester.pumpAndSettle();
          expect(find.text('亮度'), findsOneWidget);

          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          expect(settings, findsOneWidget);
          expect(tester.takeException(), isNull, reason: 'cycle $cycle');
        }
      } finally {
        semantics.dispose();
      }
    },
  );
}

final class _SettingsSemanticsDataSource implements TextReaderDataSource {
  const _SettingsSemanticsDataSource();

  static const ReaderChapterInfo _chapter = ReaderChapterInfo(
    id: 'chapter-1',
    title: '第一章',
    index: 0,
  );

  @override
  Future<ReaderBookInfo> loadBookInfo(String bookId) async =>
      ReaderBookInfo(id: bookId, title: '设置语义测试书', author: '测试作者');

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
      TextParagraph(id: 'paragraph-1', text: '用于验证阅读设置反复开关时的语义树。'),
    ],
  );
}

final class _SettingsSemanticsStateStore implements TextReaderStateStore {
  const _SettingsSemanticsStateStore();

  @override
  Future<List<ReaderBookmark>> loadBookmarks(String bookId) async =>
      const <ReaderBookmark>[];

  @override
  Future<TextReaderPreferences?> loadPreferences() async => null;

  @override
  Future<ReaderProgress?> loadProgress(String bookId) async =>
      const ReaderProgress(chapterId: 'chapter-1', paragraphId: 'paragraph-1');

  @override
  Future<void> addBookmark(ReaderBookmark bookmark) async {}

  @override
  Future<void> removeBookmark(String bookId, String bookmarkId) async {}

  @override
  Future<void> savePreferences(TextReaderPreferences preferences) async {}

  @override
  Future<void> saveProgress(String bookId, ReaderProgress progress) async {}
}
