import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';

import 'package:mg_read/app/app.dart';
import 'package:mg_read/features/library/application/library_overview_loader.dart';
import 'package:mg_read/features/library/application/library_page_controller.dart';
import 'package:mg_read/features/library/domain/library_item_summary.dart';
import 'package:mg_read/features/library/domain/library_overview.dart';
import 'package:mg_read/features/library/presentation/widgets/library_book_list.dart';
import 'package:mg_read/features/library/presentation/widgets/library_continue_reading_card.dart';
import 'package:mg_read/features/reader/application/library_reader_launcher.dart';
import 'package:mg_read/features/reader/application/reader_launch_request.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a shelf item starts a resolved reader launch', (
    WidgetTester tester,
  ) async {
    final launcher = _PendingReaderLauncher();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          libraryOverviewLoaderProvider.overrideWithValue(
            const _ReadingLibraryOverviewLoader(),
          ),
          libraryReaderLauncherProvider.overrideWithValue(launcher),
        ],
        child: const MgReadApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('已加入书架的书'), findsAtLeastNWidgets(1));
    expect(find.byType(ReadingProgressBar), findsOneWidget);

    await tester.tap(find.byType(LibraryBookListItem));
    await tester.pump();
    expect(await launcher.requestedBookId.future, 'library-book-1');
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await binding.convertFlutterSurfaceToImage();
    await tester.pump();
    await binding.takeScreenshot('library_reader_start_light');
  });

  testWidgets('returns to the shelf before reader save and refresh complete', (
    WidgetTester tester,
  ) async {
    final loader = _PendingRefreshOverviewLoader();
    final stateStore = _PendingReaderStateStore();
    addTearDown(() {
      stateStore.completeSave();
      loader.completeRefresh();
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          libraryOverviewLoaderProvider.overrideWithValue(loader),
          libraryReaderLauncherProvider.overrideWithValue(
            _ImmediateReaderLauncher(stateStore),
          ),
        ],
        child: const MgReadApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(LibraryBookListItem), findsOneWidget);
    expect(loader.loadCount, 1);

    await tester.tap(find.byType(LibraryBookListItem));
    await tester.pumpAndSettle();
    expect(find.byTooltip('返回'), findsOneWidget);

    await tester.tap(find.byTooltip('返回'));
    // The route pop, final save request, and refresh request all happen
    // before either intentionally pending future is released.
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(LibraryBookListItem), findsOneWidget);
    expect(find.text('挂起保存测试书'), findsOneWidget);
    expect(stateStore.saveStarted.isCompleted, isTrue);
    expect(loader.refreshStarted.isCompleted, isTrue);
    expect(stateStore.saveCompleted, isFalse);
    expect(loader.refreshCompleted, isFalse);

    stateStore.completeSave();
    loader.completeRefresh();
    await tester.pumpAndSettle();
  });
}

final class _ReadingLibraryOverviewLoader implements LibraryOverviewLoader {
  const _ReadingLibraryOverviewLoader();

  @override
  Future<LibraryOverview> load({Object? visibility}) async => LibraryOverview(
    items: <LibraryItemSummary>[
      LibraryItemSummary(
        id: 'library-book-1',
        title: '已加入书架的书',
        readingProgress: 0.42,
        readingChapterIndex: 4,
        lastReadAtUtc: DateTime.utc(2026, 8, 21),
      ),
    ],
  );
}

final class _PendingReaderLauncher implements LibraryReaderLauncher {
  final requestedBookId = Completer<String>();
  final _pendingRequest = Completer<ReaderLaunchRequest>();

  @override
  Future<ReaderLaunchRequest> launch(
    String libraryItemId,
  ) {
    requestedBookId.complete(libraryItemId);
    return _pendingRequest.future;
  }
}

final class _ImmediateReaderLauncher implements LibraryReaderLauncher {
  _ImmediateReaderLauncher(this.stateStore);

  final _PendingReaderStateStore stateStore;

  @override
  Future<ReaderLaunchRequest> launch(
    String libraryItemId,
  ) async => NovelReaderLaunchRequest(
    bookId: libraryItemId,
    dataSource: const _ReaderDataSource(),
    stateStore: stateStore,
  );
}

final class _PendingRefreshOverviewLoader implements LibraryOverviewLoader {
  final Completer<LibraryOverview> _refresh = Completer<LibraryOverview>();
  final Completer<void> refreshStarted = Completer<void>();
  var loadCount = 0;

  bool get refreshCompleted => _refresh.isCompleted;

  @override
  Future<LibraryOverview> load({Object? visibility}) {
    loadCount += 1;
    if (loadCount == 1) {
      return Future<LibraryOverview>.value(
        LibraryOverview(
          items: <LibraryItemSummary>[
            LibraryItemSummary(id: 'pending-reader-book', title: '挂起保存测试书'),
          ],
        ),
      );
    }
    if (!refreshStarted.isCompleted) refreshStarted.complete();
    return _refresh.future;
  }

  void completeRefresh() {
    if (!_refresh.isCompleted) {
      _refresh.complete(
        LibraryOverview(
          items: <LibraryItemSummary>[
            LibraryItemSummary(id: 'pending-reader-book', title: '挂起保存测试书'),
          ],
        ),
      );
    }
  }
}

final class _PendingReaderStateStore implements TextReaderStateStore {
  final Completer<void> _save = Completer<void>();
  final Completer<void> saveStarted = Completer<void>();

  bool get saveCompleted => _save.isCompleted;

  @override
  Future<ReaderProgress?> loadProgress(String bookId) async =>
      const ReaderProgress(
        chapterId: 'reader-chapter-1',
        paragraphId: 'reader-paragraph-1',
      );

  @override
  Future<void> saveProgress(String bookId, ReaderProgress progress) {
    if (!saveStarted.isCompleted) saveStarted.complete();
    return _save.future;
  }

  @override
  Future<TextReaderPreferences?> loadPreferences() async => null;

  @override
  Future<void> savePreferences(TextReaderPreferences preferences) async {}

  @override
  Future<List<ReaderBookmark>> loadBookmarks(String bookId) async =>
      const <ReaderBookmark>[];

  @override
  Future<void> addBookmark(ReaderBookmark bookmark) async {}

  @override
  Future<void> removeBookmark(String bookId, String bookmarkId) async {}

  void completeSave() {
    if (!_save.isCompleted) _save.complete();
  }
}

final class _ReaderDataSource implements TextReaderDataSource {
  const _ReaderDataSource();

  static const ReaderChapterInfo _chapter = ReaderChapterInfo(
    id: 'reader-chapter-1',
    title: '第一章',
    index: 0,
  );

  @override
  Future<ReaderBookInfo> loadBookInfo(String bookId) async =>
      ReaderBookInfo(id: bookId, title: '挂起保存测试书', author: '测试作者');

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
  Future<ReaderChapterInfo> loadChapterAtIndex(String bookId, int index) async {
    if (index != 0) throw RangeError.index(index, const <int>[0]);
    return _chapter;
  }

  @override
  Future<TextChapterContent> loadChapterContent(
    String bookId,
    String chapterId,
  ) async => TextChapterContent(
    chapterId: 'reader-chapter-1',
    title: '第一章',
    paragraphs: <TextParagraph>[
      TextParagraph(id: 'reader-paragraph-1', text: '用于验证退出时序的正文。'),
    ],
  );
}
