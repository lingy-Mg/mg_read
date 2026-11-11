import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/discovery/presentation/discovery_view_data.dart';
import 'package:mg_read/features/discovery/presentation/widgets/discovery_book_cover.dart';
import 'package:mg_read/features/library/presentation/library_book_list_view_data.dart';
import 'package:mg_read/features/library/presentation/widgets/library_book_cover.dart';
import 'package:mg_read/shared/presentation/source_branding.dart';
import 'package:mg_read/shared/presentation/widgets/default_content_cover_artwork.dart';
import 'package:mg_read/shared/presentation/widgets/async_book_cover_loader.dart';

void main() {
  testWidgets('provided bytes skip the remote request and still expose decode loading', (tester) async {
    final requests = <BookCoverRequest>[];
    final completion = Completer<List<int>?>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookCoverBytesLoaderProvider.overrideWithValue(_RecordingBookCoverLoader(requests, completion))],
        child: _host(
          BookCoverSourceScope(
            pluginId: 'provided-cover',
            child: DiscoveryBookCover(
              title: '本地已有封面',
              variant: DiscoveryCoverVariant.gothic,
              width: 112,
              height: 174,
              remoteContentId: 'provided-cover-book',
              coverUrl: Uri.parse('https://covers.example/provided-cover.png'),
              coverBytes: base64Decode(_onePixelPngBase64),
            ),
          ),
        ),
      ),
    );
    expect(requests, isEmpty);
    await _settleCoverImages(tester);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed remote covers finish loading with a visible failure fallback', (tester) async {
    final completion = Completer<List<int>?>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookCoverBytesLoaderProvider.overrideWithValue(_CompletingBookCoverLoader(completion))],
        child: _host(
          BookCoverSourceScope(
            pluginId: 'failed-cover',
            child: DiscoveryBookCover(
              title: '失败封面',
              variant: DiscoveryCoverVariant.gothic,
              width: 112,
              height: 174,
              remoteContentId: 'failed-cover-book',
              coverUrl: Uri.parse('https://covers.example/failed-cover.png'),
            ),
          ),
        ),
      ),
    );
    completion.completeError(StateError('cover request failed'));
    await _settleCoverImages(tester);
    expect(find.byKey(const Key('cover-load-failed')), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('uses the compact novel artwork when discovery cover is missing', (WidgetTester tester) async {
    await tester.pumpWidget(
      _host(const DiscoveryBookCover(title: '没有封面的书', variant: DiscoveryCoverVariant.gothic, width: 112, height: 174)),
    );

    expect(find.byType(DefaultContentCoverArtwork), findsOneWidget);
    expect(find.byIcon(Icons.menu_book_rounded), findsOneWidget);
    expect(find.text('小说'), findsOneWidget);
    expect(find.text('没有封面的书'), findsNothing);
  });

  testWidgets('uses the same artwork when a stored library cover cannot decode', (WidgetTester tester) async {
    await tester.pumpWidget(
      _host(
        const LibraryBookCover(
          title: '损坏封面的漫画',
          contentKind: ContentKind.manga,
          variant: LibraryCoverVariant.dusk,
          width: 80,
          height: 120,
          coverBytes: <int>[0],
        ),
      ),
    );
    await _settleCoverImages(tester);

    expect(find.byType(DefaultContentCoverArtwork), findsOneWidget);
    expect(find.byIcon(Icons.photo_library_rounded), findsOneWidget);
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

    expect(find.byType(DefaultContentCoverArtwork), findsOneWidget);
    expect(find.byKey(const Key('cover-load-progress')), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.getSemantics(find.byType(DiscoveryBookCover)).label, '异步封面 的封面加载中');

    completion.complete(null);
    await tester.pump();

    expect(find.byType(DefaultContentCoverArtwork), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('draws distinct compact artwork for every content kind without repeating titles', (WidgetTester tester) async {
    await tester.pumpWidget(
      _host(
        Wrap(
          children: <Widget>[
            for (final kind in DefaultCoverKind.values)
              SizedBox(
                width: 80,
                height: 120,
                child: DefaultContentCoverArtwork(
                  kind: kind,
                  title: '不应显示-${kind.name}',
                  width: 80,
                  height: 120,
                  startColor: const Color(0xFF263B63),
                  endColor: const Color(0xFF6E4D82),
                  foregroundColor: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
          ],
        ),
      ),
    );

    for (final kind in DefaultCoverKind.values) {
      expect(find.byKey(ValueKey<String>('default-cover-kind-${kind.name}')), findsOneWidget);
      expect(find.byKey(ValueKey<String>('default-cover-label-${kind.name}')), findsOneWidget);
      expect(find.text('不应显示-${kind.name}'), findsNothing);
    }
  });

  testWidgets('shows at most two title lines on large fallback artwork', (WidgetTester tester) async {
    await tester.pumpWidget(
      _host(
        const SizedBox(
          width: 168,
          height: 248,
          child: DefaultContentCoverArtwork(
            kind: DefaultCoverKind.audio,
            title: '这是一个大封面上显示的很长作品标题',
            width: 168,
            height: 248,
            startColor: Color(0xFF263B63),
            endColor: Color(0xFF6E4D82),
            foregroundColor: Colors.white,
            borderRadius: BorderRadius.all(Radius.circular(12)),
          ),
        ),
      ),
    );

    final title = tester.widget<Text>(find.byKey(const Key('default-cover-title')));
    expect(title.maxLines, 2);
    expect(title.overflow, TextOverflow.ellipsis);
  });

  testWidgets('uses the generic landscape cover presentation when requested', (WidgetTester tester) async {
    await tester.pumpWidget(
      _host(
        const DiscoveryBookCover(
          title: '视频海报',
          contentKind: PluginContentKind.video,
          variant: DiscoveryCoverVariant.gothic,
          width: 112,
          height: 74,
          presentation: DiscoveryCoverPresentation.landscape,
        ),
      ),
    );

    expect(tester.getSize(find.byType(DiscoveryBookCover)), const Size(112, 74));
    expect(find.byIcon(Icons.play_circle_fill_rounded), findsOneWidget);
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
    await _settleCoverImages(tester);

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
    await _settleCoverImages(tester);

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

// Engine image decoding runs outside FakeAsync. Await actual decode before
// settling the intentionally indeterminate loading indicator.
Future<void> _settleCoverImages(WidgetTester tester) async {
  final images = tester.widgetList<Image>(find.byType(Image)).toList();
  if (images.isNotEmpty) {
    final context = tester.element(find.byType(Image).first);
    await tester.runAsync(() => Future.wait(images.map((image) => precacheImage(image.image, context, onError: (_, _) {}))));
  }
  await tester.pumpAndSettle();
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
