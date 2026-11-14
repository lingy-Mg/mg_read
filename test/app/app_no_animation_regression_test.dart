/// 无动画模式真实组合根回归：启动、刷新、提示条、开关、阅读翻页与目录标签。
/// 模拟 Runtime 仅验证 Flutter 行为，不替代电子墨水屏硬件刷新验收。
library;

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_startup.dart';
import 'package:mg_read/app/app_startup_gate.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/library/presentation/library_page.dart';
import 'package:mg_read/features/library/presentation/library_home_view_data.dart';
import 'package:mg_read/features/library/presentation/widgets/library_home_shell.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';
import 'mg_read_app_test_support.dart';
import 'package:mg_read_motion/mg_read_motion.dart';

void main() {
  testWidgets('enabling no-animation mode leaves no active animation work in the real app', (tester) async {
    final settings = await createTestAppSettings();
    await tester.pumpWidget(testMgReadApp(settings));
    await tester.pumpAndSettle();
    await settings.set(AppSettingKeys.noAnimations, true);
    await tester.pump();
    await tester.pump(); // Finish the scrollbar's scroll-metrics layout notification.
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    await settings.close();
  });
  testWidgets('real app theme changes complete without intermediate animation frames', (tester) async {
    final settings = await createTestAppSettings();
    await settings.set(AppSettingKeys.noAnimations, true);
    await tester.pumpWidget(testMgReadApp(settings));
    await tester.pumpAndSettle();
    await settings.set(AppSettingKeys.themeMode, 'dark');
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    await settings.close();
  });
  testWidgets('startup waiting stays static with motion disabled', (tester) async {
    final pending = Completer<AppStartupResources>();
    final startup = AppStartupController(
      openResources: () => pending.future,
      diagnostics: DiagnosticsManager(
        sink: const NoopDiagnosticEventSink(),
        registry: AppDiagnosticEvents.registry,
        source: DiagnosticSource.app,
      ),
    );
    final boot = startup.start();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appStartupControllerProvider.overrideWithValue(startup)],
        child: MaterialApp(
          theme: AppTheme.light(),
          builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: true), child: child!),
          home: const AppStartupGate(child: Scaffold(body: Text('content'))),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(MotionCircularProgressIndicator), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.binding.transientCallbackCount, 0);
    pending.complete(const AppStartupResources());
    await boot;
    await tester.pumpWidget(const SizedBox.shrink());
    await startup.close();
  });

  testWidgets('real app snackbar appears instantly with motion disabled', (tester) async {
    final settings = await createTestAppSettings();
    await settings.set(AppSettingKeys.noAnimations, true);
    await tester.pumpWidget(testMgReadApp(settings));
    await tester.pumpAndSettle();
    final page = tester.element(find.byType(LibraryPage));
    expect(MediaQuery.disableAnimationsOf(page), isTrue);
    ScaffoldMessenger.of(page).showMotionSnackBar(page, const SnackBar(content: Text('audit snack')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    final snack = tester.widget<SnackBar>(find.byType(SnackBar));
    expect(snack.animation!.value, 1);
    ScaffoldMessenger.of(page).hideCurrentSnackBar();
    await tester.pump();
    expect(find.byType(SnackBar), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await settings.close();
  });

  testWidgets('shelf pull refresh remains functional with static waiting feedback', (tester) async {
    final pending = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: LibraryHomeShell(
            data: LibraryHomeViewData(isPresentationFixture: false, continueReading: null, books: const []),
            isRefreshing: false,
            onRefresh: () => pending.future,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byKey(const Key('library-home-content')), const Offset(0, 350));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('正在刷新…'), findsOneWidget);
    expect(find.byType(RefreshProgressIndicator), findsNothing);
    expect(tester.binding.transientCallbackCount, 0);
    pending.complete();
    await tester.pumpAndSettle();
    expect(find.text('正在刷新…'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('real app switch updates immediately without animation frames', (tester) async {
    final settings = await createTestAppSettings();
    await settings.set(AppSettingKeys.noAnimations, true);
    await tester.pumpWidget(testMgReadApp(settings));
    await tester.pumpAndSettle();
    final page = tester.element(find.byType(LibraryPage));
    var enabled = false;
    unawaited(
      Navigator.of(page).push(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            body: StatefulBuilder(
              builder: (_, setLocalState) => MotionSwitch(value: enabled, onChanged: (value) => setLocalState(() => enabled = value)),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(MediaQuery.disableAnimationsOf(tester.element(find.byType(MotionSwitch))), isTrue);
    await tester.tap(find.byType(MotionSwitch));
    await tester.pump();
    expect(enabled, isTrue);
    expect(tester.widget<MotionSwitch>(find.byType(MotionSwitch)).value, isTrue);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    await settings.close();
  });

  testWidgets('vertical reader next and previous pages jump immediately without errors', (tester) async {
    final controller = TextReaderController();
    await tester.pumpWidget(_reader(controller, vertical: true));
    await tester.pumpAndSettle();
    expect(controller.snapshot.chapter?.id, 'c1');
    await controller.nextPage();
    await tester.pump();
    final position = tester.state<ScrollableState>(find.byType(Scrollable).first).position;
    final nextOffset = position.pixels;
    expect(nextOffset, greaterThan(0));
    await controller.previousPage();
    await tester.pump();
    expect(position.pixels, lessThan(nextOffset));
    expect(tester.takeException(), isNull);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('reader library tabs switch immediately with motion disabled', (tester) async {
    final controller = TextReaderController();
    await tester.pumpWidget(_reader(controller));
    await tester.pumpAndSettle();
    await controller.showControls();
    await tester.pumpAndSettle();
    await tester.tap(find.text('目录'));
    await tester.pumpAndSettle();
    final tabContext = tester.element(find.byType(TabBar));
    expect((ModalRoute.of(tabContext)! as ModalBottomSheetRoute).enableDrag, isFalse);
    expect(MediaQuery.disableAnimationsOf(tabContext), isTrue);
    final tabs = DefaultTabController.of(tabContext);
    expect(tabs.index, 1);
    await tester.tap(find.text('书签').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(tabs.animation!.value, 2);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}

Widget _reader(TextReaderController controller, {bool vertical = false}) => MaterialApp(
  builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: true), child: child!),
  home: TextReaderView(bookId: 'audit', controller: controller, dataSource: const _Source(), stateStore: _Store(vertical)),
);

class _Store implements TextReaderStateStore {
  const _Store(this.vertical);
  final bool vertical;
  @override
  Future<TextReaderPreferences?> loadPreferences() async => TextReaderPreferences(
    navigationMode: vertical ? ReaderNavigationMode.verticalScroll : ReaderNavigationMode.horizontalPages,
    keepScreenOn: false,
  );
  @override
  Future<List<ReaderBookmark>> loadBookmarks(String bookId) async => [];
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

class _Source implements TextReaderDataSource {
  const _Source();
  static const chapter = ReaderChapterInfo(id: 'c1', index: 0, title: '第一章');
  @override
  Future<ReaderBookInfo> loadBookInfo(String bookId) async => ReaderBookInfo(id: bookId, title: 'audit');
  @override
  Future<ChapterCatalogPage> loadChapterCatalog(String bookId, {String? cursor, int pageSize = 100}) async =>
      ChapterCatalogPage(items: const [chapter], total: 1, hasMore: false);
  @override
  Future<ReaderChapterInfo> loadChapterAtIndex(String bookId, int index) async => chapter;
  @override
  Future<TextChapterContent> loadChapterContent(String bookId, String chapterId) async => TextChapterContent(
    chapterId: chapter.id,
    title: chapter.title,
    paragraphs: [for (var i = 0; i < 24; i++) TextParagraph(id: 'p$i', text: '用于检查电子墨水屏无动画模式的阅读正文。' * 12)],
  );
}
