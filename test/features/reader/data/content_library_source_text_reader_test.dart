import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';

import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/reader/data/content_library_source_text_reader.dart';

void main() {
  test(
    'opens a persisted shelf source and restores durable reading progress',
    () async {
      final root = await Directory.systemTemp.createTemp('mg-read-reader-');
      final library = await ContentLibrary.open(dataRoot: root);
      addTearDown(() async {
        await library.close();
        await root.delete(recursive: true);
      });
      final item = await library.bookshelf.addFromSource(
        const BookshelfAddRequest(
          title: '测试书',
          author: '测试作者',
          kind: ContentKind.novel,
          pluginId: 'org.example.source',
          pluginVersion: '1.0.0',
          remoteContentId: 'book-1',
        ),
      );
      final reader = ContentLibrarySourceTextReader(library, _FakeGateway());

      final firstRequest = await reader.launch(item.id.value);
      expect(firstRequest.bookId, item.id.value);
      expect(await firstRequest.stateStore.loadProgress(item.id.value), isNull);
      await firstRequest.stateStore.saveProgress(
        item.id.value,
        const ReaderProgress(
          chapterId: 'chapter-2',
          paragraphId: 'chapter-2:paragraph:0',
          characterOffset: 12,
          chapterIndex: 1,
          chapterFraction: 0.4,
          bookFraction: 0.7,
        ),
      );

      final secondRequest = await reader.launch(item.id.value);
      final restored = await secondRequest.stateStore.loadProgress(
        item.id.value,
      );
      expect(restored?.chapterId, 'chapter-2');
      expect(restored?.paragraphId, 'chapter-2:paragraph:0');
      expect(restored?.bookFraction, 0.7);
      expect(
        (await secondRequest.dataSource.loadChapterContent(
          item.id.value,
          'chapter-1',
        )).paragraphs.single.text,
        '第一段。',
      );
    },
  );
}

final class _FakeGateway implements SourceContentGateway {
  @override
  Future<PluginChaptersResult> getChapters({
    required String pluginId,
    required String id,
    String? cursor,
    int pageSize = 50,
  }) async => PluginChaptersResult(
    pluginId: pluginId,
    sourceName: '示例书源',
    items: <PluginChapterSummary>[
      _chapter('chapter-1', '第一章', 0),
      _chapter('chapter-2', '第二章', 1),
    ],
    nextCursor: null,
    totalCount: 2,
  );

  @override
  Future<PluginChapterContent> getContent({
    required String pluginId,
    required String id,
    required String chapterId,
  }) async => PluginChapterContent(
    pluginId: pluginId,
    sourceName: '示例书源',
    contentKind: PluginContentKind.novel,
    chapterId: chapterId,
    title: null,
    updatedAt: null,
    text: '第一段。',
    pages: const <PluginMangaPage>[],
  );

  @override
  Future<PluginContentDetail> getDetail({
    required String pluginId,
    required String id,
  }) async => PluginContentDetail(
    pluginId: pluginId,
    sourceName: '示例书源',
    summary: PluginContentSummary(
      id: id,
      title: '测试书',
      contentKind: PluginContentKind.novel,
      author: '测试作者',
      url: null,
      coverUrl: null,
      description: '测试简介',
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
    ),
    aliases: const <String>[],
    catalogUrl: null,
  );

  @override
  Future<PluginDiscoverResult> discover({
    required String pluginId,
    String? target,
    String? cursor,
    String? collectionId,
    int pageSize = 20,
  }) => throw UnsupportedError('Not used by reader launch.');

  @override
  Future<List<PluginSourceDescriptor>> listSources() =>
      throw UnsupportedError('Not used by reader launch.');

  @override
  Future<PluginSearchResult> search({
    required String pluginId,
    required String query,
    String? cursor,
    int pageSize = 20,
  }) => throw UnsupportedError('Not used by reader launch.');
}

PluginChapterSummary _chapter(String id, String title, int order) =>
    PluginChapterSummary(
      id: id,
      title: title,
      order: order,
      url: null,
      volumeTitle: null,
      wordCount: null,
      updatedAt: null,
      isLocked: false,
      attributes: const <PluginContentAttribute>[],
    );
