import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';

import 'package:mg_read/features/reader/data/transient_source_text_reader.dart';

void main() {
  test(
    'adapts Runtime source chapters into a route-lifetime text reader',
    () async {
      var catalogCalls = 0;
      var contentCalls = 0;
      final reader = TransientSourceTextReader(
        detail: PluginContentDetail(
          pluginId: 'org.example.source',
          sourceName: '示例书源',
          summary: _summary(),
          aliases: const <String>[],
          catalogUrl: null,
        ),
        firstCatalogPage: _chapters(
          items: <PluginChapterSummary>[_chapter('chapter-1', '第一章')],
          nextCursor: 'page-2',
          totalCount: 2,
        ),
        loadChapterPage: ({String? cursor, int pageSize = 100}) async {
          catalogCalls += 1;
          expect(cursor, 'page-2');
          return _chapters(
            items: <PluginChapterSummary>[_chapter('chapter-2', '第二章')],
            nextCursor: null,
            totalCount: 2,
          );
        },
        loadChapterContent: (String chapterId) async {
          contentCalls += 1;
          return PluginChapterContent(
            pluginId: 'org.example.source',
            sourceName: '示例书源',
            contentKind: PluginContentKind.novel,
            chapterId: chapterId,
            title: null,
            updatedAt: null,
            text: '第一段。\n\n第二段。',
            pages: const <PluginMangaPage>[],
          );
        },
      );
      final request = reader.createLaunchRequest(initialChapterId: 'chapter-1');

      expect(
        await request.stateStore.loadProgress(request.bookId),
        isA<ReaderProgress>().having(
          (ReaderProgress value) => value.chapterId,
          'chapterId',
          'chapter-1',
        ),
      );
      expect(
        (await request.dataSource.loadBookInfo(request.bookId)).title,
        '测试书',
      );
      final firstPage = await request.dataSource.loadChapterCatalog(
        request.bookId,
      );
      expect(firstPage.items.single.index, 0);
      expect(firstPage.hasMore, isTrue);

      final chapter = await request.dataSource.loadChapterContent(
        request.bookId,
        'chapter-1',
      );
      expect(chapter.title, '第一章');
      expect(chapter.paragraphs.map((paragraph) => paragraph.text), <String>[
        '第一段。',
        '第二段。',
      ]);
      expect(contentCalls, 1);

      final second = await request.dataSource.loadChapterAtIndex(
        request.bookId,
        1,
      );
      expect(second.id, 'chapter-2');
      expect(catalogCalls, 1);

      final replacement = const ReaderProgress(
        chapterId: 'chapter-2',
        paragraphId: 'chapter-2:paragraph:0',
        chapterIndex: 1,
      );
      await request.stateStore.saveProgress(request.bookId, replacement);
      expect(
        await request.stateStore.loadProgress(request.bookId),
        replacement,
      );
    },
  );
}

PluginContentSummary _summary() {
  return PluginContentSummary(
    id: 'book-1',
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
  );
}

PluginChaptersResult _chapters({
  required List<PluginChapterSummary> items,
  required String? nextCursor,
  required int totalCount,
}) {
  return PluginChaptersResult(
    pluginId: 'org.example.source',
    sourceName: '示例书源',
    items: items,
    nextCursor: nextCursor,
    totalCount: totalCount,
  );
}

PluginChapterSummary _chapter(String id, String title) {
  return PluginChapterSummary(
    id: id,
    title: title,
    order: 0,
    url: null,
    volumeTitle: null,
    wordCount: null,
    updatedAt: null,
    isLocked: false,
    attributes: const <PluginContentAttribute>[],
  );
}
