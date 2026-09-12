import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/discovery/presentation/discovery_view_data.dart';
import 'package:mg_read/features/discovery/presentation/widgets/discovery_book_cover.dart';
import 'package:mg_read/features/library/presentation/library_book_list_view_data.dart';
import 'package:mg_read/features/library/presentation/widgets/library_book_cover.dart';
import 'package:mg_read/shared/presentation/source_branding.dart';
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

  testWidgets('uses the generic landscape cover presentation when requested', (WidgetTester tester) async {
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
    expect((cover.decoration as BoxDecoration).borderRadius, BorderRadius.circular(10));
  });

  testWidgets('keeps the decoded cover ratio when height is not constrained', (WidgetTester tester) async {
    await tester.pumpWidget(
      _host(
        DiscoveryBookCover(
          title: '原始比例封面',
          variant: DiscoveryCoverVariant.gothic,
          width: 112,
          coverBytes: base64Decode(_onePixelPngBase64),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.getSize(find.byType(DiscoveryBookCover)), const Size(112, 112));
    expect(tester.widget<Image>(find.byType(Image)).fit, BoxFit.cover);
  });

  testWidgets('keeps the fixed height and derives width when width is not constrained', (WidgetTester tester) async {
    await tester.pumpWidget(
      _host(
        DiscoveryBookCover(
          title: '仅限制高度的封面',
          variant: DiscoveryCoverVariant.gothic,
          height: 174,
          coverBytes: base64Decode(_onePixelPngBase64),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.getSize(find.byType(DiscoveryBookCover)), const Size(174, 174));
  });

  testWidgets('loads remote source icons through the shared persistent cover loader', (WidgetTester tester) async {
    BookCoverMemoryCache.clear();
    addTearDown(BookCoverMemoryCache.clear);
    final completion = Completer<List<int>?>();
    final requests = <BookCoverRequest>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          bookCoverBytesLoaderProvider.overrideWithValue(_RecordingBookCoverLoader(requests, completion)),
          bookCoverBytesLoaderAvailableProvider.overrideWithValue(true),
        ],
        child: _host(const SourceIcon(sourceId: 'org.example.source', displayName: '示例源', iconUrl: 'https://icons.example/source.png')),
      ),
    );
    await tester.pump();

    expect(requests, hasLength(1));
    expect(requests.single.pluginId, 'org.example.source');
    expect(requests.single.remoteContentId, 'source-icon');
    expect(find.byKey(const ValueKey<String>('source-icon-memory-org.example.source')), findsNothing);

    completion.complete(base64Decode(_onePixelPngBase64));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const ValueKey<String>('source-icon-memory-org.example.source')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('cover memory cache preserves typed source identity', () {
    BookCoverMemoryCache.clear();
    addTearDown(BookCoverMemoryCache.clear);
    final bytes = Uint8List.fromList(<int>[1, 2, 3]);
    final discovery = _request(1);
    final shelf = _request(1);

    BookCoverMemoryCache.write(discovery, bytes);

    expect(identical(BookCoverMemoryCache.peek(shelf), bytes), isTrue);
  });

  test('cover memory cache evicts by encoded byte budget', () {
    BookCoverMemoryCache.clear();
    addTearDown(BookCoverMemoryCache.clear);
    for (var index = 0; index < 5; index += 1) {
      BookCoverMemoryCache.write(_request(index), Uint8List(4 * 1024 * 1024));
    }

    expect(BookCoverMemoryCache.peek(_request(0)), isNull);
    expect(BookCoverMemoryCache.peek(_request(4)), isNotNull);
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

final class _RecordingBookCoverLoader implements BookCoverBytesLoader {
  const _RecordingBookCoverLoader(this.requests, this.completion);

  final List<BookCoverRequest> requests;
  final Completer<List<int>?> completion;

  @override
  Future<List<int>?> resolve(BookCoverRequest request) {
    requests.add(request);
    return completion.future;
  }
}

BookCoverRequest _request(int index) => BookCoverRequest(
  pluginId: 'fixture-source',
  pluginVersion: '1.0.0',
  remoteContentId: 'book-$index',
  coverUrl: Uri.parse('https://covers.example/book-$index.png'),
);

const String _onePixelPngBase64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';
