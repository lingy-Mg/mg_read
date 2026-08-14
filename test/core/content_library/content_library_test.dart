import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/core/content_library/src/content_library.dart';
import 'package:mg_read/core/content_library/src/models.dart';

void main() {
  late Directory root;
  late ContentLibrary library;
  final source = ContentLibraryIngest(
    pluginId: 'fixture',
    producerPluginVersion: '1.0.0',
    dataVersion: 1,
    opaqueData: const {'remoteBookId': 'book-1', 'unknown': null},
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mg-read-content-library-');
    library = await ContentLibrary.open(dataRoot: root);
  });
  tearDown(() async {
    await library.close();
    await root.delete(recursive: true);
  });

  test(
    'persists a shelf item and immutable novel content across reopen',
    () async {
      final item = await library.bookshelf.add(
        title: '测试书',
        kind: ContentKind.novel,
        source: source,
      );
      await library.catalog.replaceSnapshot(
        itemId: item.id,
        bindingId: const SourceBindingId('binding-1'),
        entries: [
          IngestCatalogEntry(
            remoteIdentity: 'chapter-1',
            title: '第一章',
            orderKey: '000001',
            kindCode: 'novel',
            source: source,
          ),
        ],
      );
      final entry = (await library.listCatalog(
        item.id,
        const CatalogQuery(),
      )).items.single;
      await library.content.putNovel(
        entryId: entry.id,
        text: '正文',
        source: source,
      );
      expect((await library.openContent(entry.id)), isA<NovelChapterContent>());
      await library.close();
      library = await ContentLibrary.open(dataRoot: root);
      expect(
        (await library.listLibrary(const LibraryQuery())).items.single.title,
        '测试书',
      );
      expect(
        (await library.openContent(entry.id) as NovelChapterContent).text,
        '正文',
      );
    },
  );

  test('keyset pagination has a stable tail at 3000 entries', () async {
    final item = await library.bookshelf.add(
      title: '边界书',
      kind: ContentKind.novel,
      source: source,
    );
    final entries = List.generate(
      3000,
      (i) => IngestCatalogEntry(
        remoteIdentity: '$i',
        title: '$i',
        orderKey: i.toString().padLeft(6, '0'),
        kindCode: 'novel',
        source: source,
      ),
    );
    await library.catalog.replaceSnapshot(
      itemId: item.id,
      bindingId: const SourceBindingId('binding-2'),
      entries: entries,
    );
    String? cursor;
    var count = 0;
    do {
      final page = await library.listCatalog(
        item.id,
        CatalogQuery(after: cursor, limit: 137),
      );
      count += page.items.length;
      cursor = page.nextCursor;
    } while (cursor != null);
    expect(count, 3000);
  });

  test('session-only manga resource never serializes a URL', () async {
    final item = await library.bookshelf.add(
      title: '漫画',
      kind: ContentKind.manga,
      source: source,
    );
    await library.catalog.replaceSnapshot(
      itemId: item.id,
      bindingId: const SourceBindingId('binding-3'),
      entries: [
        IngestCatalogEntry(
          remoteIdentity: 'c',
          title: 'c',
          orderKey: '1',
          kindCode: 'manga',
          source: source,
        ),
      ],
    );
    final entry = (await library.listCatalog(
      item.id,
      const CatalogQuery(),
    )).items.single;
    await library.content.putManga(
      entryId: entry.id,
      pages: [
        IngestMangaPage(
          pageId: 'page-1',
          order: 0,
          resource: SourceResource.sessionOnly(),
          source: source,
        ),
      ],
      source: source,
    );
    final result = await library.openContent(entry.id) as MangaChapterContent;
    expect(result.pages.single.resource.url, isNull);
  });
}
