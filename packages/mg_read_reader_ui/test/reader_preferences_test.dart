import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';
import 'package:novel_reader_ui/src/platform/reader_platform.dart';

void main() {
  test(
    'uses a compact default top margin without rewriting explicit values',
    () {
      expect(TextReaderPreferences.defaults.topPadding, 8);
      expect(
        const TextReaderPreferences(topPadding: 24).normalized().topPadding,
        24,
      );
      expect(
        const TextReaderPreferences(topPadding: 40).normalized().topPadding,
        40,
      );
      expect(
        const TextReaderPreferences(topPadding: 64).normalized().topPadding,
        64,
      );
    },
  );

  testWidgets(
    'places default text content eight dp after the Android safe area',
    (WidgetTester tester) async {
      final TextReaderController controller = TextReaderController();
      await tester.pumpWidget(
        MaterialApp(
          builder: (BuildContext context, Widget? child) {
            final MediaQueryData mediaQuery = MediaQuery.of(context);
            return MediaQuery(
              data: mediaQuery.copyWith(
                padding: const EdgeInsets.only(top: 24),
                viewPadding: const EdgeInsets.only(top: 24),
              ),
              child: child ?? const SizedBox.shrink(),
            );
          },
          home: TextReaderView(
            bookId: 'top-margin-book',
            controller: controller,
            dataSource: const _ThemeDataSource(),
            stateStore: _MemoryStore(TextReaderPreferences.defaults),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      await tester.pumpAndSettle();

      expect(tester.getTopLeft(find.text('第一章').first).dy, 32);
    },
  );

  test('normalizes legacy and night last-theme values safely', () {
    expect(
      const TextReaderPreferences(
        theme: ReaderThemePreset.eyeCare,
      ).normalized().lastNonNightTheme,
      ReaderThemePreset.eyeCare,
    );
    expect(
      const TextReaderPreferences(
        theme: ReaderThemePreset.night,
      ).normalized().lastNonNightTheme,
      ReaderThemePreset.day,
    );
    expect(
      const TextReaderPreferences(
        theme: ReaderThemePreset.night,
        lastNonNightTheme: ReaderThemePreset.deepNight,
      ).normalized().lastNonNightTheme,
      ReaderThemePreset.day,
    );
  });

  testWidgets('restores the last non-night theme after a reader re-entry', (
    WidgetTester tester,
  ) async {
    final _MemoryStore store = _MemoryStore(
      const TextReaderPreferences(theme: ReaderThemePreset.eyeCare),
    );
    final TextReaderController firstController = TextReaderController();
    await tester.pumpWidget(_reader(store, firstController));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await tester.pumpAndSettle();
    await firstController.showControls();
    await tester.pump();
    await tester.tap(find.byKey(const Key('reader-toolbar-night-theme')));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    expect(store.preferences.theme, ReaderThemePreset.night);
    expect(store.preferences.lastNonNightTheme, ReaderThemePreset.eyeCare);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    final TextReaderController secondController = TextReaderController();
    await tester.pumpWidget(_reader(store, secondController));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await tester.pumpAndSettle();
    await secondController.showControls();
    await tester.pump();
    await tester.tap(find.byKey(const Key('reader-toolbar-night-theme')));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    expect(store.preferences.theme, ReaderThemePreset.eyeCare);
    expect(store.preferences.lastNonNightTheme, ReaderThemePreset.eyeCare);
  });

  testWidgets(
    'center tap exits immersive mode before settings and restores the preference',
    (WidgetTester tester) async {
      final ReaderPlatform previousPlatform = ReaderPlatform.instance;
      final _RecordingReaderPlatform platform = _RecordingReaderPlatform();
      ReaderPlatform.instance = platform;
      try {
        // The coordinator is process-global; establish a known platform state
        // so this regression remains independent of earlier widget tests.
        final Object testHolder = Object();
        await ScreenAwakeCoordinator.instance.acquire(
          testHolder,
          keepScreenOn: false,
          immersiveMode: true,
        );
        await ScreenAwakeCoordinator.instance.release(testHolder);
        platform.requests.clear();
        final _MemoryStore store = _MemoryStore(
          const TextReaderPreferences(keepScreenOn: false, immersiveMode: true),
        );
        final TextReaderController controller = TextReaderController();
        await tester.pumpWidget(_reader(store, controller));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 500)),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey<String>('reader-content-surface')),
        );
        await tester.pumpAndSettle();

        final int immersiveRequest = platform.requests.lastIndexOf('0/1');
        expect(
          immersiveRequest,
          greaterThanOrEqualTo(0),
          reason: platform.requests.toString(),
        );

        await tester.tap(find.byKey(const Key('reader-toolbar-settings')));
        await tester.pumpAndSettle();
        final int settingsExit = platform.requests.lastIndexOf('0/0');
        expect(settingsExit, greaterThan(immersiveRequest));
        expect(
          platform.requests.where((String request) => request == '0/0').length,
          1,
        );
        expect(store.preferences.immersiveMode, isTrue);

        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        await controller.hideControls();
        await tester.pumpAndSettle();
        expect(platform.requests.lastIndexOf('0/1'), greaterThan(settingsExit));
        expect(store.preferences.immersiveMode, isTrue);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        ReaderPlatform.instance = previousPlatform;
      }
    },
  );
}

Widget _reader(_MemoryStore store, TextReaderController controller) =>
    MaterialApp(
      home: TextReaderView(
        bookId: 'theme-book',
        controller: controller,
        dataSource: const _ThemeDataSource(),
        stateStore: store,
      ),
    );

final class _MemoryStore implements TextReaderStateStore {
  _MemoryStore(this.preferences);

  TextReaderPreferences preferences;

  @override
  Future<TextReaderPreferences?> loadPreferences() async => preferences;

  @override
  Future<void> savePreferences(TextReaderPreferences value) async {
    preferences = value;
  }

  @override
  Future<List<ReaderBookmark>> loadBookmarks(String bookId) async =>
      const <ReaderBookmark>[];

  @override
  Future<void> addBookmark(ReaderBookmark bookmark) async {}

  @override
  Future<void> removeBookmark(String bookId, String bookmarkId) async {}

  @override
  Future<ReaderProgress?> loadProgress(String bookId) async => null;

  @override
  Future<void> saveProgress(String bookId, ReaderProgress progress) async {}
}

final class _RecordingReaderPlatform extends ReaderPlatform {
  final List<String> requests = <String>[];

  @override
  Future<ReaderPlatformCapabilities> capabilities() async =>
      const ReaderPlatformCapabilities(keepScreenOn: true, immersiveMode: true);

  @override
  Future<void> setReaderSystemUi({
    required bool keepScreenOn,
    required bool immersiveMode,
  }) async {
    requests.add('${keepScreenOn ? 1 : 0}/${immersiveMode ? 1 : 0}');
  }
}

final class _ThemeDataSource implements TextReaderDataSource {
  const _ThemeDataSource();

  static const _chapter = ReaderChapterInfo(
    id: 'chapter-1',
    index: 0,
    title: '第一章',
  );

  @override
  Future<ReaderBookInfo> loadBookInfo(String bookId) async =>
      ReaderBookInfo(id: bookId, title: '主题测试');

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
    chapterId: 'chapter-1',
    title: '第一章',
    paragraphs: <TextParagraph>[TextParagraph(id: 'paragraph-1', text: '正文')],
  );
}
