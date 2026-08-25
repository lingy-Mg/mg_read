import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';

void main() {
  testWidgets('reader settings locks the reader and barrier closes every settings page', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TextReaderView(
            bookId: 'settings-interaction-book',
            dataSource: const _SettingsSemanticsDataSource(),
            stateStore: const _SettingsSemanticsStateStore(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(TextReaderView));
    await tester.pumpAndSettle();

    final Finder settings = find.byKey(const Key('reader-toolbar-settings'));
    await tester.tap(settings);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('reader-settings-interaction-lock')), findsOneWidget);

    final Finder readerSurface = find.byKey(const ValueKey<String>('reader-content-surface'));
    final Finder readerScrollable = find.descendant(of: readerSurface, matching: find.byType(Scrollable));
    expect(readerScrollable, findsOneWidget);
    final ScrollableState locked = tester.state<ScrollableState>(readerScrollable);
    expect(locked.position.physics.shouldAcceptUserOffset(locked.position), isFalse);

    final Finder settingsSheet = find.byWidgetPredicate((Widget widget) => widget.runtimeType.toString() == 'ReaderSettingsSheet');
    final double sheetTop = tester.getTopLeft(settingsSheet).dy;
    await tester.tapAt(Offset(20, sheetTop - 8));
    await tester.pumpAndSettle();
    expect(settingsSheet, findsNothing);

    await tester.tap(settings);
    await tester.pumpAndSettle();
    await tester.tap(find.text('更多'));
    await tester.pumpAndSettle();
    expect(find.text('自动阅读速度'), findsOneWidget);

    final double subpageTop = tester.getTopLeft(settingsSheet).dy;
    await tester.tapAt(Offset(20, subpageTop - 8));
    await tester.pumpAndSettle();
    expect(settingsSheet, findsNothing);
    expect(find.text('自动阅读速度'), findsNothing);
  });

  testWidgets('single-hand mode keeps the centre tap available for controls', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TextReaderView(
            bookId: 'single-hand-mode-book',
            dataSource: const _SettingsSemanticsDataSource(),
            stateStore: const _SettingsSemanticsStateStore(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(TextReaderView));
    await tester.pumpAndSettle();
    final Finder settings = find.byKey(const Key('reader-toolbar-settings'));
    await tester.tap(settings);
    await tester.pumpAndSettle();
    await tester.tap(find.text('更多'));
    await tester.pumpAndSettle();

    final Finder singleHandMode = find.ancestor(of: find.text('单手模式'), matching: find.byType(SwitchListTile));
    await tester.tap(find.descendant(of: singleHandMode, matching: find.byType(Switch)));
    await tester.pumpAndSettle();
    final Finder singleHandSwitch = find.descendant(of: singleHandMode, matching: find.byType(Switch));
    expect(tester.widget<Switch>(singleHandSwitch).value, isTrue);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    final Finder readerSurface = find.byKey(const ValueKey<String>('reader-content-surface'));
    final Finder controlsGate = find.ancestor(of: settings, matching: find.byType(IgnorePointer));
    await tester.tapAt(tester.getCenter(readerSurface));
    await tester.pumpAndSettle();
    expect(tester.widgetList<IgnorePointer>(controlsGate).map((IgnorePointer widget) => widget.ignoring), contains(isTrue));

    await tester.tapAt(tester.getCenter(readerSurface));
    await tester.pumpAndSettle();
    expect(tester.widgetList<IgnorePointer>(controlsGate).map((IgnorePointer widget) => widget.ignoring), isNot(contains(isTrue)));
  });

  testWidgets('repeatedly opening and dismissing reader settings keeps semantics valid', (WidgetTester tester) async {
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

      final Finder settings = find.byKey(const Key('reader-toolbar-settings'));
      expect(settings, findsOneWidget);

      for (int cycle = 0; cycle < 4; cycle += 1) {
        await tester.tap(settings);
        await tester.pumpAndSettle();
        expect(find.text('亮度'), findsOneWidget);

        if (cycle == 0) {
          await tester.tap(find.text('更多'));
          await tester.pumpAndSettle();
          expect(find.text('自动阅读速度'), findsOneWidget);
          final Finder settingsSheet = find.byWidgetPredicate((Widget widget) => widget.runtimeType.toString() == 'ReaderSettingsSheet');
          final Offset moreTitle = tester.getTopLeft(find.text('更多').last);
          final Offset autoTitle = tester.getTopLeft(find.text('自动阅读速度'));
          // Keep the subpage content attached to the top of the sheet.
          expect(settingsSheet, findsOneWidget);
          final double sheetTop = tester.getTopLeft(settingsSheet).dy;
          expect(moreTitle.dy - sheetTop, lessThan(72));
          expect(autoTitle.dy - moreTitle.dy, lessThan(100));
          expect(find.text('单手模式'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
        }

        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(settings, findsOneWidget);
        expect(tester.takeException(), isNull, reason: 'cycle $cycle');
      }
    } finally {
      semantics.dispose();
    }
  });
}

final class _SettingsSemanticsDataSource implements TextReaderDataSource {
  const _SettingsSemanticsDataSource();

  static const ReaderChapterInfo _chapter = ReaderChapterInfo(id: 'chapter-1', title: '第一章', index: 0);

  @override
  Future<ReaderBookInfo> loadBookInfo(String bookId) async => ReaderBookInfo(id: bookId, title: '设置语义测试书', author: '测试作者');

  @override
  Future<ChapterCatalogPage> loadChapterCatalog(String bookId, {String? cursor, int pageSize = 100}) async =>
      ChapterCatalogPage(items: <ReaderChapterInfo>[_chapter], total: 1, hasMore: false);

  @override
  Future<ReaderChapterInfo> loadChapterAtIndex(String bookId, int index) async {
    if (index != 0) throw RangeError.index(index, const <int>[0]);
    return _chapter;
  }

  @override
  Future<TextChapterContent> loadChapterContent(String bookId, String chapterId) async => TextChapterContent(
    chapterId: 'chapter-1',
    title: '第一章',
    paragraphs: <TextParagraph>[TextParagraph(id: 'paragraph-1', text: '用于验证阅读设置反复开关时的语义树。')],
  );
}

final class _SettingsSemanticsStateStore implements TextReaderStateStore {
  const _SettingsSemanticsStateStore();

  @override
  Future<List<ReaderBookmark>> loadBookmarks(String bookId) async => const <ReaderBookmark>[];

  @override
  Future<TextReaderPreferences?> loadPreferences() async => null;

  @override
  Future<ReaderProgress?> loadProgress(String bookId) async => const ReaderProgress(chapterId: 'chapter-1', paragraphId: 'paragraph-1');

  @override
  Future<void> addBookmark(ReaderBookmark bookmark) async {}

  @override
  Future<void> removeBookmark(String bookId, String bookmarkId) async {}

  @override
  Future<void> savePreferences(TextReaderPreferences preferences) async {}

  @override
  Future<void> saveProgress(String bookId, ReaderProgress progress) async {}
}
