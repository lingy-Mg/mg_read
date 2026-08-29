/// Content Library 数据库缓存维护适配器。
///
/// 延迟复用组合根的唯一 Content Library，不泄漏路径或持久化对象。
library;

import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/cache/application/database_cache_manager.dart';

final class ContentLibraryDatabaseCacheGateway implements DatabaseCacheGateway {
  const ContentLibraryDatabaseCacheGateway(this._load);

  final Future<ContentLibrary> Function() _load;

  @override
  Future<DatabaseCacheUsage> inspect() async {
    final result = await (await _load()).storageMaintenance.inspect();
    return DatabaseCacheUsage(
      staleCatalogRecords: result.staleCatalogRecords,
      detachedMetadataRecords: result.detachedMetadataRecords,
      orphanContentObjects: result.orphanContentObjects,
      reclaimableContentBytes: result.reclaimableContentBytes,
      estimatedReclaimableBytes: result.estimatedReclaimableBytes,
      compactableDatabaseBytes: result.compactableDatabaseBytes,
    );
  }

  @override
  Future<DatabaseCacheCleanupResult> clearAll() async {
    final result = await (await _load()).storageMaintenance.clearAll();
    return DatabaseCacheCleanupResult(
      deletedRecords: result.staleCatalogRecords + result.detachedMetadataRecords,
      deletedContentObjects: result.deletedContentObjects,
      releasedLogicalBytes: result.releasedLogicalBytes,
      isPartial: result.isPartial,
    );
  }

  @override
  Future<DatabaseCacheCompactionResult> compact() async {
    final result = await (await _load()).storageMaintenance.compact();
    return DatabaseCacheCompactionResult(releasedBytes: result.releasedBytes);
  }
}
