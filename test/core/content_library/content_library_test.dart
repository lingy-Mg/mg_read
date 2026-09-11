/// Content Library 五表持久化、追加目录和固定会话上界测试。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/core/persistence/persistence.dart';

void main() {
  late Directory root;
  late ContentLibrary library;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mg-read-content-library-');
    library = await ContentLibrary.open(dataRoot: root);
  });

  tearDown(() async {
    await library.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<LibraryItem> addItem({
    String remoteId = 'book-1',
    String title = '测试书',
    ContentKind kind = ContentKind.novel,
    CoverOrientation coverOrientation = CoverOrientation.portrait,
  }) => library.addLibraryItem(
    BookshelfAddRequest(
      title: title,
      author: '作者',
      kind: kind,
      pluginId: 'fixture',
      pluginVersion: '1.0.0',
      remoteContentId: remoteId,
      coverOrientation: coverOrientation,
      description: List<String>.filled(300, '文').join(),
      chapterCount: 20,
    ),
  );

  List<SourceNovelCatalogChapter> chapters(Iterable<String> ids) => <SourceNovelCatalogChapter>[
    for (final (index, id) in ids.indexed)
      SourceNovelCatalogChapter(remoteIdentity: id, title: '章节 $id', index: index, wordCount: 100 + index),
  ];

  test('metadata database contains exactly the five persistent tables', () async {
    expect(await library.persistentTableNamesForTest(), <String>[
      'bookmarks',
      'catalog_chapters',
      'library_items',
      'metadata_records',
      'reading_progress',
    ]);
  });

  test('retained item reuses catalog and body while explicit deletion cascades', () async {
    final item = await addItem();
    await library.syncNovelCatalog(itemId: item.id, chapters: chapters(<String>['chapter-0']));
    var session = (await library.openNovelReaderSession(item.id))!;
    await session.cacheChapter(entry: session.initialChapter, text: '旧正文');

    await library.removeLibraryItem(item.id, LibraryRemovalPolicy.removeFromShelfKeepContent);
    expect((await library.listLibrary(const LibraryQuery())).items, isEmpty);
    expect((await library.getLibraryItem(item.id))?.state, 'retained');

    final restored = await addItem(title: '重新加入');
    expect(restored.id.value, item.id.value);
    session = (await library.openNovelReaderSession(item.id))!;
    expect((await session.readContent(session.initialChapter) as NovelChapterContent).text, '旧正文');

    final entryId = session.initialChapter.id;
    await library.removeLibraryItem(item.id, LibraryRemovalPolicy.removeIncludingUnreferencedContent);
    expect(await library.getLibraryItem(item.id), isNull);
    expect(await library.openContent(entryId), isNull);
  });

  test('source identity is unique and concurrent re-add does not duplicate rows', () async {
    final results = await Future.wait(<Future<LibraryItem>>[addItem(), addItem(title: '并发更新')]);
    expect(results.map((item) => item.id.value).toSet(), hasLength(1));
    expect((await library.listLibrary(const LibraryQuery())).items, hasLength(1));
  });

  test('shelf projection retains square cover composition', () async {
    final item = await addItem(remoteId: 'square-cover', coverOrientation: CoverOrientation.square);

    expect(item.coverOrientation, CoverOrientation.square);
    expect((await library.loadShelfProjection()).single.coverOrientation, CoverOrientation.square);
  });

  test('source identity cannot be rebound to a different media kind', () async {
    await addItem(remoteId: 'stable-kind');
    await expectLater(addItem(remoteId: 'stable-kind', kind: ContentKind.manga), throwsA(isA<PersistenceConflictError>()));
    final items = (await library.listLibrary(const LibraryQuery())).items;
    expect(items.single.kind, ContentKind.novel);
  });

  test('bookshelf enforces the global active capacity', () async {
    for (var index = 0; index < bookshelfMaxItemCount; index++) {
      await addItem(remoteId: 'capacity-$index', title: '书 $index');
    }
    await expectLater(addItem(remoteId: 'capacity-overflow'), throwsA(isA<BookshelfCapacityExceededException>()));
  });

  test('catalog sync is append-only, idempotent, ordered, and revision-aware', () async {
    final item = await addItem();
    expect(await library.syncNovelCatalog(itemId: item.id, chapters: chapters(<String>['chapter-0'])), 1);
    expect(await library.catalogStateForTest(item.id), (count: 1, revision: 1));

    expect(
      await library.syncNovelCatalog(
        itemId: item.id,
        chapters: const <SourceNovelCatalogChapter>[
          SourceNovelCatalogChapter(remoteIdentity: 'chapter-0', title: '不得覆盖', index: 99),
          SourceNovelCatalogChapter(remoteIdentity: 'chapter-1', title: '第二章', index: 7),
        ],
      ),
      2,
    );
    final entries = await library.listAllCatalog(item.id);
    expect(entries.map((entry) => entry.title), <String>['章节 chapter-0', '第二章']);
    expect(entries.map((entry) => entry.index), <int>[0, 1]);
    expect(await library.catalogStateForTest(item.id), (count: 2, revision: 2));

    expect(await library.syncNovelCatalog(itemId: item.id, chapters: const <SourceNovelCatalogChapter>[]), 2);
    expect(await library.catalogStateForTest(item.id), (count: 2, revision: 2));
    expect(await library.syncNovelCatalog(itemId: item.id, chapters: chapters(<String>['chapter-0', 'chapter-1'])), 2);
    expect(await library.catalogStateForTest(item.id), (count: 2, revision: 2));
  });

  test('catalog rejects duplicate response identities before writing', () async {
    final item = await addItem();
    await expectLater(
      library.syncNovelCatalog(
        itemId: item.id,
        chapters: const <SourceNovelCatalogChapter>[
          SourceNovelCatalogChapter(remoteIdentity: 'same', title: '一', index: 0),
          SourceNovelCatalogChapter(remoteIdentity: 'same', title: '二', index: 1),
        ],
      ),
      throwsArgumentError,
    );
    expect(await library.catalogStateForTest(item.id), (count: 0, revision: 0));
  });

  test('catalog rejects a media kind that does not match its library item', () async {
    final manga = await addItem(remoteId: 'kind-mismatch', kind: ContentKind.manga);

    await expectLater(
      library.syncNovelCatalog(
        itemId: manga.id,
        chapters: const <SourceNovelCatalogChapter>[SourceNovelCatalogChapter(remoteIdentity: 'chapter-1', title: '第一章', index: 0)],
      ),
      throwsA(isA<StateError>()),
    );
    expect(await library.catalogStateForTest(manga.id), (count: 0, revision: 0));
  });

  test('session upper bound hides background appends until reopen', () async {
    final item = await addItem();
    await library.syncNovelCatalog(itemId: item.id, chapters: chapters(<String>['chapter-0', 'chapter-1']));
    final oldSession = (await library.openNovelReaderSession(item.id))!;
    await library.syncNovelCatalog(itemId: item.id, chapters: chapters(<String>['chapter-2', 'chapter-3']));

    expect((await oldSession.page(limit: 100)).items, hasLength(2));
    expect(await oldSession.itemAtIndex(2), isNull);
    final reopened = (await library.openNovelReaderSession(item.id))!;
    expect(reopened.catalogCount, 4);
    expect((await reopened.page(limit: 100)).items, hasLength(4));
  });

  test('overlapping concurrent appends allocate unique continuous positions', () async {
    final item = await addItem();
    await Future.wait(<Future<int>>[
      library.syncNovelCatalog(itemId: item.id, chapters: chapters(<String>['chapter-0', 'chapter-1'])),
      library.syncNovelCatalog(itemId: item.id, chapters: chapters(<String>['chapter-1', 'chapter-2'])),
    ]);
    final entries = await library.listAllCatalog(item.id);
    expect(entries.map((entry) => entry.remoteIdentity).toSet(), <String>{'chapter-0', 'chapter-1', 'chapter-2'});
    expect(entries.map((entry) => entry.index), <int>[0, 1, 2]);
    expect((await library.catalogStateForTest(item.id))!.count, 3);
  });

  test('four progress kinds share one UPSERT row and round trip strongly typed values', () async {
    final items = <ContentKind, LibraryItem>{
      for (final kind in ContentKind.values) kind: await addItem(remoteId: 'progress-${kind.code}', kind: kind),
    };
    final now = DateTime.utc(2026, 9, 5, 1, 2, 3);
    final novel = LibraryReadingProgress(
      itemId: items[ContentKind.novel]!.id,
      chapterId: 'n1',
      paragraphId: 'p1',
      characterOffset: 3,
      chapterIndex: 2,
      chapterFraction: .4,
      bookFraction: .2,
      updatedAtUtc: now,
      totalReadingSeconds: 9,
    );
    final manga = LibraryMangaReadingProgress(
      itemId: items[ContentKind.manga]!.id,
      chapterId: 'm1',
      imageId: 'i1',
      imageFraction: .5,
      chapterIndex: 4,
      bookFraction: .3,
      updatedAtUtc: now,
      readingSeconds: 10,
    );
    final audio = LibraryAudioPlaybackProgress(
      itemId: items[ContentKind.audio]!.id,
      chapterId: 'a1',
      position: const Duration(milliseconds: 1234),
      updatedAtUtc: now,
    );
    final video = LibraryVideoPlaybackProgress(
      itemId: items[ContentKind.video]!.id,
      groupId: 'g1',
      episodeId: 'e1',
      position: const Duration(milliseconds: 321),
      duration: const Duration(milliseconds: 999),
      updatedAtUtc: now,
    );
    for (final progress in <LibraryProgress>[novel, manga, audio, video]) {
      await library.saveProgress(progress);
      final restored = await library.loadProgress(progress.itemId);
      expect(restored.runtimeType, progress.runtimeType);
      expect(restored!.kind, progress.kind);
    }
    await library.saveProgress(
      LibraryReadingProgress(
        itemId: novel.itemId,
        chapterId: 'n2',
        paragraphId: 'p2',
        characterOffset: 0,
        chapterIndex: 3,
        chapterFraction: .1,
        bookFraction: .25,
        updatedAtUtc: now.add(const Duration(seconds: 1)),
      ),
    );
    expect((await library.loadProgress(novel.itemId) as LibraryReadingProgress).chapterId, 'n2');
  });

  test('progress storage rejects a media kind mismatch and invalid video time', () async {
    final novelItem = await addItem();
    await expectLater(
      library.saveProgress(
        LibraryAudioPlaybackProgress(
          itemId: novelItem.id,
          chapterId: 'audio-1',
          position: const Duration(seconds: 1),
          updatedAtUtc: DateTime.utc(2026, 9, 5),
        ),
      ),
      throwsA(isA<PersistenceNotFoundError>()),
    );
    expect(await library.loadProgress(novelItem.id), isNull);

    final videoItem = await addItem(remoteId: 'video-invalid-time', kind: ContentKind.video);
    await expectLater(
      library.saveProgress(
        LibraryVideoPlaybackProgress(
          itemId: videoItem.id,
          groupId: 'group-1',
          episodeId: 'episode-1',
          position: const Duration(seconds: 2),
          duration: const Duration(seconds: 1),
          updatedAtUtc: DateTime.utc(2026, 9, 5),
        ),
      ),
      throwsA(anything),
    );
    expect(await library.loadProgress(videoItem.id), isNull);
  });

  test('novel and manga bookmarks share one table with compatible anchors', () async {
    final item = await addItem();
    final mangaItem = await addItem(remoteId: 'manga-book', kind: ContentKind.manga);
    final now = DateTime.utc(2026, 9, 5);
    final novel = LibraryBookmark(
      id: 'bookmark-novel',
      itemId: item.id,
      chapterId: 'n1',
      paragraphId: 'p1',
      characterOffset: 2,
      chapterTitle: '第一章',
      excerpt: '摘录',
      createdAtUtc: now,
    );
    final manga = LibraryMangaBookmark(
      id: 'bookmark-manga',
      itemId: mangaItem.id,
      chapterId: 'm1',
      imageId: 'i1',
      imageFraction: .25,
      createdAtUtc: now.add(const Duration(seconds: 1)),
    );
    await library.saveBookmark(novel);
    await library.saveBookmark(manga);
    expect((await library.loadBookmarks(item.id, ContentKind.novel)).single.id, novel.id);
    expect((await library.loadBookmarks(mangaItem.id, ContentKind.manga)).single.id, manga.id);
    await library.deleteBookmark(mangaItem.id, manga.id);
    expect(await library.loadBookmarks(mangaItem.id, ContentKind.manga), isEmpty);
  });

  test('chapter refresh swaps immutable body and stale CAS leaves an orphan', () async {
    final item = await addItem();
    await library.syncNovelCatalog(itemId: item.id, chapters: chapters(<String>['chapter-0']));
    var session = (await library.openNovelReaderSession(item.id))!;
    await session.cacheChapter(entry: session.initialChapter, text: '版本一');
    session = (await library.openNovelReaderSession(item.id))!;
    final captured = session.initialChapter;
    await session.refreshChapter(entry: captured, text: '版本二');
    await expectLater(session.refreshChapter(entry: captured, text: '冲突版本'), throwsA(isA<PersistenceConflictError>()));

    final reopened = (await library.openNovelReaderSession(item.id))!;
    expect((await reopened.readContent(reopened.initialChapter) as NovelChapterContent).text, '版本二');
    expect((await library.inspectStorage()).orphanContentObjects, 2);
    expect((await library.clearStorage()).deletedContentObjects, 2);
  });

  test('shelf, session, and catalog pages use bounded query counts and target indexes', () async {
    final item = await addItem();
    await library.syncNovelCatalog(itemId: item.id, chapters: chapters(List<String>.generate(120, (index) => 'chapter-$index')));
    await library.saveProgress(
      LibraryReadingProgress(
        itemId: item.id,
        chapterId: 'chapter-50',
        paragraphId: 'p',
        characterOffset: 0,
        chapterIndex: 50,
        chapterFraction: 0,
        bookFraction: .4,
        updatedAtUtc: DateTime.utc(2026, 9, 5),
      ),
    );

    library.resetBusinessQueryCountForTest();
    expect(await library.loadShelfProjection(), hasLength(1));
    expect(library.businessQueryCountForTest, 1);

    library.resetBusinessQueryCountForTest();
    final session = (await library.openNovelReaderSession(item.id))!;
    expect(session.initialChapter.remoteIdentity, 'chapter-50');
    expect(library.businessQueryCountForTest, 1);
    expect((await session.page(limit: 100)).items, hasLength(100));
    expect(library.businessQueryCountForTest, 2);
    final cached = await session.itemsByRemoteIdentities(['chapter-50', 'chapter-51']);
    expect(cached, hasLength(2));
    expect(library.businessQueryCountForTest, 2);
    await session.cacheChapter(entry: cached['chapter-50']!, text: '缓存正文');
    expect((await session.itemByRemoteIdentity('chapter-50'))!.contentStatus, 'ready');

    final plans = await library.hotIndexPlansForTest(item.id);
    expect(plans['shelf']!.join(' '), contains('library_items_active_order'));
    expect(plans['position']!.join(' '), contains('catalog_chapters_item_position'));
    expect(plans['remote']!.join(' '), contains('catalog_chapters_item_remote'));
  });
}
