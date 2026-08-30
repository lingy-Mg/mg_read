import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';

import 'package:mg_read/features/reader/data/transient_source_text_reader.dart';

void main() {
  test('adapts Runtime source chapters into a route-lifetime text reader', () async {
    var contentCalls = 0;
    final reader = TransientSourceTextReader(
      detail: PluginContentDetail(
        pluginId: 'org.example.source',
        sourceName: '示例数据源',
        summary: _summary(),
        aliases: const <String>[],
        catalogUrl: null,
      ),
      catalog: _chapters(items: <PluginChapterSummary>[_chapter('chapter-1', '第一章'), _chapter('chapter-2', '第二章')]),
      chapterPreloadCount: 4,
      loadChapterContent: (String chapterId) async {
        contentCalls += 1;
        return PluginChapterContent(
          pluginId: 'org.example.source',
          sourceName: '示例数据源',
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

    expect(request.entryCoverBytes, <int>[1, 2, 3]);
    expect(request.chapterPreloadCount, 4);

    expect(
      await request.stateStore.loadProgress(request.bookId),
      isA<ReaderProgress>().having((ReaderProgress value) => value.chapterId, 'chapterId', 'chapter-1'),
    );
    expect((await request.dataSource.loadBookInfo(request.bookId)).title, '测试书');
    final firstPage = await request.dataSource.loadChapterCatalog(request.bookId);
    expect(firstPage.items, hasLength(2));
    expect(firstPage.items.first.index, 0);
    expect(firstPage.hasMore, isFalse);

    final chapter = await request.dataSource.loadChapterContent(request.bookId, 'chapter-1');
    expect(chapter.title, '第一章');
    expect(chapter.paragraphs.map((paragraph) => paragraph.text), <String>['第一段。', '第二段。']);
    expect(contentCalls, 1);

    final second = await request.dataSource.loadChapterAtIndex(request.bookId, 1);
    expect(second.id, 'chapter-2');

    final replacement = const ReaderProgress(chapterId: 'chapter-2', paragraphId: 'chapter-2:paragraph:0', chapterIndex: 1);
    await request.stateStore.saveProgress(request.bookId, replacement);
    expect(await request.stateStore.loadProgress(request.bookId), replacement);
  });

  test('slices the complete in-memory catalog for reader consumption', () async {
    final catalog = List<PluginChapterSummary>.generate(205, (index) => _chapter('chapter-$index', '第${index + 1}章', order: index));
    final reader = TransientSourceTextReader(
      detail: PluginContentDetail(
        pluginId: 'org.example.source',
        sourceName: '示例数据源',
        summary: _summary(),
        aliases: const <String>[],
        catalogUrl: null,
      ),
      catalog: _chapters(items: catalog),
      loadChapterContent: (_) => throw UnsupportedError('Not used.'),
    );
    final request = reader.createLaunchRequest(initialChapterId: 'chapter-0');

    final first = await request.dataSource.loadChapterCatalog(request.bookId);
    final second = await request.dataSource.loadChapterCatalog(request.bookId, cursor: first.nextCursor);
    final third = await request.dataSource.loadChapterCatalog(request.bookId, cursor: second.nextCursor);

    expect(first.items, hasLength(100));
    expect(second.items, hasLength(100));
    expect(third.items, hasLength(5));
    expect(third.items.last.id, 'chapter-204');
    expect(third.hasMore, isFalse);
  });

  test('reports a safe source location when a novel chapter request fails', () async {
    final reader = TransientSourceTextReader(
      detail: PluginContentDetail(
        pluginId: 'org.example.source',
        sourceName: '示例数据源',
        summary: _summary(),
        aliases: const <String>[],
        catalogUrl: null,
      ),
      catalog: _chapters(items: <PluginChapterSummary>[_chapter('chapter-1', '第一章')]),
      loadChapterContent: (_) => throw StateError('https://private.example/signed-url'),
    );
    final request = reader.createLaunchRequest(initialChapterId: 'chapter-1');

    await expectLater(
      request.dataSource.loadChapterContent(request.bookId, 'chapter-1'),
      throwsA(
        isA<ReaderFailure>()
            .having((failure) => failure.code, 'code', 'source_text_content_load_failed')
            .having((failure) => failure.location, 'location', '请求小说章节正文')
            .having((failure) => failure.message, 'message', '小说正文暂时无法加载，请检查数据源或网络后重试。'),
      ),
    );
  });
}

PluginContentSummary _summary() {
  return PluginContentSummary(
    id: 'book-1',
    title: '测试书',
    contentKind: PluginContentKind.novel,
    author: '测试作者',
    url: null,
    coverUrl: null,
    coverBytes: const <int>[1, 2, 3],
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

PluginChaptersResult _chapters({required List<PluginChapterSummary> items}) {
  return PluginChaptersResult(pluginId: 'org.example.source', sourceName: '示例数据源', items: items);
}

PluginChapterSummary _chapter(String id, String title, {int order = 0}) {
  return PluginChapterSummary(
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
}
