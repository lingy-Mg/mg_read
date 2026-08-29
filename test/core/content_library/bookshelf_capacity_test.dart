/// Content Library 书架全局容量边界测试。
///
/// 职责：
/// - 覆盖单条、重复、并发与 LAN/本地导入共用批量事务的 100 本硬上限。
/// - 验证主书架、个人统计和同步快照读取同一容量边界。
///
/// 注意：
/// - 每个用例使用独立临时目录，不依赖真实用户书架。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/core/content_library/src/models.dart';
import 'package:mg_read/features/profile/data/content_library_profile_reading_stats_loader.dart';

void main() {
  late Directory root;
  late ContentLibrary library;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mg-read-bookshelf-capacity-');
    library = await ContentLibrary.open(dataRoot: root);
  });

  tearDown(() async {
    await library.close();
    await root.delete(recursive: true);
  });

  test('allows 99 to 100, rejects 100 to 101, and keeps duplicate updates idempotent', () async {
    await _fillShelf(library, bookshelfMaxItemCount - 1);

    await library.bookshelf.add(title: '第 100 本', kind: ContentKind.novel, source: _source('book-99'));
    final atCapacity = await library.listLibrary(const LibraryQuery(limit: bookshelfMaxItemCount));
    expect(atCapacity.items, hasLength(bookshelfMaxItemCount));
    expect((await ContentLibraryProfileReadingStatsLoader(library).load()).shelfBookCount, bookshelfMaxItemCount);
    expect((await library.createSyncSnapshot()).items, hasLength(bookshelfMaxItemCount));

    await expectLater(
      library.bookshelf.add(title: '第 101 本', kind: ContentKind.novel, source: _source('book-100')),
      throwsA(_capacityFailure(currentCount: bookshelfMaxItemCount, requestedNewItems: 1)),
    );

    final duplicate = await library.bookshelf.add(title: '已更新标题', kind: ContentKind.novel, source: _source('book-0'));
    expect(duplicate.title, '已更新标题');
    expect((await library.listLibrary(const LibraryQuery(limit: bookshelfMaxItemCount))).items, hasLength(bookshelfMaxItemCount));
  });

  test('serializes concurrent additions so only one final slot is committed', () async {
    await _fillShelf(library, bookshelfMaxItemCount - 1);

    final outcomes = await Future.wait<Object>(<Future<Object>>[
      _capture(library.bookshelf.add(title: '并发一', kind: ContentKind.novel, source: _source('concurrent-1'))),
      _capture(library.bookshelf.add(title: '并发二', kind: ContentKind.novel, source: _source('concurrent-2'))),
    ]);

    expect(outcomes.whereType<LibraryItem>(), hasLength(1));
    expect(outcomes.whereType<BookshelfCapacityExceededException>(), hasLength(1));
    expect((await library.listLibrary(const LibraryQuery(limit: bookshelfMaxItemCount))).items, hasLength(bookshelfMaxItemCount));
  });

  test('rejects an over-capacity LAN or local-import batch atomically', () async {
    await _fillShelf(library, bookshelfMaxItemCount - 1);
    final snapshot = LibrarySyncSnapshot(items: <LibrarySyncItem>[_syncItem('incoming-1'), _syncItem('incoming-2')]);
    final preview = await library.previewSyncSnapshot(snapshot, availablePluginIds: const <String>{'fixture'});

    await expectLater(
      library.applySyncSnapshot(snapshot, preview: preview, choices: const <LibrarySyncIdentity, LibrarySyncConflictChoice>{}),
      throwsA(_capacityFailure(currentCount: bookshelfMaxItemCount - 1, requestedNewItems: 2)),
    );
    expect((await library.listLibrary(const LibraryQuery(limit: bookshelfMaxItemCount))).items, hasLength(bookshelfMaxItemCount - 1));
  });
}

Future<void> _fillShelf(ContentLibrary library, int count) async {
  for (var index = 0; index < count; index++) {
    await library.bookshelf.add(title: '书籍 $index', kind: ContentKind.novel, source: _source('book-$index'));
  }
}

ContentLibraryIngest _source(String remoteBookId) => ContentLibraryIngest(
  pluginId: 'fixture',
  producerPluginVersion: '1.0.0',
  dataVersion: 1,
  opaqueData: <String, Object?>{'remoteBookId': remoteBookId},
);

LibrarySyncItem _syncItem(String remoteContentId) => LibrarySyncItem(
  pluginId: 'fixture',
  producerPluginVersion: '1.0.0',
  remoteContentId: remoteContentId,
  kind: ContentKind.novel,
  title: remoteContentId,
);

Future<Object> _capture(Future<LibraryItem> future) async {
  try {
    return await future;
  } on Object catch (error) {
    return error;
  }
}

Matcher _capacityFailure({required int currentCount, required int requestedNewItems}) => isA<BookshelfCapacityExceededException>()
    .having((error) => error.code, 'code', bookshelfCapacityExceededCode)
    .having((error) => error.currentCount, 'currentCount', currentCount)
    .having((error) => error.requestedNewItems, 'requestedNewItems', requestedNewItems);
