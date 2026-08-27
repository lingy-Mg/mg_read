/// Content Library 的持久化与边界测试。
///
/// 职责：
/// - 验证书架、目录、正文、封面与阅读进度的应用自有持久化语义。
/// - 覆盖全局封面缓存的 LRU 上限与路径隔离。
///
/// 注意：
/// - 每个用例使用独立临时目录，不能依赖真实应用数据或网络。
/// - 文件对象测试只经公开仓储 API，不暴露生产路径。
///
/// TODO:
/// - 无。
library;

import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/core/content_library/src/content_library.dart';
import 'package:mg_read/core/content_library/src/models.dart';
import 'package:mg_read/core/persistence/persistence.dart';

import '../diagnostics/diagnostics_testkit.dart';

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

  test('persists a shelf item, catalog, and novel content across reopen', () async {
    final item = await library.bookshelf.add(title: '测试书', kind: ContentKind.novel, source: source);
    await library.catalog.replaceSnapshot(
      itemId: item.id,
      bindingId: const SourceBindingId('binding-1'),
      entries: [IngestCatalogEntry(remoteIdentity: 'chapter-1', title: '第一章', orderKey: '000001', kindCode: 'novel', source: source)],
    );
    final entry = (await library.listCatalog(item.id, const CatalogQuery())).items.single;
    await library.content.putNovel(entryId: entry.id, text: '正文', source: source);
    await library.close();
    library = await ContentLibrary.open(dataRoot: root);
    expect((await library.listLibrary(const LibraryQuery())).items.single.title, '测试书');
    expect((await library.openContent(entry.id) as NovelChapterContent).text, '正文');
  });

  test('persists semantic reading progress and typed source identity', () async {
    final item = await library.bookshelf.add(title: '进度测试书', kind: ContentKind.novel, source: source);
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
        totalReadingSeconds: 3723,
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
    expect(progress?.totalReadingSeconds, 3723);
  });

  test('content metadata inlines bounded writes but keeps catalog-sized batches in a worker', () async {
    final registry = RecordDocumentRegistry(contentLibraryRecordDocumentCodecs);
    final progressCodec = registry.require('content_library_reading_progress', 'content_library');
    final inline = await progressCodec.prepareCurrent(const <String, Object?>{
      'chapterId': 'chapter-1',
      'paragraphId': 'paragraph-1',
      'characterOffset': 0,
      'chapterIndex': 0,
      'chapterFraction': 0.0,
      'bookFraction': 0.0,
      'updatedAtUtc': '2026-08-27T00:00:00.000Z',
      'totalReadingSeconds': 0,
    });
    expect(inline.executionIsolateId, Isolate.current.hashCode);

    final catalog = await registry.prepareCurrentMany(
      documents: List.generate(
        9,
        (index) =>
            (recordKind: 'content_catalog_entry', scopeKind: 'content_library', document: <String, Object?>{'title': 'chapter-$index'}),
      ),
    );
    expect(catalog.map((document) => document.executionIsolateId).toSet(), hasLength(1));
    expect(catalog.first.executionIsolateId, isNot(Isolate.current.hashCode));
  });

  test('persists and removes a bookshelf cover outside metadata', () async {
    final item = await library.bookshelf.addFromSource(
      BookshelfAddRequest(
        title: '封面测试书',
        author: null,
        kind: ContentKind.novel,
        pluginId: 'fixture',
        pluginVersion: '1.0.0',
        remoteContentId: 'cover-book',
        coverUrl: Uri.parse('https://covers.example/cover-book.png'),
      ),
    );
    final bytes = <int>[137, 80, 78, 71, 1, 2, 3];

    await library.bookshelf.saveCover(id: item.id, bytes: bytes, mimeType: 'image/png');
    expect(await library.bookshelf.readCover(item.id), bytes);

    await library.close();
    library = await ContentLibrary.open(dataRoot: root);
    expect(await library.bookshelf.readCover(item.id), bytes);

    await library.bookshelf.remove(item.id, LibraryRemovalPolicy.removeFromShelfKeepContent);
    expect(await library.bookshelf.readCover(item.id), isNull);
  });

  test('keeps global covers within the byte cap using least-recently-used eviction', () async {
    final fileRoot = await Directory.systemTemp.createTemp('mg-read-global-cover-files-');
    final files = await FileObjectStore.open(fileRoot);
    addTearDown(() async {
      await files.close();
      await fileRoot.delete(recursive: true);
    });
    final first = '1'.padLeft(64, '0');
    final second = '2'.padLeft(64, '0');
    final third = '3'.padLeft(64, '0');

    await files.commitGlobalCoverBytes(coverKey: first, bytes: const <int>[1, 1, 1, 1], mimeType: 'image/png', maxBytes: 8);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await files.commitGlobalCoverBytes(coverKey: second, bytes: const <int>[2, 2, 2, 2], mimeType: 'image/png', maxBytes: 8);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(await files.readGlobalCoverBytes(first), <int>[1, 1, 1, 1]);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await files.commitGlobalCoverBytes(coverKey: third, bytes: const <int>[3, 3, 3, 3], mimeType: 'image/png', maxBytes: 8);

    expect(await files.readGlobalCoverBytes(second), isNull);
    expect(await files.readGlobalCoverBytes(first), <int>[1, 1, 1, 1]);
    expect(await files.readGlobalCoverBytes(third), <int>[3, 3, 3, 3]);
  });

  test('saves a global cover without a separate pruning persistence operation', () async {
    final diagnostics = DiagnosticsTestkit();
    addTearDown(diagnostics.dispose);
    await library.close();
    library = await ContentLibrary.open(dataRoot: root, diagnostics: diagnostics.manager);

    await library.covers.save(
      key: CoverKey(
        pluginId: 'fixture',
        pluginVersion: '1.0.0',
        remoteContentId: 'diagnostic-cover',
        coverUrl: Uri.parse('https://covers.example/diagnostic-cover.png'),
      ),
      bytes: const <int>[1, 2, 3, 4],
      mimeType: 'image/png',
    );

    expect(diagnostics.sink.events.where((event) => event.eventName.startsWith('persistence.operation.')), hasLength(2));
  });

  test('persists privacy visibility without changing progress or content', () async {
    final normal = await library.bookshelf.add(
      title: '普通书籍',
      kind: ContentKind.novel,
      source: const ContentLibraryIngest(
        pluginId: 'fixture',
        producerPluginVersion: '1.0.0',
        dataVersion: 1,
        opaqueData: <String, Object?>{'remoteBookId': 'normal-book'},
      ),
    );
    final private = await library.bookshelf.add(
      title: '隐私书籍',
      kind: ContentKind.novel,
      source: const ContentLibraryIngest(
        pluginId: 'fixture',
        producerPluginVersion: '1.0.0',
        dataVersion: 1,
        opaqueData: <String, Object?>{'remoteBookId': 'private-book'},
      ),
    );
    final progress = LibraryReadingProgress(
      itemId: private.id,
      chapterId: 'chapter-1',
      paragraphId: 'paragraph-1',
      characterOffset: 3,
      chapterIndex: 0,
      chapterFraction: 0.5,
      bookFraction: 0.25,
      updatedAtUtc: DateTime.utc(2026, 8, 24),
    );
    await library.readingProgress.save(progress);

    await library.bookshelf.setVisibility(private.id, LibraryVisibility.private);
    await library.close();
    library = await ContentLibrary.open(dataRoot: root);

    expect(
      (await library.listLibrary(const LibraryQuery(visibility: LibraryVisibility.normal))).items.map((item) => item.id.value),
      <String>[normal.id.value],
    );
    expect(
      (await library.listLibrary(const LibraryQuery(visibility: LibraryVisibility.private))).items.single.visibility,
      LibraryVisibility.private,
    );
    expect((await library.readingProgress.load(private.id))?.bookFraction, progress.bookFraction);

    await library.bookshelf.setVisibility(private.id, LibraryVisibility.normal);
    expect(
      (await library.listLibrary(const LibraryQuery(visibility: LibraryVisibility.normal))).items.map((item) => item.id.value).toSet(),
      <String>{normal.id.value, private.id.value},
    );
  });

  test('concurrent source saves are idempotent and atomically bound', () async {
    final items = await Future.wait<LibraryItem>([
      library.bookshelf.add(title: '并发加入', kind: ContentKind.novel, source: source),
      library.bookshelf.add(title: '并发加入', kind: ContentKind.novel, source: source),
    ]);

    expect(items.map((item) => item.id.value).toSet(), hasLength(1));
    expect((await library.listLibrary(const LibraryQuery())).items, hasLength(1));
    expect(items.first.source?.remoteContentId, 'book-1');
  });

  test('batch reads unique progress records and omits unread shelf items', () async {
    final first = await library.bookshelf.add(
      title: '批量进度一',
      kind: ContentKind.novel,
      source: const ContentLibraryIngest(
        pluginId: 'fixture',
        producerPluginVersion: '1.0.0',
        dataVersion: 1,
        opaqueData: <String, Object?>{'remoteBookId': 'batch-one'},
      ),
    );
    final unread = await library.bookshelf.add(
      title: '批量进度二',
      kind: ContentKind.novel,
      source: const ContentLibraryIngest(
        pluginId: 'fixture',
        producerPluginVersion: '1.0.0',
        dataVersion: 1,
        opaqueData: <String, Object?>{'remoteBookId': 'batch-two'},
      ),
    );
    await library.readingProgress.save(
      LibraryReadingProgress(
        itemId: first.id,
        chapterId: 'chapter-1',
        paragraphId: 'chapter-1:paragraph:0',
        characterOffset: 0,
        chapterIndex: 0,
        chapterFraction: 0.25,
        bookFraction: 0.15,
        updatedAtUtc: DateTime.utc(2026, 8, 22),
      ),
    );

    final progress = await library.readingProgress.loadMany([first.id, unread.id, first.id]);

    expect(progress, hasLength(1));
    expect(progress.single.itemId.value, first.id.value);
    expect(progress.single.bookFraction, 0.15);
    expect(await library.readingProgress.loadMany(const <LibraryItemId>[]), isEmpty);
  });

  test('session-only manga resource does not retain a URL', () async {
    final item = await library.bookshelf.add(title: '漫画', kind: ContentKind.manga, source: source);
    await library.catalog.replaceSnapshot(
      itemId: item.id,
      bindingId: const SourceBindingId('binding-3'),
      entries: [IngestCatalogEntry(remoteIdentity: 'c', title: 'c', orderKey: '1', kindCode: 'manga', source: source)],
    );
    final entry = (await library.listCatalog(item.id, const CatalogQuery())).items.single;
    await library.content.putManga(
      entryId: entry.id,
      pages: [IngestMangaPage(pageId: 'page-1', order: 0, resource: SourceResource.sessionOnly(), source: source)],
      source: source,
    );
    expect((await library.openContent(entry.id) as MangaChapterContent).pages.single.resource.url, isNull);
  });

  test('manga assets are grouped and removed with the manga item', () async {
    final item = await library.bookshelf.add(title: '本地漫画', kind: ContentKind.manga, source: source);
    final files = await FileObjectStore.open(root);
    addTearDown(files.close);
    await files.commitBytes(mangaId: item.id.value, assetId: 'asset_identifier_0001', bytes: [1, 2, 3], mimeType: 'image/png');
    final directory = Directory(
      '${root.path}${Platform.pathSeparator}files${Platform.pathSeparator}content-assets${Platform.pathSeparator}${item.id.value}',
    );
    expect(await directory.exists(), isTrue);
    await library.bookshelf.remove(item.id, LibraryRemovalPolicy.removeFromShelfKeepContent);
    expect(await directory.exists(), isFalse);
  });

  test('opens a bounded novel session with targeted chapter queries', () async {
    final item = await library.bookshelf.add(title: '会话书', kind: ContentKind.novel, source: source);
    await library.catalog.ensureNovelCatalog(
      itemId: item.id,
      chapters: const [
        SourceNovelCatalogChapter(remoteIdentity: 'one', title: '一', index: 0),
        SourceNovelCatalogChapter(remoteIdentity: 'two', title: '二', index: 1),
      ],
    );
    final session = await library.openNovelReaderSession(item.id);
    expect(session, isNotNull);
    expect(session!.catalogCount, 2);
    expect((await session.itemAtIndex(1))!.remoteIdentity, 'two');
    expect((await session.itemByRemoteIdentity('one'))!.index, 0);
    expect(
      (await session.itemsByRemoteIdentities(const <String>['two', 'missing', 'one'])).keys,
      containsAllInOrder(const <String>['one', 'two']),
    );
    expect((await session.page(limit: 1)).items, hasLength(1));

    final progress = LibraryReadingProgress(
      itemId: item.id,
      chapterId: 'removed',
      paragraphId: 'p',
      characterOffset: 0,
      chapterIndex: 1,
      chapterFraction: 0,
      bookFraction: 0.5,
      updatedAtUtc: DateTime.utc(2026, 8, 24),
    );
    await session.saveProgress(progress);
    await library.catalog.syncNovelCatalog(
      itemId: item.id,
      chapters: const [
        SourceNovelCatalogChapter(remoteIdentity: 'one', title: '一', index: 0),
        SourceNovelCatalogChapter(remoteIdentity: 'new', title: '新', index: 1),
      ],
    );
    expect(
      (await session.itemsByRemoteIdentities(const <String>['one', 'two', 'new'])).keys,
      containsAllInOrder(const <String>['one', 'two']),
    );
    final reopened = await library.openNovelReaderSession(item.id);
    expect(
      (await reopened!.itemsByRemoteIdentities(const <String>['one', 'two', 'new'])).keys,
      containsAllInOrder(const <String>['new', 'one']),
    );
    expect((await reopened.resolveProgressEntry())!.remoteIdentity, 'new');
  });

  test('session remains on its snapshot while a refresh replaces the catalog', () async {
    final item = await library.bookshelf.add(title: '快照书', kind: ContentKind.novel, source: source);
    await library.catalog.ensureNovelCatalog(
      itemId: item.id,
      chapters: const [SourceNovelCatalogChapter(remoteIdentity: 'old', title: '旧', index: 0)],
    );
    final session = await library.openNovelReaderSession(item.id);
    final refresh = library.catalog.syncNovelCatalog(
      itemId: item.id,
      chapters: const [SourceNovelCatalogChapter(remoteIdentity: 'fresh', title: '新', index: 0)],
    );
    expect((await session!.itemAtIndex(0))!.remoteIdentity, 'old');
    await refresh;
    expect((await (await library.openNovelReaderSession(item.id))!.itemAtIndex(0))!.remoteIdentity, 'fresh');
  });

  test('legacy snapshot count is read once and bad content references are safe', () async {
    final item = await library.bookshelf.add(title: '旧数据书', kind: ContentKind.novel, source: source);
    await library.catalog.ensureNovelCatalog(
      itemId: item.id,
      chapters: const [SourceNovelCatalogChapter(remoteIdentity: 'legacy', title: '旧', index: 0)],
    );
    await library.close();
    final store = await PersistenceRecordStore.open(dataRoot: root, registry: RecordDocumentRegistry(contentLibraryRecordDocumentCodecs));
    final record = await store.read(
      id: item.id.value,
      scope: const ScopeKey(kind: 'content_library', id: 'default'),
    );
    final document = Map<String, Object?>.from(record!.document)..remove('catalogCount');
    await store.update(previous: record, document: document);
    await store.close();
    library = await ContentLibrary.open(dataRoot: root);

    final session = await library.openNovelReaderSession(item.id);
    expect(session!.catalogCount, 1);
    expect(await session.itemByRemoteIdentity('missing'), isNull);
    expect(
      await session.readContent(
        CatalogEntry(
          id: const CatalogEntryId('bad'),
          itemId: item.id,
          bindingId: const SourceBindingId('binding'),
          remoteIdentity: 'bad',
          title: '坏引用',
          orderKey: '000000000000',
          index: 0,
          kind: ContentKind.novel,
          contentStatus: 'ready',
          contentReference: 'missing-object',
        ),
      ),
      isA<UnsupportedContent>(),
    );
  });

  test('session cache targets one chapter without listing the catalog', () async {
    final item = await library.bookshelf.add(title: '定向缓存书', kind: ContentKind.novel, source: source);
    await library.catalog.ensureNovelCatalog(
      itemId: item.id,
      chapters: const [SourceNovelCatalogChapter(remoteIdentity: 'target', title: '目标', index: 0)],
    );
    final session = await library.openNovelReaderSession(item.id);
    final entry = await session!.itemAtIndex(0);
    await session.cacheChapter(entry: entry!, text: '缓存正文');
    final refreshedEntry = await session.itemByRemoteIdentity('target');
    expect(await session.readContent(refreshedEntry!), isA<NovelChapterContent>());
    expect(((await session.readContent(refreshedEntry)) as NovelChapterContent).text, '缓存正文');
    expect(refreshedEntry.wordCount, '缓存正文'.length);
  });

  test('sync previews and transactionally applies shelf metadata and progress', () async {
    final item = await library.bookshelf.addFromSource(
      const BookshelfAddRequest(
        title: '旧标题',
        author: '作者',
        kind: ContentKind.novel,
        pluginId: 'fixture',
        pluginVersion: '1.0.0',
        remoteContentId: 'sync-book',
      ),
    );
    await library.readingProgress.save(
      LibraryReadingProgress(
        itemId: item.id,
        chapterId: 'old',
        paragraphId: 'p',
        characterOffset: 1,
        chapterIndex: 0,
        chapterFraction: 0.1,
        bookFraction: 0.1,
        updatedAtUtc: DateTime.utc(2026, 8, 24),
      ),
    );
    final sender = LibrarySyncItem(
      pluginId: 'fixture',
      producerPluginVersion: '2.0.0',
      remoteContentId: 'sync-book',
      kind: ContentKind.novel,
      title: '新标题',
      author: '新作者',
      progress: LibrarySyncReadingProgress(
        chapterId: 'new',
        paragraphId: 'p2',
        characterOffset: 2,
        chapterIndex: 1,
        chapterFraction: 0.2,
        bookFraction: 0.2,
        updatedAtUtc: DateTime.utc(2026, 8, 25),
      ),
    );
    final incoming = LibrarySyncSnapshot(items: [sender]);
    final preview = await library.sync.preview(incoming, availablePluginIds: const {'fixture'});
    expect(preview.newItems, isEmpty);
    expect(preview.conflicts, hasLength(1));
    final result = await library.sync.apply(
      incoming,
      preview: preview,
      choices: {preview.conflicts.single.identity: LibrarySyncConflictChoice.smartMerge},
    );
    expect(result.code, LibrarySyncResultCode.applied);
    expect(result.updatedItems, 1);
    expect(result.progressApplied, 1);
    expect((await library.getLibraryItem(item.id))!.title, '新标题');
    expect((await library.readingProgress.load(item.id))!.chapterId, 'new');
  });

  test('sync reports missing plugins as blocked without writing them', () async {
    final incoming = LibrarySyncSnapshot(
      items: const [
        LibrarySyncItem(
          pluginId: 'not-installed',
          producerPluginVersion: '1.0.0',
          remoteContentId: 'missing-plugin-book',
          kind: ContentKind.novel,
          title: '书',
        ),
      ],
    );
    final preview = await library.sync.preview(incoming, availablePluginIds: const {'fixture'});
    expect(preview.blocked.single.reason, LibrarySyncBlockedReason.missingPlugin);
    final result = await library.sync.apply(incoming, preview: preview, choices: const {});
    expect(result.code, LibrarySyncResultCode.applied);
    expect(result.blockedItems, 1);
    expect((await library.listLibrary(const LibraryQuery())).items, isEmpty);
  });
}
