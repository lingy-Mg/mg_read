/// Verifies that horizontal reader backgrounds belong to animated page sheets.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';

void main() {
  for (final ReaderPageAnimation animation in ReaderPageAnimation.values) {
    testWidgets('assigns one background owner for ${animation.name}', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: TextReaderView(
            bookId: 'page-background-book',
            dataSource: const _PageBackgroundDataSource(),
            stateStore: _PageBackgroundStateStore(animation),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final bool movingPageOwnsBackground =
          animation == ReaderPageAnimation.cover ||
          animation == ReaderPageAnimation.pageCurl;
      expect(
        find.byKey(const ValueKey<String>('reader-fixed-background')),
        movingPageOwnsBackground ? findsNothing : findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('reader-page-background-1')),
        movingPageOwnsBackground ? findsOneWidget : findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('reader-animated-page-boundary-1')),
        movingPageOwnsBackground ? findsOneWidget : findsNothing,
      );
    });
  }

  testWidgets('slide drag keeps the shared background fixed', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: TextReaderView(
          bookId: 'sliding-page-background-book',
          dataSource: const _PageBackgroundDataSource(),
          stateStore: _PageBackgroundStateStore(ReaderPageAnimation.slide),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Finder fixedBackground = find.byKey(
      const ValueKey<String>('reader-fixed-background'),
    );
    final Offset initialPosition = tester.getTopLeft(fixedBackground);
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(
        find.byKey(const ValueKey<String>('reader-content-surface')),
      ),
    );
    // First cross the gesture arena threshold, then verify a subsequent drag
    // update while the pointer is still down.
    await gesture.moveBy(const Offset(-24, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-96, 0));
    await tester.pump();

    expect(tester.getTopLeft(fixedBackground), initialPosition);

    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('horizontal pages keep adjacent sheets prelaid out', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: TextReaderView(
          bookId: 'adjacent-page-layout-book',
          dataSource: const _PageBackgroundDataSource(),
          stateStore: const _PageBackgroundStateStore(
            ReaderPageAnimation.slide,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final PageView pageView = tester.widget<PageView>(find.byType(PageView));
    expect(pageView.allowImplicitScrolling, isTrue);
  });
}

final class _PageBackgroundStateStore implements TextReaderStateStore {
  const _PageBackgroundStateStore(this.animation);

  final ReaderPageAnimation animation;

  @override
  Future<TextReaderPreferences?> loadPreferences() async =>
      TextReaderPreferences(
        background: ReaderBackgroundPreset.mistMountains,
        pageAnimation: animation,
      );

  @override
  Future<List<ReaderBookmark>> loadBookmarks(String bookId) async =>
      const <ReaderBookmark>[];

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

final class _PageBackgroundDataSource implements TextReaderDataSource {
  const _PageBackgroundDataSource();

  static const ReaderChapterInfo _chapter = ReaderChapterInfo(
    id: 'chapter-1',
    index: 0,
    title: '第一章',
  );

  @override
  Future<ReaderBookInfo> loadBookInfo(String bookId) async =>
      ReaderBookInfo(id: bookId, title: '背景翻页测试');

  @override
  Future<ChapterCatalogPage> loadChapterCatalog(
    String bookId, {
    String? cursor,
    int pageSize = 100,
  }) async => ChapterCatalogPage(
    items: const <ReaderChapterInfo>[_chapter],
    total: 1,
    hasMore: false,
  );

  @override
  Future<ReaderChapterInfo> loadChapterAtIndex(
    String bookId,
    int index,
  ) async => _chapter;

  @override
  Future<TextChapterContent> loadChapterContent(
    String bookId,
    String chapterId,
  ) async => TextChapterContent(
    chapterId: _chapter.id,
    title: _chapter.title,
    paragraphs: <TextParagraph>[
      for (int index = 0; index < 24; index += 1)
        TextParagraph(
          id: 'paragraph-$index',
          text: '这是用于验证阅读器背景跟随翻页移动的测试正文。' * 12,
        ),
    ],
  );
}
