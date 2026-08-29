/// Content Library 正文图片缓存网关。
///
/// 将存储归属映射成用户可读漫画名称，不泄漏路径或持久化实现。
library;

import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/cache/application/cover_cache_manager.dart';

final class ContentLibraryMangaImageCacheGateway implements MangaImageCacheGateway {
  const ContentLibraryMangaImageCacheGateway(this._load);
  final Future<ContentLibrary> Function() _load;
  @override
  Future<MangaImageCacheUsage> loadUsage() async {
    final library = await _load();
    final storage = await library.mangaImageCache.usage();
    final bytesByItem = <String, int>{for (final item in storage.items) item.itemId.value: item.bytes};
    final entries = <MangaImageCacheEntry>[];
    final seen = <String>{};
    String? after;
    final cursors = <String>{};
    do {
      final page = await library.listLibrary(LibraryQuery(after: after, limit: 100));
      for (final item in page.items) {
        if (item.kind != ContentKind.manga) continue;
        seen.add(item.id.value);
        entries.add(MangaImageCacheEntry(itemId: item.id.value, title: item.title, bytes: bytesByItem[item.id.value] ?? 0));
      }
      final next = page.nextCursor;
      if (next == null || next.isEmpty || !cursors.add(next)) break;
      after = next;
    } while (true);
    for (final item in storage.items) {
      if (seen.contains(item.itemId.value)) continue;
      entries.add(MangaImageCacheEntry(itemId: item.itemId.value, title: '已移出书架的漫画', bytes: item.bytes));
    }
    entries.sort((a, b) {
      final byBytes = b.bytes.compareTo(a.bytes);
      return byBytes != 0 ? byBytes : a.title.compareTo(b.title);
    });
    return MangaImageCacheUsage(
      totalBytes: storage.totalBytes,
      unattributedBytes: storage.unattributedBytes,
      entries: List<MangaImageCacheEntry>.unmodifiable(entries),
    );
  }

  @override
  Future<int> clear() async => (await _load()).mangaImageCache.clear();
}
