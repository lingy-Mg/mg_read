/// 手动刷新书架书籍的应用契约。
///
/// 职责：
/// - 以稳定书架 ID 请求数据源的原始书籍身份并提交完整元数据与目录。
///
/// 注意：
/// - 展示层不直接访问 Runtime、封面缓存或 Content Library。
/// - 刷新失败必须保留之前已提交的书架投影。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Refreshes one persisted source-bound bookshelf item.
abstract interface class LibraryBookRefresher {
  Future<void> refresh(String bookId);
}

/// Provides the refresh capability only in an app composition with persistence.
final libraryBookRefresherProvider = Provider<LibraryBookRefresher?>((Ref ref) => null);
