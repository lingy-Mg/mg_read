import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/core/content_library/src/models.dart';
import 'package:mg_read/features/library/data/content_library_overview_loader.dart';

void main() {
  test('reads persisted bookshelf items through the feature projection', () async {
    final root = await Directory.systemTemp.createTemp('mg-read-library-home-');
    final library = await ContentLibrary.open(dataRoot: root);
    addTearDown(() async {
      await library.close();
      await root.delete(recursive: true);
    });
    final item = await library.bookshelf.add(
      title: '持久化书架测试',
      kind: ContentKind.novel,
      source: const ContentLibraryIngest(
        pluginId: 'test-source',
        producerPluginVersion: '1.0.0',
        dataVersion: 1,
        opaqueData: <String, Object?>{'remoteBookId': 'persisted-book'},
      ),
    );
    await library.readingProgress.save(
      LibraryReadingProgress(
        itemId: item.id,
        chapterId: 'chapter-1',
        paragraphId: 'chapter-1:paragraph:0',
        characterOffset: 0,
        chapterIndex: 0,
        chapterFraction: 0.2,
        bookFraction: 0.1,
        updatedAtUtc: DateTime.utc(2026, 8, 21),
      ),
    );
    await library.bookshelf.add(
      title: '尚未阅读的书架测试',
      kind: ContentKind.novel,
      source: const ContentLibraryIngest(
        pluginId: 'test-source',
        producerPluginVersion: '1.0.0',
        dataVersion: 1,
        opaqueData: <String, Object?>{'remoteBookId': 'unread-book'},
      ),
    );

    final overview = await ContentLibraryOverviewLoader(library).load();

    expect(overview.items, hasLength(2));
    final readItem = overview.items.singleWhere((summary) => summary.id == item.id.value);
    final unreadItem = overview.items.singleWhere((summary) => summary.title == '尚未阅读的书架测试');
    expect(readItem.id, isNotEmpty);
    expect(readItem.title, '持久化书架测试');
    expect(unreadItem.readingProgress, isNull);
    expect(overview.continueReading?.id, item.id.value);
    expect(overview.continueReading?.readingProgress, 0.1);
  });

  test('returns the shelf before optional cover resolution', () async {
    final root = await Directory.systemTemp.createTemp('mg-read-library-cover-');
    var library = await ContentLibrary.open(dataRoot: root);
    final item = await library.bookshelf.addFromSource(
      BookshelfAddRequest(
        title: '首次加载封面',
        author: null,
        kind: ContentKind.novel,
        pluginId: 'test-source',
        pluginVersion: '1.0.0',
        remoteContentId: 'cover-book',
        coverUrl: Uri.parse('https://covers.example/cover.png'),
      ),
    );
    final overview = await ContentLibraryOverviewLoader(library).load();
    final summary = overview.items.single;
    expect(summary.id, item.id.value);
    expect(summary.coverBytes, isNull);
    expect(summary.coverPluginId, 'test-source');
    expect(summary.coverPluginVersion, '1.0.0');
    expect(summary.coverRemoteContentId, 'cover-book');
    await library.close();
    await root.delete(recursive: true);
  });

  test('normal overview and continue reading exclude private books', () async {
    final root = await Directory.systemTemp.createTemp('mg-read-library-private-overview-');
    final library = await ContentLibrary.open(dataRoot: root);
    addTearDown(() async {
      await library.close();
      await root.delete(recursive: true);
    });
    final normal = await library.bookshelf.add(
      title: '普通继续阅读',
      kind: ContentKind.novel,
      source: const ContentLibraryIngest(
        pluginId: 'fixture',
        producerPluginVersion: '1.0.0',
        dataVersion: 1,
        opaqueData: <String, Object?>{'remoteBookId': 'normal'},
      ),
    );
    final private = await library.bookshelf.add(
      title: '隐私继续阅读',
      kind: ContentKind.novel,
      source: const ContentLibraryIngest(
        pluginId: 'fixture',
        producerPluginVersion: '1.0.0',
        dataVersion: 1,
        opaqueData: <String, Object?>{'remoteBookId': 'private'},
      ),
    );
    await library.readingProgress.save(_progress(normal.id, 1));
    await library.readingProgress.save(_progress(private.id, 2));
    await library.bookshelf.setVisibility(private.id, LibraryVisibility.private);

    final loader = ContentLibraryOverviewLoader(library);
    final normalOverview = await loader.load();
    final privateOverview = await loader.load(visibility: LibraryVisibility.private);

    expect(normalOverview.items.map((item) => item.id), <String>[normal.id.value]);
    expect(normalOverview.continueReading?.id, normal.id.value);
    expect(privateOverview.items.map((item) => item.id), <String>[private.id.value]);
  });
}

LibraryReadingProgress _progress(LibraryItemId id, int hour) => LibraryReadingProgress(
  itemId: id,
  chapterId: 'chapter-$hour',
  paragraphId: 'paragraph-$hour',
  characterOffset: 0,
  chapterIndex: 0,
  chapterFraction: 0.5,
  bookFraction: 0.5,
  updatedAtUtc: DateTime.utc(2026, 8, 24, hour),
);
