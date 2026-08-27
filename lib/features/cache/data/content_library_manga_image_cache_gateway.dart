/// Content Library 正文图片缓存网关。
///
/// 只转发用量与清理操作，不泄漏路径或持久化实现。
library;

import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/cache/application/cover_cache_manager.dart';

final class ContentLibraryMangaImageCacheGateway implements MangaImageCacheGateway {
  const ContentLibraryMangaImageCacheGateway(this._load);
  final Future<ContentLibrary> Function() _load;
  @override
  Future<int> usageBytes() async => (await _load()).mangaImageCache.usageBytes();
  @override
  Future<int> clear() async => (await _load()).mangaImageCache.clear();
}
