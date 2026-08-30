import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/library/data/content_library_book_refresher.dart';

void main() {
  test('refreshes the shelf metadata, complete catalog, and cached cover from the source identity', () async {
    final root = await Directory.systemTemp.createTemp('mg-read-book-refresh-');
    final library = await ContentLibrary.open(dataRoot: root);
    addTearDown(() async {
      await library.close();
      await root.delete(recursive: true);
    });
    final oldCover = Uri.parse('https://source.example/cover.png');
    final item = await library.bookshelf.addFromSource(
      BookshelfAddRequest(
        title: '旧书名',
        author: '旧作者',
        kind: ContentKind.novel,
        pluginId: 'org.example.source',
        pluginVersion: '1.0.0',
        remoteContentId: 'book-original-url',
        coverUrl: oldCover,
        sourceUrl: Uri.parse('https://source.example/book-original-url'),
        description: '旧简介',
      ),
    );
    final oldCoverKey = CoverKey(
      pluginId: 'org.example.source',
      pluginVersion: '1.0.0',
      remoteContentId: 'book-original-url',
      coverUrl: oldCover,
    );
    await library.covers.save(key: oldCoverKey, bytes: const <int>[1, 2, 3]);
    await library.bookshelf.saveCover(id: item.id, bytes: const <int>[4, 5, 6], mimeType: 'image/png');

    final gateway = _RefreshGateway();
    await ContentLibraryBookRefresher(library, gateway).refresh(item.id.value);

    final refreshed = await library.getLibraryItem(item.id);
    expect(gateway.detailIds, <String>['book-original-url']);
    expect(gateway.chapterIds, <String>['book-original-url']);
    expect(refreshed?.title, '新书名');
    expect(refreshed?.author, '新作者');
    expect(refreshed?.description, '新简介');
    expect(refreshed?.coverUrl, Uri.parse('https://source.example/new-cover.png'));
    expect(refreshed?.sourceUrl, Uri.parse('https://source.example/book-original-url'));
    expect(refreshed?.chapterCount, 2);
    expect(refreshed?.latestChapterTitle, '第二章');
    expect(refreshed?.attributes.single.value, '98.7万');
    expect((await library.listAllCatalog(item.id)).map((entry) => entry.remoteIdentity), <String>['chapter-1', 'chapter-2']);
    expect(await library.covers.read(oldCoverKey), isNull);
    expect(await library.bookshelf.readCover(item.id), isNull);
  });

  test('retains the existing shelf item when a source refresh fails', () async {
    final root = await Directory.systemTemp.createTemp('mg-read-book-refresh-');
    final library = await ContentLibrary.open(dataRoot: root);
    addTearDown(() async {
      await library.close();
      await root.delete(recursive: true);
    });
    final item = await library.bookshelf.addFromSource(
      BookshelfAddRequest(
        title: '保留书名',
        author: null,
        kind: ContentKind.novel,
        pluginId: 'org.example.source',
        pluginVersion: '1.0.0',
        remoteContentId: 'book-failure',
        sourceUrl: Uri.parse('https://source.example/book-failure'),
        description: '保留简介',
      ),
    );

    await expectLater(ContentLibraryBookRefresher(library, _FailingRefreshGateway()).refresh(item.id.value), throwsStateError);

    final retained = await library.getLibraryItem(item.id);
    expect(retained?.title, '保留书名');
    expect(retained?.description, '保留简介');
    expect(await library.listAllCatalog(item.id), isEmpty);
  });
}

final class _RefreshGateway implements SourceContentGateway {
  final detailIds = <String>[];
  final chapterIds = <String>[];

  @override
  Future<PluginContentDetail> getDetail({required String pluginId, required String id}) async {
    detailIds.add(id);
    return PluginContentDetail(
      pluginId: pluginId,
      sourceName: '刷新数据源',
      summary: PluginContentSummary(
        id: id,
        title: '新书名',
        contentKind: PluginContentKind.novel,
        author: '新作者',
        url: Uri.parse('https://source.example/book-original-url'),
        coverUrl: Uri.parse('https://source.example/new-cover.png'),
        description: '新简介',
        language: 'zh-CN',
        status: PluginContentStatus.ongoing,
        access: PluginAccessKind.free,
        wordCount: 123456,
        chapterCount: 2,
        publishedAt: null,
        updatedAt: null,
        latestChapter: PluginLatestChapter(
          id: 'chapter-2',
          title: '第二章',
          url: Uri.parse('https://source.example/chapter-2'),
          updatedAt: null,
        ),
        categories: const <String>['玄幻'],
        tags: const <String>['连载'],
        attributes: const <PluginContentAttribute>[PluginContentAttribute(key: 'heat', label: '热度', value: '98.7万')],
      ),
      aliases: const <String>[],
      catalogUrl: Uri.parse('https://source.example/book-original-url'),
    );
  }

  @override
  Future<PluginChaptersResult> getChapters({required String pluginId, required String id}) async {
    chapterIds.add(id);
    return PluginChaptersResult(
      pluginId: pluginId,
      sourceName: '刷新数据源',
      items: <PluginChapterSummary>[_chapter('chapter-1', '第一章', 0), _chapter('chapter-2', '第二章', 1)],
    );
  }

  @override
  Future<PluginChapterContent> getContent({required String pluginId, required String id, required String chapterId}) =>
      throw UnsupportedError('Not used.');

  @override
  Future<PluginDiscoverResult> discover({
    required String pluginId,
    String? target,
    String? cursor,
    String? collectionId,
    int pageSize = 20,
  }) => throw UnsupportedError('Not used.');

  @override
  Future<List<PluginSourceDescriptor>> listSources() => throw UnsupportedError('Not used.');

  @override
  Future<PluginSearchResult> search({required String pluginId, required String query, String? cursor, int pageSize = 20}) =>
      throw UnsupportedError('Not used.');

  @override
  Future<PluginSearchSuggestionsResult> searchSuggestions({required String pluginId, String? cursor, int pageSize = 20}) =>
      throw UnsupportedError('Not used.');
}

final class _FailingRefreshGateway extends _RefreshGateway {
  @override
  Future<PluginContentDetail> getDetail({required String pluginId, required String id}) => Future<PluginContentDetail>.error(StateError('offline'));
}

PluginChapterSummary _chapter(String id, String title, int order) => PluginChapterSummary(
  id: id,
  title: title,
  order: order,
  url: Uri.parse('https://source.example/$id'),
  volumeTitle: null,
  wordCount: null,
  updatedAt: null,
  isLocked: false,
  attributes: const <PluginContentAttribute>[],
);
