import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/core/content_library/src/content_library.dart';
import 'package:mg_read/core/content_library/src/models.dart';
import 'package:mg_read/core/persistence/persistence.dart';

void main() {
  late Directory root;
  late ContentLibrary library;
  final source = ContentLibraryIngest(
    pluginId: 'fixture',
    producerPluginVersion: '1.0.0',
    dataVersion: 1,
    opaqueData: const {'remoteBookId': 'book-1'},
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
    'persists a shelf item, catalog, and novel content across reopen',
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

  test('persists semantic reading progress and typed source identity', () async {
    final item = await library.bookshelf.add(
      title: '进度测试书',
      kind: ContentKind.novel,
      source: source,
    );
    await library.readingProgress.save(
      LibraryReadingProgress(
        itemId: item.id,
        chapterId: 'chapter-6',
        paragraphId: 'chapter-6:paragraph:3',
        characterOffset: 18,
        chapterIndex: 5,
        chapterFraction: 0.5,
        bookFraction: 0.25,
        updatedAtUtc: DateTime.utc(2026, 8, 21, 12),
      ),
    );
    await library.close();
    library = await ContentLibrary.open(dataRoot: root);

    final restored = await library.getLibraryItem(item.id);
    final progress = await library.readingProgress.load(item.id);

    expect(restored?.source?.pluginId, 'fixture');
    expect(restored?.source?.remoteContentId, 'book-1');
    expect(progress?.chapterId, 'chapter-6');
    expect(progress?.paragraphId, 'chapter-6:paragraph:3');
    expect(progress?.characterOffset, 18);
    expect(progress?.bookFraction, 0.25);
  });

  test('session-only manga resource does not retain a URL', () async {
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
    expect(
      (await library.openContent(entry.id) as MangaChapterContent)
          .pages
          .single
          .resource
          .url,
      isNull,
    );
  });

  test('manga assets are grouped and removed with the manga item', () async {
    final item = await library.bookshelf.add(
      title: '本地漫画',
      kind: ContentKind.manga,
      source: source,
    );
    final files = await FileObjectStore.open(root);
    addTearDown(files.close);
    await files.commitBytes(
      mangaId: item.id.value,
      assetId: 'asset_identifier_0001',
      bytes: [1, 2, 3],
      mimeType: 'image/png',
    );
    final directory = Directory(
      '${root.path}${Platform.pathSeparator}files${Platform.pathSeparator}content-assets${Platform.pathSeparator}${item.id.value}',
    );
    expect(await directory.exists(), isTrue);
    await library.bookshelf.remove(
      item.id,
      LibraryRemovalPolicy.removeFromShelfKeepContent,
    );
    expect(await directory.exists(), isFalse);
  });
}
