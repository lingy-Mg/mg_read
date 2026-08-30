import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/discovery/presentation/discovery_view_data.dart';
import 'package:mg_read/features/discovery/presentation/widgets/discovery_book_cover.dart';
import 'package:mg_read/features/library/presentation/library_book_list_view_data.dart';
import 'package:mg_read/features/library/presentation/widgets/library_book_cover.dart';
import 'package:mg_read/shared/presentation/widgets/default_book_cover_artwork.dart';
import 'package:mg_read/shared/presentation/widgets/async_book_cover_loader.dart';

void main() {
  testWidgets('uses the neutral book artwork when discovery cover is missing', (WidgetTester tester) async {
    await tester.pumpWidget(
      _host(const DiscoveryBookCover(title: '没有封面的书', variant: DiscoveryCoverVariant.gothic, width: 112, height: 174)),
    );

    expect(find.byType(DefaultBookCoverArtwork), findsOneWidget);
    expect(find.byIcon(Icons.menu_book_rounded), findsOneWidget);
    expect(find.text('没有封面的书'), findsOneWidget);
  });

  testWidgets('uses the same artwork when a stored library cover cannot decode', (WidgetTester tester) async {
    await tester.pumpWidget(
      _host(const LibraryBookCover(title: '损坏封面的书', variant: LibraryCoverVariant.dusk, width: 80, height: 120, coverBytes: <int>[0])),
    );
    await tester.pumpAndSettle();

    expect(find.byType(DefaultBookCoverArtwork), findsOneWidget);
    expect(find.byIcon(Icons.menu_book_rounded), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows a loading cover without delaying its surrounding layout', (WidgetTester tester) async {
    final completion = Completer<List<int>?>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookCoverBytesLoaderProvider.overrideWithValue(_CompletingBookCoverLoader(completion))],
        child: _host(
          BookCoverSourceScope(
            pluginId: 'fixture-source',
            child: DiscoveryBookCover(
              title: '异步封面',
              remoteContentId: 'book-1',
              coverUrl: Uri.parse('https://covers.example/book-1.png'),
              variant: DiscoveryCoverVariant.gothic,
              width: 112,
              height: 174,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(DefaultBookCoverArtwork), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(tester.getSemantics(find.byType(DiscoveryBookCover)).label, '异步封面 的封面加载中');

    completion.complete(null);
    await tester.pump();

    expect(find.byType(DefaultBookCoverArtwork), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('uses the landscape cover presentation for video posters', (WidgetTester tester) async {
    await tester.pumpWidget(
      _host(
        const DiscoveryBookCover(
          title: '视频海报',
          variant: DiscoveryCoverVariant.gothic,
          width: 112,
          height: 74,
          presentation: DiscoveryCoverPresentation.landscape,
        ),
      ),
    );

    expect(tester.getSize(find.byType(DiscoveryBookCover)), const Size(112, 74));
    final cover = tester.widget<DecoratedBox>(find.byType(DecoratedBox).first);
    expect((cover.decoration! as BoxDecoration).borderRadius, BorderRadius.circular(10));
  });
}

Widget _host(Widget child) => MaterialApp(
  theme: AppTheme.light(),
  home: Scaffold(body: Center(child: child)),
);

final class _CompletingBookCoverLoader implements BookCoverBytesLoader {
  const _CompletingBookCoverLoader(this.completion);

  final Completer<List<int>?> completion;

  @override
  Future<List<int>?> resolve(BookCoverRequest request) => completion.future;
}
