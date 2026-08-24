import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';

import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/features/discovery/application/discovery_bookshelf_saver.dart';
import 'package:mg_read/features/discovery/application/content_library_source_prefetcher.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/reader/application/reader_launch_failure.dart';
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
      final saver = ContentLibraryDiscoveryBookshelfSaver(library);
      await saver.save(
        source: PluginSourceDescriptor(
          id: 'org.example.source',
          displayName: '示例书源',
          pluginVersion: '1.0.0',
          contentKinds: const <PluginContentKind>[PluginContentKind.novel],
        ),
        content: PluginContentSummary(
          id: 'book-1',
          title: '测试书',
          contentKind: PluginContentKind.novel,
          author: '测试作者',
          url: null,
          coverUrl: null,
          description: null,
          language: null,
          status: PluginContentStatus.ongoing,
          access: PluginAccessKind.unknown,
          wordCount: null,
          chapterCount: 2,
          publishedAt: null,
          updatedAt: null,
          latestChapter: null,
          categories: const <String>[],
          tags: const <String>[],
          attributes: const <PluginContentAttribute>[],
        ),
      );
      final item = (await library.listLibrary(
        const LibraryQuery(),
      )).items.single;
      final gateway = _FakeGateway();
      final reader = ContentLibrarySourceTextReader(library, gateway);

      final firstRequest = await reader.launch(item.id.value);
      expect(firstRequest.bookId, item.id.value);
      expect(gateway.requestedCatalogCount, 1);
      expect(gateway.requestedDetailCount, 1);
      expect(firstRequest.extensions.chapterStateCapability, isNotNull);
      expect(await library.listAllCatalog(item.id), hasLength(2));
      expect(
        (await firstRequest.dataSource.loadChapterContent(
          item.id.value,
          'chapter-1',
        )).paragraphs.single.text,
        '第一段。',
      );
      expect(gateway.requestedContentChapterIds, <String>['chapter-1']);
      expect(
        (await library.listAllCatalog(item.id)).first.contentStatus,
        'ready',
      );
      final hydrated = await library.getLibraryItem(item.id);
      expect(hydrated?.revision, greaterThan(item.revision));
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
      expect(gateway.requestedCatalogCount, 1);
      expect(gateway.requestedDetailCount, 2);
      expect(gateway.requestedContentChapterIds, <String>['chapter-1']);
    },
  );

  test(
    'reports the source stage and safe code when catalog loading fails',
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

      await expectLater(
        ContentLibrarySourceTextReader(
          library,
          _CatalogFailureGateway(),
        ).launch(item.id.value),
        throwsA(
          isA<ReaderLaunchFailure>()
              .having(
                (failure) => failure.reason,
                'reason',
                ReaderLaunchFailureReason.sourceCatalog,
              )
              .having(
                (failure) => failure.diagnosticCode,
                'diagnosticCode',
                'reader_launch_source_catalog_timeout',
              ),
        ),
      );
    },
  );

  test('keeps source chapter IDs that contain a colon readable', () async {
    final root = await Directory.systemTemp.createTemp('mg-read-reader-');
    final library = await ContentLibrary.open(dataRoot: root);
    addTearDown(() async {
      await library.close();
      await root.delete(recursive: true);
    });
    final item = await library.bookshelf.addFromSource(
      const BookshelfAddRequest(
        title: '复合章节 ID',
        author: null,
        kind: ContentKind.novel,
        pluginId: 'org.example.source',
        pluginVersion: '1.0.0',
        remoteContentId: 'book-colon-id',
      ),
    );
    final reader = ContentLibrarySourceTextReader(
      library,
      _ColonChapterGateway(),
    );

    final request = await reader.launch(item.id.value);
    final content = await request.dataSource.loadChapterContent(
      item.id.value,
      'chapter:1',
    );

    expect(content.paragraphs.single.text, '带冒号 ID 的首章。');
    expect(
      (await library.listAllCatalog(item.id)).first.remoteIdentity,
      'chapter:1',
    );
  });

  test(
    'waits for the shared prefetch instead of requesting the catalog twice',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'mg-read-reader-prefetch-',
      );
      final library = await ContentLibrary.open(dataRoot: root);
      addTearDown(() async {
        await library.close();
        await root.delete(recursive: true);
      });
      final item = await library.bookshelf.addFromSource(
        const BookshelfAddRequest(
          title: '共享预取',
          author: null,
          kind: ContentKind.novel,
          pluginId: 'org.example.source',
          pluginVersion: '1.0.0',
          remoteContentId: 'book-shared-prefetch',
        ),
      );
      final gateway = _GatedCatalogGateway();
      final prefetcher = ContentLibrarySourcePrefetcher(library, gateway);
      final reader = ContentLibrarySourceTextReader(
        library,
        gateway,
        prefetcher,
      );

      prefetcher.start(item);
      await gateway.catalogRequested.future;
      final launch = reader.launch(item.id.value);
      await Future<void>.delayed(Duration.zero);

      expect(gateway.requestedCatalogCount, 1);
      expect(await library.listAllCatalog(item.id), isEmpty);

      gateway.releaseCatalog();
      final request = await launch;

      expect(request.bookId, item.id.value);
      expect(gateway.requestedCatalogCount, 1);
      expect(await library.listAllCatalog(item.id), hasLength(2));
    },
  );

  test(
    'retries once in the reader after a background catalog failure',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'mg-read-reader-retry-',
      );
      final library = await ContentLibrary.open(dataRoot: root);
      addTearDown(() async {
        await library.close();
        await root.delete(recursive: true);
      });
      final item = await library.bookshelf.addFromSource(
        const BookshelfAddRequest(
          title: '失败重试',
          author: null,
          kind: ContentKind.novel,
          pluginId: 'org.example.source',
          pluginVersion: '1.0.0',
          remoteContentId: 'book-prefetch-retry',
        ),
      );
      final gateway = _FailOnceCatalogGateway();
      final prefetcher = ContentLibrarySourcePrefetcher(library, gateway);
      final reader = ContentLibrarySourceTextReader(
        library,
        gateway,
        prefetcher,
      );

      prefetcher.start(item);
      await prefetcher.waitFor(item.id.value);
      final request = await reader.launch(item.id.value);

      expect(request.bookId, item.id.value);
      expect(gateway.requestedCatalogCount, 2);
      expect(await library.listAllCatalog(item.id), hasLength(2));
    },
  );

  test(
    'replaces an old partial catalog when remote detail reports more chapters',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'mg-read-reader-repair-',
      );
      final library = await ContentLibrary.open(dataRoot: root);
      addTearDown(() async {
        await library.close();
        await root.delete(recursive: true);
      });
      final item = await library.bookshelf.addFromSource(
        const BookshelfAddRequest(
          title: '半目录修复',
          author: null,
          kind: ContentKind.novel,
          pluginId: 'org.example.source',
          pluginVersion: '1.0.0',
          remoteContentId: 'book-partial-repair',
        ),
      );
      await library.syncNovelCatalog(
        itemId: item.id,
        chapters: const <SourceNovelCatalogChapter>[
          SourceNovelCatalogChapter(
            remoteIdentity: 'chapter-1',
            title: '第一章',
            index: 0,
          ),
        ],
      );
      final gateway = _FakeGateway();

      final request = await ContentLibrarySourceTextReader(
        library,
        gateway,
      ).launch(item.id.value);

      expect(request.bookId, item.id.value);
      expect(gateway.requestedCatalogCount, 1);
      expect(await library.listAllCatalog(item.id), hasLength(2));
    },
  );
}

final class _CatalogFailureGateway extends _FakeGateway {
  @override
  Future<PluginChaptersResult> getChapters({
    required String pluginId,
    required String id,
  }) => Future<PluginChaptersResult>.error(
    AppError.fromCode(AppErrorCode.timeout),
  );
}

final class _ColonChapterGateway extends _FakeGateway {
  @override
  Future<PluginChaptersResult> getChapters({
    required String pluginId,
    required String id,
  }) async => PluginChaptersResult(
    pluginId: pluginId,
    sourceName: '示例书源',
    items: <PluginChapterSummary>[
      _chapter('chapter:1', '第一章', 0),
      _chapter('chapter:https://2', '第二章', 1),
    ],
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
    title: '第一章',
    updatedAt: null,
    text: '带冒号 ID 的首章。',
    pages: const <PluginMangaPage>[],
  );
}

final class _GatedCatalogGateway extends _FakeGateway {
  final catalogRequested = Completer<void>();
  final _catalogRelease = Completer<void>();

  void releaseCatalog() => _catalogRelease.complete();

  @override
  Future<PluginChaptersResult> getChapters({
    required String pluginId,
    required String id,
  }) async {
    requestedCatalogCount += 1;
    if (!catalogRequested.isCompleted) catalogRequested.complete();
    await _catalogRelease.future;
    return PluginChaptersResult(
      pluginId: pluginId,
      sourceName: '示例书源',
      items: <PluginChapterSummary>[
        _chapter('chapter-1', '第一章', 0),
        _chapter('chapter-2', '第二章', 1),
      ],
    );
  }
}

final class _FailOnceCatalogGateway extends _FakeGateway {
  @override
  Future<PluginChaptersResult> getChapters({
    required String pluginId,
    required String id,
  }) {
    requestedCatalogCount += 1;
    if (requestedCatalogCount == 1) {
      return Future<PluginChaptersResult>.error(
        AppError.fromCode(AppErrorCode.timeout),
      );
    }
    return Future<PluginChaptersResult>.value(
      PluginChaptersResult(
        pluginId: pluginId,
        sourceName: '示例书源',
        items: <PluginChapterSummary>[
          _chapter('chapter-1', '第一章', 0),
          _chapter('chapter-2', '第二章', 1),
        ],
      ),
    );
  }
}

final class _FakeGateway implements SourceContentGateway {
  var requestedCatalogCount = 0;
  final requestedContentChapterIds = <String>[];
  var requestedDetailCount = 0;

  @override
  Future<PluginChaptersResult> getChapters({
    required String pluginId,
    required String id,
  }) async {
    requestedCatalogCount += 1;
    return PluginChaptersResult(
      pluginId: pluginId,
      sourceName: '示例书源',
      items: <PluginChapterSummary>[
        _chapter('chapter-1', '第一章', 0, wordCount: 1234),
        _chapter('chapter-2', '第二章', 1),
      ],
    );
  }

  @override
  Future<PluginChapterContent> getContent({
    required String pluginId,
    required String id,
    required String chapterId,
  }) async {
    requestedContentChapterIds.add(chapterId);
    return PluginChapterContent(
      pluginId: pluginId,
      sourceName: '示例书源',
      contentKind: PluginContentKind.novel,
      chapterId: chapterId,
      title: null,
      updatedAt: null,
      text: '第一段。',
      pages: const <PluginMangaPage>[],
    );
  }

  @override
  Future<PluginContentDetail> getDetail({
    required String pluginId,
    required String id,
  }) async {
    requestedDetailCount += 1;
    return PluginContentDetail(
      pluginId: pluginId,
      sourceName: '示例书源',
      summary: PluginContentSummary(
        id: id,
        title: '测试书',
        contentKind: PluginContentKind.novel,
        author: '测试作者',
        url: Uri.parse('https://source.example/books/book-1'),
        coverUrl: Uri.parse('https://cdn.example.com/book.jpg'),
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
  }

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

  @override
  Future<PluginSearchSuggestionsResult> searchSuggestions({
    required String pluginId,
    String? cursor,
    int pageSize = 20,
  }) => throw UnsupportedError('Not used by reader launch.');
}

PluginChapterSummary _chapter(
  String id,
  String title,
  int order, {
  int? wordCount,
}) => PluginChapterSummary(
  id: id,
  title: title,
  order: order,
  url: null,
  volumeTitle: null,
  wordCount: wordCount,
  updatedAt: null,
  isLocked: false,
  attributes: const <PluginContentAttribute>[],
);
