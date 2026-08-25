/// 跨页面书籍封面异步加载契约。
///
/// 职责：
/// - 用稳定书源身份描述一张可缓存的封面。
/// - 为共享封面组件提供去重的异步字节读取入口。
///
/// 注意：
/// - 页面主体不得等待该 Provider；缺失、失败和取消均由封面组件降级显示。
/// - 解析器只能返回显示字节，不得暴露持久化路径、Runtime 传输或原始网络响应。
///
/// TODO:
/// - 无。
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// One cacheable source-cover identity, optionally retaining a legacy shelf id.
@immutable
final class BookCoverRequest {
  const BookCoverRequest({
    required this.pluginId,
    required this.pluginVersion,
    required this.remoteContentId,
    required this.coverUrl,
    this.legacyLibraryItemId,
  }) : assert(pluginId != ''),
       assert(pluginVersion != ''),
       assert(remoteContentId != '');

  final String pluginId;
  final String pluginVersion;
  final String remoteContentId;
  final Uri coverUrl;
  final String? legacyLibraryItemId;

  @override
  bool operator ==(Object other) =>
      other is BookCoverRequest &&
      other.pluginId == pluginId &&
      other.pluginVersion == pluginVersion &&
      other.remoteContentId == remoteContentId &&
      other.coverUrl == coverUrl &&
      other.legacyLibraryItemId == legacyLibraryItemId;

  @override
  int get hashCode => Object.hash(pluginId, pluginVersion, remoteContentId, coverUrl, legacyLibraryItemId);
}

/// Application-provided resolver for a persistently cacheable source cover.
abstract interface class BookCoverBytesLoader {
  Future<List<int>?> resolve(BookCoverRequest request);
}

/// Safe default used by isolated presentation tests and startup fallbacks.
final class EmptyBookCoverBytesLoader implements BookCoverBytesLoader {
  const EmptyBookCoverBytesLoader();

  @override
  Future<List<int>?> resolve(BookCoverRequest request) async => null;
}

/// App composition supplies the Content Library-backed implementation.
final bookCoverBytesLoaderProvider = Provider<BookCoverBytesLoader>((Ref ref) => const EmptyBookCoverBytesLoader());

/// Per-cover asynchronous state shared by every mounted consumer of one key.
final bookCoverBytesProvider = FutureProvider.autoDispose.family<List<int>?, BookCoverRequest>((Ref ref, BookCoverRequest request) {
  return ref.watch(bookCoverBytesLoaderProvider).resolve(request);
});

/// Supplies one source identity to a discovery, search, or detail subtree.
class BookCoverSourceScope extends InheritedWidget {
  const BookCoverSourceScope({required this.pluginId, required super.child, this.pluginVersion = 'unknown', super.key})
    : assert(pluginId != ''),
      assert(pluginVersion != '');

  final String pluginId;
  final String pluginVersion;

  static BookCoverSourceScope? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<BookCoverSourceScope>();

  BookCoverRequest requestFor({required String remoteContentId, required Uri coverUrl}) =>
      BookCoverRequest(pluginId: pluginId, pluginVersion: pluginVersion, remoteContentId: remoteContentId, coverUrl: coverUrl);

  @override
  bool updateShouldNotify(BookCoverSourceScope oldWidget) => oldWidget.pluginId != pluginId || oldWidget.pluginVersion != pluginVersion;
}
