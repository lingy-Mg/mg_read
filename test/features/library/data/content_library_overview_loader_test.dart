import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/library/data/content_library_overview_loader.dart';
import 'package:mg_read/features/library/domain/library_item_summary.dart';

void main() {
  test('reads persisted bookshelf items through the feature projection', () async {
    final root = await Directory.systemTemp.createTemp('mg-read-library-home-');
    final library = await ContentLibrary.open(dataRoot: root);
    addTearDown(() async {
      await library.close();
      await root.delete(recursive: true);
    });
    final item = await library.addLibraryItem(_source('persisted-book', title: '持久化书架测试'));
    await library.saveProgress(
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
    await library.addLibraryItem(_source('unread-book', title: '尚未阅读的书架测试'));

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
    final item = await library.addLibraryItem(
      BookshelfAddRequest(
        title: '首次加载封面',
        author: null,
        kind: ContentKind.novel,
        pluginId: 'test-source',
        pluginVersion: '1.0.0',
        remoteContentId: 'cover-book',
        coverUrl: Uri.parse('https://covers.example/cover.png'),
        chapterCount: 999,
        attributes: const <LibraryItemAttribute>[LibraryItemAttribute(key: 'heat', label: '热度', value: '565.2万')],
      ),
    );
    final overview = await ContentLibraryOverviewLoader(library).load();
    final summary = overview.items.single;
    expect(summary.id, item.id.value);
    expect(summary.coverBytes, isNull);
    expect(summary.coverPluginId, 'test-source');
    expect(summary.coverPluginVersion, '1.0.0');
    expect(summary.coverRemoteContentId, 'cover-book');
    expect(summary.chapterCount, 999);
    expect(summary.attributes, isEmpty, reason: 'details_json is loaded only by the long-press detail path');
    await library.close();
    await root.delete(recursive: true);
  });

  test('projects the latest progress across novel, manga, audio, and video shelf items', () async {
    final root = await Directory.systemTemp.createTemp('mg-read-library-all-progress-');
    final library = await ContentLibrary.open(dataRoot: root);
    addTearDown(() async {
      await library.close();
      await root.delete(recursive: true);
    });
    final novel = await library.addLibraryItem(_source('novel', title: '小说'));
    final manga = await library.addLibraryItem(_source('manga', title: '漫画', kind: ContentKind.manga));
    final audio = await library.addLibraryItem(_source('audio', title: '音乐', kind: ContentKind.audio));
    final video = await library.addLibraryItem(_source('video', title: '视频', kind: ContentKind.video));
    await library.saveProgress(_progress(novel.id, 1));
    await library.saveProgress(
      LibraryMangaReadingProgress(
        itemId: manga.id,
        chapterId: 'manga-chapter',
        imageId: 'image-3',
        imageFraction: 0.5,
        chapterIndex: 2,
        bookFraction: 0.4,
        updatedAtUtc: DateTime.utc(2026, 8, 24, 5),
      ),
    );
    await library.saveProgress(
      LibraryAudioPlaybackProgress(
        itemId: audio.id,
        chapterId: 'track-7',
        position: const Duration(minutes: 8),
        updatedAtUtc: DateTime.utc(2026, 8, 24, 3),
      ),
    );
    await library.saveProgress(
      LibraryVideoPlaybackProgress(
        itemId: video.id,
        groupId: 'group-2',
        episodeId: 'episode-4',
        position: const Duration(minutes: 15),
        duration: const Duration(hours: 1),
        updatedAtUtc: DateTime.utc(2026, 8, 24, 4),
      ),
    );

    final overview = await ContentLibraryOverviewLoader(library).load();
    final byKind = <ContentKind, LibraryItemSummary>{for (final item in overview.items) item.contentKind: item};

    expect(byKind[ContentKind.novel]?.readingProgress, 0.5);
    expect(byKind[ContentKind.manga]?.readingProgress, 0.4);
    expect(byKind[ContentKind.audio]?.readingProgress, isNull);
    expect(byKind[ContentKind.video]?.readingProgress, isNull);
    expect(byKind.values.every((item) => item.lastReadAtUtc != null), isTrue);
    expect(overview.continueReading?.contentKind, ContentKind.manga);
  });

  test('normal overview and continue reading exclude private books', () async {
    final root = await Directory.systemTemp.createTemp('mg-read-library-private-overview-');
    final library = await ContentLibrary.open(dataRoot: root);
    addTearDown(() async {
      await library.close();
      await root.delete(recursive: true);
    });
    final normal = await library.addLibraryItem(_source('normal', title: '普通继续阅读'));
    final private = await library.addLibraryItem(_source('private', title: '隐私继续阅读'));
    await library.saveProgress(_progress(normal.id, 1));
    await library.saveProgress(_progress(private.id, 2));
    await library.setLibraryItemVisibility(private.id, LibraryVisibility.private);

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

BookshelfAddRequest _source(String remoteBookId, {required String title, ContentKind kind = ContentKind.novel}) => BookshelfAddRequest(
  pluginId: 'test-source',
  pluginVersion: '1.0.0',
  remoteContentId: remoteBookId,
  title: title,
  author: null,
  kind: kind,
);
