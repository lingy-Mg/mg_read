import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/discovery/presentation/discovery_view_data.dart';
import 'package:mg_read/features/discovery/presentation/widgets/discovery_book_cover.dart';
import 'package:mg_read/features/library/presentation/library_book_list_view_data.dart';
import 'package:mg_read/features/library/presentation/widgets/library_book_cover.dart';
import 'package:mg_read/shared/presentation/widgets/default_book_cover_artwork.dart';

void main() {
  testWidgets('uses the neutral book artwork when discovery cover is missing', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const DiscoveryBookCover(
          title: '没有封面的书',
          variant: DiscoveryCoverVariant.gothic,
          width: 112,
          height: 174,
        ),
      ),
    );

    expect(find.byType(DefaultBookCoverArtwork), findsOneWidget);
    expect(find.byIcon(Icons.menu_book_rounded), findsOneWidget);
    expect(find.text('没有封面的书'), findsOneWidget);
  });

  testWidgets(
    'uses the same artwork when a stored library cover cannot decode',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(
          const LibraryBookCover(
            title: '损坏封面的书',
            variant: LibraryCoverVariant.dusk,
            width: 80,
            height: 120,
            coverBytes: <int>[0],
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(DefaultBookCoverArtwork), findsOneWidget);
      expect(find.byIcon(Icons.menu_book_rounded), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

Widget _host(Widget child) => MaterialApp(
  theme: AppTheme.light(),
  home: Scaffold(body: Center(child: child)),
);
