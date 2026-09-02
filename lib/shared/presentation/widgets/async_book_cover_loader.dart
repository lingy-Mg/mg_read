/// 跨页面书籍封面异步加载契约。
///
/// 职责：
/// - 用稳定数据源身份描述一张可缓存的封面。
/// - 为共享封面组件提供去重的异步字节读取入口。
/// - 以条目和编码字节双上限保留稳定 Uint8List，供 Flutter 复用图片键。
///
/// 注意：
/// - 页面主体不得等待该 Provider；缺失、失败和取消均由封面组件降级显示。
/// - 解析器返回显示所需的字节，页面负责展示和生命周期管理。
///
library;

import 'dart:collection';
import 'dart:typed_data';

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

/// Keeps bytes that a visible cover has already resolved available to the
/// next route without making that route resolve the cover again.
final class BookCoverMemoryCache {
  BookCoverMemoryCache._();

  static const int _maxEntries = 32;
  static const int _maxBytes = 16 * 1024 * 1024;
  static final LinkedHashMap<_BookCoverIdentity, Uint8List> _entries = LinkedHashMap<_BookCoverIdentity, Uint8List>();
  static int _totalBytes = 0;

  static Uint8List? read(BookCoverRequest request) {
    final identity = _BookCoverIdentity.fromRequest(request);
    final bytes = _entries.remove(identity);
    if (bytes == null) return null;
    _entries[identity] = bytes;
    return bytes;
  }

  static void write(BookCoverRequest request, List<int>? bytes) {
    if (bytes == null || bytes.isEmpty) return;
    final normalized = normalizeBookCoverBytes(bytes);
    if (normalized.lengthInBytes > _maxBytes) return;
    final identity = _BookCoverIdentity.fromRequest(request);
    final previous = _entries.remove(identity);
    if (previous != null) _totalBytes -= previous.lengthInBytes;
    _entries[identity] = normalized;
    _totalBytes += normalized.lengthInBytes;
    while (_entries.length > _maxEntries || _totalBytes > _maxBytes) {
      final removed = _entries.remove(_entries.keys.first);
      if (removed != null) _totalBytes -= removed.lengthInBytes;
    }
  }

  /// Drops one visible cover after its source has explicitly refreshed it.
  static void remove(BookCoverRequest request) {
    final removed = _entries.remove(_BookCoverIdentity.fromRequest(request));
    if (removed != null) _totalBytes -= removed.lengthInBytes;
  }

  /// Returns already resolved bytes without restarting an asynchronous load.
  static Uint8List? peek(BookCoverRequest request) => _entries[_BookCoverIdentity.fromRequest(request)];

  /// Drops route-to-route cover bytes after the persistent cache is cleared.
  static void clear() {
    _entries.clear();
    _totalBytes = 0;
  }
}

/// Returns one stable typed buffer for Flutter's decoded image-cache identity.
/// Callers must treat the returned bytes as immutable.
Uint8List normalizeBookCoverBytes(List<int> bytes) => bytes is Uint8List ? bytes : Uint8List.fromList(bytes);

@immutable
final class _BookCoverIdentity {
  const _BookCoverIdentity({required this.pluginId, required this.pluginVersion, required this.remoteContentId, required this.coverUrl});

  factory _BookCoverIdentity.fromRequest(BookCoverRequest request) => _BookCoverIdentity(
    pluginId: request.pluginId,
    pluginVersion: request.pluginVersion,
    remoteContentId: request.remoteContentId,
    coverUrl: request.coverUrl,
  );

  final String pluginId;
  final String pluginVersion;
  final String remoteContentId;
  final Uri coverUrl;

  @override
  bool operator ==(Object other) =>
      other is _BookCoverIdentity &&
      other.pluginId == pluginId &&
      other.pluginVersion == pluginVersion &&
      other.remoteContentId == remoteContentId &&
      other.coverUrl == coverUrl;

  @override
  int get hashCode => Object.hash(pluginId, pluginVersion, remoteContentId, coverUrl);
}

/// App composition supplies the Content Library-backed implementation.
final bookCoverBytesLoaderProvider = Provider<BookCoverBytesLoader>((Ref ref) => const EmptyBookCoverBytesLoader());

/// Whether app composition installed the persistent loader used by remote icons.
final bookCoverBytesLoaderAvailableProvider = Provider<bool>((Ref ref) => false);

/// Per-cover asynchronous state shared by every mounted consumer of one key.
final bookCoverBytesProvider = FutureProvider.autoDispose.family<List<int>?, BookCoverRequest>((Ref ref, BookCoverRequest request) async {
  final memory = BookCoverMemoryCache.read(request);
  if (memory != null) return memory;
  final bytes = await ref.watch(bookCoverBytesLoaderProvider).resolve(request);
  BookCoverMemoryCache.write(request, bytes);
  return bytes;
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
