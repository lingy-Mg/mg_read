import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';

import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/reader/data/transient_source_comic_reader.dart';

void main() {
  test('adapts a discovery manga catalog and refreshes image URLs per request', () async {
    final gateway = _Gateway();
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

    expect((await reader.loadBookInfo('manga-1')).title, '示例漫画');
    final first = await reader.loadChapterCatalog('manga-1', pageSize: 1);
    expect(first.items.single.id, 'chapter-1');
    expect(first.items.single.title, '第一章');
    expect(first.items.single.index, 0);
    expect(first.nextCursor, 'transient:1');
    expect((await reader.loadChapterCatalog('manga-1', cursor: first.nextCursor)).items.single.id, 'chapter-2');

    final content = await reader.loadChapterContent('manga-1', 'chapter-1');
    expect(
      content.images.single,
      const ComicImageInfo(id: 'image-1', index: 0, width: 100, height: 200, contentType: 'image/png', contentVersion: '1'),
    );
    expect(await reader.loadImageBytes('manga-1', 'chapter-1', 'image-1'), <int>[1, 2, 3]);
    expect(await reader.loadImageBytes('manga-1', 'chapter-1', 'image-1'), <int>[1, 2, 3]);
    expect(gateway.contentCalls, 3);
    expect(fetched, <Uri>[
      Uri.parse('https://example.com/chapter-1/image-1.png?generation=2'),
      Uri.parse('https://example.com/chapter-1/image-1.png?generation=3'),
    ]);
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
}

final class _Gateway implements SourceContentGateway {
  int contentCalls = 0;

  @override
  Future<PluginChapterContent> getContent({required String pluginId, required String id, required String chapterId}) async {
    contentCalls += 1;
    return PluginChapterContent(
      pluginId: pluginId,
      sourceName: '示例漫画源',
      contentKind: PluginContentKind.manga,
      chapterId: chapterId,
      title: chapterId == 'chapter-1' ? '第一章' : '第二章',
      updatedAt: null,
      text: null,
      pages: <PluginMangaPage>[
        PluginMangaPage(
          id: 'image-1',
          index: 0,
          url: Uri.parse('https://example.com/$chapterId/image-1.png?generation=$contentCalls'),
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
  catalogUrl: null,
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
