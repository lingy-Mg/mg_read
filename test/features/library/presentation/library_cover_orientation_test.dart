import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/library/presentation/library_book_list_view_data.dart';
import 'package:mg_read/features/library/presentation/widgets/library_book_cover.dart';
import 'package:mg_read/features/library/presentation/widgets/library_book_grid.dart';
import 'package:mg_read/features/library/presentation/widgets/library_book_list.dart';

void main() {
  testWidgets('list keeps the primary portrait cover size for every source shape', (tester) async {
    await tester.pumpWidget(_host(LibraryBookList(books: _books, onOpenBook: (_) {})));

    final covers = tester.widgetList<LibraryBookCover>(find.byType(LibraryBookCover)).toList();
    expect(
      covers.map((cover) => Size(cover.width, cover.height)),
      everyElement(const Size(AppSpacing.listCoverWidth, AppSpacing.listCoverHeight)),
    );
  });

  testWidgets('mixed card grid keeps full-size portrait frames without inset stages', (tester) async {
    await tester.pumpWidget(
      _host(
        CustomScrollView(
          slivers: <Widget>[LibraryBookSliverGrid(books: _books, onOpenBook: (_) {})],
        ),
      ),
    );

    final covers = tester.widgetList<LibraryBookCover>(find.byType(LibraryBookCover)).toList();
    expect(covers, hasLength(3));
    final sizes = covers.map((cover) => Size(cover.width, cover.height)).toSet();
    expect(sizes, hasLength(1));
    expect(sizes.single.height, greaterThan(sizes.single.width));
  });
}

final List<LibraryBookListItemViewData> _books = <LibraryBookListItemViewData>[
  _book('portrait', CoverOrientation.portrait),
  _book('square', CoverOrientation.square),
  _book('landscape', CoverOrientation.landscape),
];

LibraryBookListItemViewData _book(String id, CoverOrientation orientation) => LibraryBookListItemViewData(
  id: id,
  title: id,
  coverVariant: LibraryCoverVariant.dusk,
  coverOrientation: orientation,
  status: LibraryBookStatus.local,
);

Widget _host(Widget child) => MaterialApp(
  theme: AppTheme.light(),
  home: Scaffold(body: SizedBox(width: 390, height: 700, child: child)),
);
