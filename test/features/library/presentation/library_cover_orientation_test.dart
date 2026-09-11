import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
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
    await tester.pumpAndSettle();

    final covers = tester.widgetList<LibraryBookCover>(find.byType(LibraryBookCover)).toList();
    expect(
      covers.map((cover) => Size(cover.width, cover.height)),
      everyElement(const Size(AppSpacing.listCoverWidth, AppSpacing.listCoverHeight)),
    );
    expect(tester.widgetList<Image>(find.byType(Image)).map((image) => image.fit), everyElement(BoxFit.contain));
  });

  testWidgets('card mode uses equal-width masonry covers with intrinsic image ratios', (tester) async {
    await tester.pumpWidget(
      _host(
        CustomScrollView(
          slivers: <Widget>[LibraryBookSliverGrid(books: _books, onOpenBook: (_) {})],
        ),
      ),
    );
    await tester.pump();

    final covers = tester.widgetList<LibraryBookCover>(find.byType(LibraryBookCover)).toList();
    expect(covers, hasLength(3));
    expect(find.byType(SliverMasonryGrid), findsOneWidget);
    expect(covers.map((cover) => cover.width).toSet(), hasLength(1));
    expect(covers.map((cover) => cover.useIntrinsicAspectRatio), everyElement(isTrue));
    final images = tester.widgetList<Image>(find.byType(Image)).toList();
    expect(images.map((image) => image.width).toSet(), hasLength(1));
    expect(images.map((image) => image.height), everyElement(isNull));
    expect(images.map((image) => image.fit), everyElement(BoxFit.fitWidth));
  });

  testWidgets('masonry uses two phone columns and adds columns on wider devices', (tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    Future<int> columnCountAt(double width) async {
      await tester.binding.setSurfaceSize(Size(width, 700));
      await tester.pumpWidget(
        _host(
          CustomScrollView(
            slivers: <Widget>[LibraryBookSliverGrid(books: _books.take(1), onOpenBook: (_) {})],
          ),
          width: width,
        ),
      );
      final grid = tester.widget<SliverMasonryGrid>(find.byType(SliverMasonryGrid));
      return (grid.gridDelegate as SliverSimpleGridDelegateWithFixedCrossAxisCount).crossAxisCount;
    }

    expect(await columnCountAt(390), 2);
    expect(await columnCountAt(760), 3);
    expect(await columnCountAt(1080), 4);
    expect(await columnCountAt(1500), 6);
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
  coverAssetPath: _coverAssetPath(orientation),
  status: LibraryBookStatus.local,
);

String _coverAssetPath(CoverOrientation orientation) => switch (orientation) {
  CoverOrientation.portrait => 'assets/fixtures/home_covers/lord_of_mysteries.png',
  CoverOrientation.square => 'assets/branding/mg_read_logo.png',
  CoverOrientation.landscape => 'assets/illustrations/home/continue_reading_backdrop.png',
};

Widget _host(Widget child, {double width = 390}) => MaterialApp(
  theme: AppTheme.light(),
  home: Scaffold(
    body: SizedBox(width: width, height: 700, child: child),
  ),
);
