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
import 'package:novel_reader_ui/novel_reader_ui.dart';

/// Refreshes one persisted source-bound bookshelf item.
abstract interface class LibraryBookRefresher implements ReaderBookRefreshCapability {
  @override
  Future<void> refresh(String bookId);
}

/// Reports whether a refresh appended one or more catalog entries.
abstract interface class LibraryBookRefreshReporter {
  Future<bool> refreshAndReport(String bookId);
}

/// Refreshes only the chapter catalog, preserving the saved book metadata.
abstract interface class LibraryCatalogOnlyRefresher {
  Future<bool> refreshCatalogOnly(String bookId);
}

/// Provides the refresh capability only in an app composition with persistence.
final libraryBookRefresherProvider = Provider<LibraryBookRefresher?>((Ref ref) => null);
