/// 书架媒体入口投影测试。
///
/// 职责：
/// - 验证已有书架投影可不等待详情或目录 IO 直接生成播放入口。
/// - 验证封面字节和持久化目录首项被稳定传递。
///
/// 注意：
/// - 测试不读取 Runtime、网络或本地数据库。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/library/domain/library_item_summary.dart';
import 'package:mg_read/features/library/presentation/library_book_list_view_data.dart';
import 'package:mg_read/features/library/presentation/library_media_entry_data.dart';

void main() {
  test('builds an immediate audio entry from the visible shelf projection', () {
    final item = LibraryItemSummary(
      id: 'shelf-audio',
      title: '测试听书',
      contentKind: ContentKind.audio,
      coverBytes: const <int>[1, 2, 3],
      coverPluginId: 'fixture-source',
      coverPluginVersion: '1.0.0',
      coverRemoteContentId: 'remote-audio',
      sourceName: '测试来源',
      latestChapterId: 'latest',
      latestChapterTitle: '最新一集',
    );
    final entry = immediateLibraryMediaEntry(item, _book('shelf-audio'));

    expect(entry, isNotNull);
    expect(entry!.detail.pluginId, 'fixture-source');
    expect(entry.detail.summary.id, 'remote-audio');
    expect(entry.detail.summary.contentKind, PluginContentKind.audio);
    expect(entry.detail.summary.coverBytes, const <int>[1, 2, 3]);
    expect(entry.catalog.items, isEmpty);
    expect(entry.chapter.id, 'latest');
  });

  test('uses the first unlocked persisted chapter when fallback loading is needed', () {
    final detail = libraryDetailPreview(
      const LibraryItemSummary(
        id: 'shelf-video',
        title: '测试视频',
        contentKind: ContentKind.video,
        coverPluginId: 'fixture-source',
        coverRemoteContentId: 'remote-video',
      ),
      _book('shelf-video'),
    );
    final locked = _chapter('locked', locked: true, order: 0);
    final playable = _chapter('playable', locked: false, order: 1);
    final catalog = PluginChaptersResult(pluginId: 'fixture-source', sourceName: '测试来源', items: <PluginChapterSummary>[locked, playable]);
    final entry = persistedLibraryMediaEntry(detail: detail, catalog: catalog, book: _book('shelf-video'));

    expect(entry.chapter.id, 'playable');
    expect(entry.catalog, same(catalog));
  });
}

LibraryBookListItemViewData _book(String id) =>
    LibraryBookListItemViewData(id: id, title: '测试条目', coverVariant: LibraryCoverVariant.indigo, status: LibraryBookStatus.local);

PluginChapterSummary _chapter(String id, {required bool locked, required int order}) => PluginChapterSummary(
  id: id,
  title: id,
  order: order,
  url: null,
  volumeTitle: null,
  wordCount: null,
  updatedAt: null,
  isLocked: locked,
  attributes: const <PluginContentAttribute>[],
);
