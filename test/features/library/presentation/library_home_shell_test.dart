import 'dart:async';
import 'dart:convert';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../../support/visual_evidence.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/library/presentation/library_book_list_view_data.dart';
import 'package:mg_read/features/library/presentation/library_home_view_data.dart';
import 'package:mg_read/features/library/presentation/widgets/library_book_cover.dart';
import 'package:mg_read/features/library/presentation/widgets/library_book_grid.dart';
import 'package:mg_read/features/library/presentation/widgets/library_book_list.dart';
import 'package:mg_read/features/library/presentation/widgets/library_book_removal_transition.dart';
import 'package:mg_read/features/library/presentation/widgets/library_book_swipe_actions.dart';
import 'package:mg_read/features/library/presentation/widgets/library_continue_reading_card.dart';
import 'package:mg_read/features/library/presentation/widgets/library_home_controls.dart';
import 'package:mg_read/features/library/presentation/widgets/library_home_shell.dart';
import 'package:mg_read/features/library/presentation/widgets/library_home_top_bar.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';
import 'package:mg_read/shared/presentation/widgets/async_book_cover_loader.dart';
import 'package:mg_read/shared/presentation/widgets/app_bottom_navigation.dart';

part 'library_home_shell_basics_part.dart';
part 'library_home_shell_actions_part.dart';
part 'library_home_shell_layout_part.dart';

void main() {
  _registerLibraryHomeShellBasics();
  _registerLibraryHomeShellActions();
  _registerLibraryHomeShellLayout();
}

LibraryHomeViewData _largeLibraryHomeData(int count) => LibraryHomeViewData(
  isPresentationFixture: true,
  continueReading: null,
  books: List<LibraryBookListItemViewData>.generate(
    count,
    (int index) => LibraryBookListItemViewData(
      id: 'performance-book-$index',
      title: '性能测试书 $index',
      coverVariant: LibraryCoverVariant.values[index % LibraryCoverVariant.values.length],
      status: LibraryBookStatus.local,
    ),
  ),
);

Future<void> _setViewport(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pump();
}

Future<void> _openHomeBookMenu(WidgetTester tester) async {
  final Finder book = find.byWidgetPredicate(
    (Widget widget) => widget is LibraryBookListItem && widget.data.id == 'fixture-lord-of-mysteries',
  );
  final Finder content = find.byKey(const Key('library-home-content'));
  for (int attempt = 0; attempt < 8 && book.evaluate().isEmpty; attempt++) {
    await tester.drag(content, const Offset(0, -240));
    await settleWidgetImages(tester);
  }
  expect(book, findsOneWidget);
  await tester.ensureVisible(book);
  await settleWidgetImages(tester);
  await tester.tap(find.descendant(of: book, matching: find.byTooltip('书籍更多操作')));
  await settleWidgetImages(tester);
}

LibraryHomeViewData _asyncCoverLibraryHomeData() {
  final requests = List<BookCoverRequest>.generate(
    3,
    (int index) => BookCoverRequest(
      pluginId: 'cover-source',
      pluginVersion: '1.0.0',
      remoteContentId: 'book-$index',
      coverUrl: Uri.parse('https://example.com/book-$index.png'),
    ),
  );
  return LibraryHomeViewData(
    isPresentationFixture: false,
    continueReading: LibraryContinueReadingViewData(
      bookId: 'book-0',
      title: '继续阅读测试',
      chapter: '第1章',
      progress: 0.5,
      lastReadLabel: '刚刚',
      coverVariant: LibraryCoverVariant.dusk,
      coverRequest: requests[0],
    ),
    books: <LibraryBookListItemViewData>[
      LibraryBookListItemViewData(
        id: 'book-1',
        title: '连载测试',
        coverVariant: LibraryCoverVariant.dawn,
        status: LibraryBookStatus.ongoing,
        coverRequest: requests[1],
      ),
      LibraryBookListItemViewData(
        id: 'book-2',
        title: '完结测试',
        coverVariant: LibraryCoverVariant.ocean,
        status: LibraryBookStatus.completed,
        coverRequest: requests[2],
      ),
    ],
  );
}

final class _CountingBookCoverBytesLoader implements BookCoverBytesLoader {
  final Map<BookCoverRequest, int> loadCounts = <BookCoverRequest, int>{};

  @override
  Future<List<int>?> resolve(BookCoverRequest request) async {
    loadCounts.update(request, (int count) => count + 1, ifAbsent: () => 1);
    return base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=');
  }
}
