/// Content Library 封面缓存管理适配器。
///
/// 职责：
/// - 将应用层封面缓存网关映射到共享 Content Library 实例。
///
/// 注意：
/// - 延迟取得实例，避免设置页面自行打开第二套持久化生命周期。
/// - 不访问或泄漏任何缓存路径。
library;

import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/cache/application/cover_cache_manager.dart';

typedef ContentLibraryLoader = Future<ContentLibrary> Function();

final class ContentLibraryCoverCacheGateway implements CoverCacheGateway {
  const ContentLibraryCoverCacheGateway(this._loadLibrary);

  final ContentLibraryLoader _loadLibrary;

  @override
  Future<int> usageBytes() async => (await _loadLibrary()).covers.usageBytes();

  @override
  Future<int> clear() async => (await _loadLibrary()).covers.clear();
}
