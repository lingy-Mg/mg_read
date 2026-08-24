import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/features/discovery/application/content_library_source_prefetcher.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';

import '../../../core/diagnostics/diagnostics_testkit.dart';

void main() {
  test(
    'prefetches detail, the complete catalog, and the first chapter',
    () async {
      final root = await Directory.systemTemp.createTemp('mg-read-prefetch-');
      final library = await ContentLibrary.open(dataRoot: root);
      addTearDown(() async {
        await library.close();
        await root.delete(recursive: true);
      });
      final item = await library.bookshelf.addFromSource(
        const BookshelfAddRequest(
          title: '预取测试书',
          author: '作者',
          kind: ContentKind.novel,
          pluginId: 'org.example.source',
          pluginVersion: '1.0.0',
          remoteContentId: 'book-prefetch',
        ),
      );
      final gateway = _PrefetchGateway();
      final prefetcher = ContentLibrarySourcePrefetcher(library, gateway);

      prefetcher.start(item);
      await prefetcher.waitFor(item.id.value);

      final catalog = await library.listAllCatalog(item.id);
      expect(catalog.map((entry) => entry.remoteIdentity), <String>[
        'chapter:1',
        'chapter:2',
      ]);
      expect(catalog.first.contentStatus, 'ready');
      expect(
        await library.openContent(catalog.first.id),
        isA<NovelChapterContent>(),
      );
      expect(gateway.detailCalls, 1);
      expect(gateway.catalogCalls, 1);
      expect(gateway.contentChapterIds, <String>['chapter:1']);
    },
  );

  test(
    'deduplicates concurrent prefetch and never exposes a half catalog',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'mg-read-prefetch-dedupe-',
      );
      final library = await ContentLibrary.open(dataRoot: root);
      addTearDown(() async {
        await library.close();
        await root.delete(recursive: true);
      });
      final item = await library.bookshelf.addFromSource(
        const BookshelfAddRequest(
          title: '并发预取测试书',
          author: null,
          kind: ContentKind.novel,
          pluginId: 'org.example.source',
          pluginVersion: '1.0.0',
          remoteContentId: 'book-deduplicated',
        ),
      );
      final gateway = _GatedPrefetchGateway();
      final diagnostics = DiagnosticsTestkit();
      addTearDown(diagnostics.dispose);
      final prefetcher = ContentLibrarySourcePrefetcher(
        library,
        gateway,
        diagnostics: diagnostics.manager,
      );

      prefetcher.start(item);
      prefetcher.start(item);
      await gateway.catalogRequested.future;

      expect(gateway.catalogCalls, 1);
      expect(await library.listAllCatalog(item.id), isEmpty);

      gateway.releaseCatalog();
      await prefetcher.waitFor(item.id.value);

      expect(await library.listAllCatalog(item.id), hasLength(2));
      expect(gateway.catalogCalls, 1);
      final events = diagnostics.sink.events
          .where((event) => event.eventName.startsWith('reader.prefetch.'))
          .toList(growable: false);
      expect(
        events.where((event) => event.phase == DiagnosticPhase.start),
        hasLength(1),
      );
      expect(
        events.where((event) => event.phase == DiagnosticPhase.terminal),
        hasLength(1),
      );
      expect(
        jsonEncode(events.map(const DiagnosticEventCodec().encode).toList()),
        isNot(contains('并发预取测试书')),
      );
    },
  );

  test(
    'splits a catalog snapshot larger than one metadata write batch',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'mg-read-prefetch-large-',
      );
      final library = await ContentLibrary.open(dataRoot: root);
      addTearDown(() async {
        await library.close();
        await root.delete(recursive: true);
      });
      final item = await library.bookshelf.addFromSource(
        const BookshelfAddRequest(
          title: '大目录测试书',
          author: null,
          kind: ContentKind.novel,
          pluginId: 'org.example.source',
          pluginVersion: '1.0.0',
          remoteContentId: 'book-large-catalog',
        ),
      );
      final chapters = List<SourceNovelCatalogChapter>.generate(
        166,
        (index) => SourceNovelCatalogChapter(
          remoteIdentity: 'chapter:$index',
          title: '第${index + 1}章',
          index: index,
        ),
      );

      final catalog = await library.syncNovelCatalog(
        itemId: item.id,
        chapters: chapters,
      );

      expect(catalog, hasLength(166));
      expect(catalog.first.remoteIdentity, 'chapter:0');
      expect(catalog.last.remoteIdentity, 'chapter:165');
    },
  );
}

final class _PrefetchGateway implements SourceContentGateway {
  var detailCalls = 0;
  var catalogCalls = 0;
  final contentChapterIds = <String>[];

  @override
  Future<PluginContentDetail> getDetail({
    required String pluginId,
    required String id,
  }) async {
    detailCalls += 1;
    return PluginContentDetail(
      pluginId: pluginId,
      sourceName: '预取书源',
      summary: PluginContentSummary(
        id: id,
        title: '远程详情书名',
        contentKind: PluginContentKind.novel,
        author: '远程作者',
        url: null,
        coverUrl: null,
        description: '简介',
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
  }

  @override
  Future<PluginChaptersResult> getChapters({
    required String pluginId,
    required String id,
  }) async {
    catalogCalls += 1;
    return PluginChaptersResult(
      pluginId: pluginId,
      sourceName: '预取书源',
      items: <PluginChapterSummary>[
        _chapter('chapter:1', '第一章', 0),
        _chapter('chapter:2', '第二章', 1),
      ],
    );
  }

  @override
  Future<PluginChapterContent> getContent({
    required String pluginId,
    required String id,
    required String chapterId,
  }) async {
    contentChapterIds.add(chapterId);
    return PluginChapterContent(
      pluginId: pluginId,
      sourceName: '预取书源',
      contentKind: PluginContentKind.novel,
      chapterId: chapterId,
      title: '第一章',
      updatedAt: null,
      text: '预取正文。',
      pages: const <PluginMangaPage>[],
    );
  }

  @override
  Future<List<PluginSourceDescriptor>> listSources() =>
      throw UnsupportedError('Not used.');

  @override
  Future<PluginSearchResult> search({
    required String pluginId,
    required String query,
    String? cursor,
    int pageSize = 20,
  }) => throw UnsupportedError('Not used.');

  @override
  Future<PluginSearchSuggestionsResult> searchSuggestions({
    required String pluginId,
    String? cursor,
    int pageSize = 20,
  }) => throw UnsupportedError('Not used.');

  @override
  Future<PluginDiscoverResult> discover({
    required String pluginId,
    String? target,
    String? cursor,
    String? collectionId,
    int pageSize = 20,
  }) => throw UnsupportedError('Not used.');
}

final class _GatedPrefetchGateway extends _PrefetchGateway {
  final catalogRequested = Completer<void>();
  final _catalogRelease = Completer<void>();

  void releaseCatalog() => _catalogRelease.complete();

  @override
  Future<PluginChaptersResult> getChapters({
    required String pluginId,
    required String id,
  }) async {
    catalogCalls += 1;
    if (!catalogRequested.isCompleted) catalogRequested.complete();
    await _catalogRelease.future;
    return PluginChaptersResult(
      pluginId: pluginId,
      sourceName: '预取书源',
      items: <PluginChapterSummary>[
        _chapter('chapter:1', '第一章', 0),
        _chapter('chapter:2', '第二章', 1),
      ],
    );
  }
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
