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
}

final class _ReadingLibraryOverviewLoader implements LibraryOverviewLoader {
  const _ReadingLibraryOverviewLoader();

  @override
  Future<LibraryOverview> load() async => LibraryOverview(
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
    String libraryItemId, {
    ReaderObserver? observer,
  }) {
    requestedBookId.complete(libraryItemId);
    return _pendingRequest.future;
  }
}
