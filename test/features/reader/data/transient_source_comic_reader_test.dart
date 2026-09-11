import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';

import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/reader/data/content_library_source_comic_reader.dart';
import 'package:mg_read/features/reader/data/transient_source_comic_reader.dart';

void main() {
  test('loads one manifest for every image in a discovery manga chapter', () async {
    final gateway = _Gateway(pageCount: 3);
    final fetched = <Uri>[];
    final reader = TransientSourceComicReaderDataSource(
      detail: _detail,
      catalog: _catalog,
      gateway: gateway,
      fetcher: (Uri uri) async {
        fetched.add(uri);
        return Uint8List.fromList(<int>[1, 2, 3]);
      },
    );

    final book = await reader.loadBookInfo('manga-1');
    expect(book.title, '示例漫画');
    expect(book.sourceName, '示例漫画源');
    expect(book.sourceUrl, Uri.parse('https://example.com/manga-1'));
    final first = await reader.loadChapterCatalog('manga-1', pageSize: 1);
    expect(first.items.single.id, 'chapter-1');
    expect(first.items.single.title, '第一章');
    expect(first.items.single.index, 0);
    expect(first.nextCursor, 'transient:1');
    expect((await reader.loadChapterCatalog('manga-1', cursor: first.nextCursor)).items.single.id, 'chapter-2');

    final content = await reader.loadChapterContent('manga-1', 'chapter-1');
    expect(
      content.images.first,
      const ComicImageInfo(id: 'image-1', index: 0, width: 100, height: 200, contentType: 'image/png', contentVersion: '1'),
    );
    expect(content.images, hasLength(3));
    expect(
      await Future.wait<Uint8List>([for (final image in content.images) reader.loadImageBytes('manga-1', 'chapter-1', image.id)]),
      everyElement(<int>[1, 2, 3]),
    );
    expect(gateway.contentCalls, 1);
    expect(fetched, <Uri>[
      Uri.parse('https://example.com/chapter-1/image-1.png?generation=1'),
      Uri.parse('https://example.com/chapter-1/image-2.png?generation=1'),
      Uri.parse('https://example.com/chapter-1/image-3.png?generation=1'),
    ]);
  });

  test('single-flights concurrent loads of the same chapter manifest', () async {
    final release = Completer<void>();
    final gateway = _Gateway(contentRelease: release);
    final reader = TransientSourceComicReaderDataSource(
      detail: _detail,
      catalog: _catalog,
      gateway: gateway,
      fetcher: (_) async => Uint8List(1),
    );

    final first = reader.loadChapterContent('manga-1', 'chapter-1');
    final second = reader.loadChapterContent('manga-1', 'chapter-1');
    await gateway.contentStarted.future.timeout(const Duration(seconds: 5));
    expect(gateway.contentCalls, 1);
    release.complete();

    final contents = await Future.wait<ComicChapterContent>(<Future<ComicChapterContent>>[first, second]);
    expect(identical(contents.first, contents.last), isTrue);
    expect(gateway.contentCalls, 1);
  });

  test('refreshes and retries only once after an explicit authorization failure', () async {
    final gateway = _Gateway(varyUrlByCall: true);
    final fetched = <Uri>[];
    final reader = TransientSourceComicReaderDataSource(
      detail: _detail,
      catalog: _catalog,
      gateway: gateway,
      fetcher: (uri) async {
        fetched.add(uri);
        throw ComicImageHttpStatusException(403, uri);
      },
    );
    await reader.loadChapterContent('manga-1', 'chapter-1');

    await expectLater(
      reader.loadImageBytes('manga-1', 'chapter-1', 'image-1'),
      throwsA(isA<ReaderFailure>().having((failure) => failure.code, 'code', 'source_comic_image_load_failed')),
    );

    expect(gateway.contentCalls, 2);
    expect(fetched.map((uri) => uri.queryParameters['generation']), <String?>['1', '2']);
  });

  test('keeps progress in the route-lifetime state store', () async {
    final store = TransientComicReaderStateStore();
    const progress = ComicReaderProgress(chapterId: 'chapter-2', imageId: 'image-1', imageFraction: .4, chapterIndex: 1, bookFraction: .8);
    await store.saveProgress('manga-1', progress);
    expect(await store.loadProgress('manga-1'), progress);
    expect(await store.loadBookmarks('manga-1'), isEmpty);
  });

  test('keeps only three recently used preview manifests', () async {
    final gateway = _Gateway();
    final reader = TransientSourceComicReaderDataSource(detail: _detail, catalog: _catalogWithChapters(4), gateway: gateway);

    for (final chapterId in <String>['chapter-1', 'chapter-2', 'chapter-3']) {
      await reader.loadChapterContent('manga-1', chapterId);
    }
    await reader.loadChapterContent('manga-1', 'chapter-1');
    await reader.loadChapterContent('manga-1', 'chapter-4');
    await reader.loadChapterContent('manga-1', 'chapter-2');

    expect(gateway.contentCalls, 5, reason: 'touching chapter-1 makes chapter-2 the least recently used manifest');
  });

  test('reports a safe image location when a preview image request fails', () async {
    final reader = TransientSourceComicReaderDataSource(
      detail: _detail,
      catalog: _catalog,
      gateway: _Gateway(),
      fetcher: (_) => throw StateError('https://private.example/signed-image'),
    );
    await reader.loadChapterContent('manga-1', 'chapter-1');

    await expectLater(
      reader.loadImageBytes('manga-1', 'chapter-1', 'image-1'),
      throwsA(
        isA<ReaderFailure>()
            .having((failure) => failure.code, 'code', 'source_comic_image_load_failed')
            .having((failure) => failure.location, 'location', '下载漫画图片')
            .having((failure) => failure.message, 'message', '漫画图片暂时无法加载，请检查网络后重试。'),
      ),
    );
  });
}

final class _Gateway implements SourceContentGateway {
  _Gateway({this.pageCount = 1, this.varyUrlByCall = true, this.contentRelease});

  final int pageCount;
  final bool varyUrlByCall;
  final Completer<void>? contentRelease;
  final Completer<void> contentStarted = Completer<void>();
  int contentCalls = 0;

  @override
  Future<PluginChapterContent> getContent({required String pluginId, required String id, required String chapterId}) async {
    contentCalls += 1;
    if (!contentStarted.isCompleted) contentStarted.complete();
    await contentRelease?.future;
    return PluginChapterContent(
      pluginId: pluginId,
      sourceName: '示例漫画源',
      contentKind: PluginContentKind.manga,
      chapterId: chapterId,
      title: chapterId == 'chapter-1' ? '第一章' : '第二章',
      updatedAt: null,
      text: null,
      pages: <PluginMangaPage>[
        for (var index = 0; index < pageCount; index++)
          PluginMangaPage(
            id: 'image-${index + 1}',
            index: index,
            url: Uri.parse('https://example.com/$chapterId/image-${index + 1}.png${varyUrlByCall ? '?generation=$contentCalls' : ''}'),
            mimeType: 'image/png',
            width: 100,
            height: 200,
            resourcePolicy: PluginMangaPageResourcePolicy.sessionOnly,
            expiresAt: null,
          ),
      ],
    );
  }

  @override
  Future<PluginContentDetail> getDetail({required String pluginId, required String id}) => throw UnimplementedError();
  @override
  Future<PluginChaptersResult> getChapters({required String pluginId, required String id}) => throw UnimplementedError();
  @override
  Future<List<PluginSourceDescriptor>> listSources() => throw UnimplementedError();
  @override
  Future<PluginSearchResult> search({required String pluginId, required String query, String? cursor, int pageSize = 20}) =>
      throw UnimplementedError();
  @override
  Future<PluginSearchSuggestionsResult> searchSuggestions({required String pluginId, String? cursor, int pageSize = 20}) =>
      throw UnimplementedError();
  @override
  Future<PluginDiscoverResult> discover({
    required String pluginId,
    String? target,
    String? cursor,
    String? collectionId,
    int pageSize = 20,
  }) => throw UnimplementedError();
}

final _detail = PluginContentDetail(
  pluginId: 'org.example.manga',
  sourceName: '示例漫画源',
  summary: _summary,
  aliases: const <String>[],
  catalogUrl: Uri.parse('https://example.com/manga-1'),
);

final _summary = PluginContentSummary(
  id: 'manga-1',
  title: '示例漫画',
  contentKind: PluginContentKind.manga,
  author: '示例作者',
  url: null,
  coverUrl: null,
  description: '示例简介',
  language: 'zh-CN',
  status: PluginContentStatus.ongoing,
  access: PluginAccessKind.free,
  wordCount: null,
  chapterCount: 2,
  publishedAt: null,
  updatedAt: null,
  latestChapter: null,
  categories: const <String>[],
  tags: const <String>[],
  attributes: const <PluginContentAttribute>[],
);

final _catalog = PluginChaptersResult(
  pluginId: 'org.example.manga',
  sourceName: '示例漫画源',
  items: <PluginChapterSummary>[
    PluginChapterSummary(
      id: 'chapter-1',
      title: '第一章',
      order: 0,
      url: null,
      volumeTitle: null,
      wordCount: null,
      updatedAt: null,
      isLocked: false,
      attributes: <PluginContentAttribute>[],
    ),
    PluginChapterSummary(
      id: 'chapter-2',
      title: '第二章',
      order: 1,
      url: null,
      volumeTitle: null,
      wordCount: null,
      updatedAt: null,
      isLocked: false,
      attributes: <PluginContentAttribute>[],
    ),
  ],
);

PluginChaptersResult _catalogWithChapters(int count) => PluginChaptersResult(
  pluginId: 'org.example.manga',
  sourceName: '示例漫画源',
  items: <PluginChapterSummary>[
    for (var index = 0; index < count; index++)
      PluginChapterSummary(
        id: 'chapter-${index + 1}',
        title: '第${index + 1}章',
        order: index,
        url: null,
        volumeTitle: null,
        wordCount: null,
        updatedAt: null,
        isLocked: false,
        attributes: const <PluginContentAttribute>[],
      ),
  ],
);
