/// 应用共享的数据源封面缓存适配器。
///
/// 职责：
/// - 读取和写入 Content Library 所有的封面缓存。
/// - 在缓存缺失时获取远端封面，并迁移旧书架封面对象。
///
/// 注意：
/// - 此适配器只返回显示字节，不向页面暴露文件路径或网络响应。
/// - 调用方必须异步消费结果，封面失败不得阻塞书籍主体内容。
///
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/shared/presentation/widgets/async_book_cover_loader.dart';

/// 搜索、发现、详情和书架共用的封面解析实现。
final class ContentLibrarySourceCoverPersistence implements BookCoverBytesLoader {
  ContentLibrarySourceCoverPersistence(this._library, {SourceCoverFetcher? fetcher, SourceCoverHttpClientFactory? clientFactory})
    : _fetcher = fetcher ?? ((uri) => _fetchCover(uri, clientFactory ?? _createDirectHttpClient));

  final ContentLibrary _library;
  final SourceCoverFetcher _fetcher;

  @override
  Future<List<int>?> resolve(BookCoverRequest request) async {
    final url = request.coverUrl;
    if (url.scheme != 'http' && url.scheme != 'https') {
      return null;
    }
    final key = CoverKey(
      pluginId: request.pluginId,
      pluginVersion: request.pluginVersion,
      remoteContentId: request.remoteContentId,
      coverUrl: url,
    );
    final persisted = await _library.covers.read(key);
    if (persisted != null && persisted.isNotEmpty) return persisted;
    final legacyLibraryItemId = request.legacyLibraryItemId;
    if (legacyLibraryItemId != null) {
      final legacy = await _library.bookshelf.readCover(LibraryItemId(legacyLibraryItemId));
      if (legacy != null && legacy.isNotEmpty) {
        try {
          await _library.covers.save(key: key, bytes: legacy);
        } catch (_) {
          // The legacy result remains immediately usable.
        }
        return legacy;
      }
    }
    try {
      final fetched = await _fetcher(url);
      if (fetched == null || fetched.isEmpty) return null;
      try {
        await _library.covers.save(key: key, bytes: fetched);
      } catch (_) {
        // Keep the freshly fetched bytes usable; retry persistence later.
      }
      return fetched;
    } catch (_) {
      return null;
    }
  }
}

typedef SourceCoverFetcher = Future<List<int>?> Function(Uri uri);
typedef SourceCoverHttpClientFactory = Future<HttpClient> Function();

Future<HttpClient> _createDirectHttpClient() async => HttpClient();

Future<List<int>?> _fetchCover(Uri uri, SourceCoverHttpClientFactory clientFactory) async {
  final client = await clientFactory()
    ..connectionTimeout = const Duration(seconds: 10)
    ..idleTimeout = const Duration(seconds: 10);
  try {
    final request = await client.getUrl(uri).timeout(const Duration(seconds: 15));
    request.followRedirects = true;
    request.maxRedirects = 3;
    final response = await request.close().timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 300) return null;
    final builder = BytesBuilder(copy: false);
    var length = 0;
    await for (final chunk in response.timeout(const Duration(seconds: 15))) {
      length += chunk.length;
      if (length > 5 * 1024 * 1024) return null;
      builder.add(chunk);
    }
    final bytes = builder.takeBytes();
    return bytes.isEmpty ? null : Uint8List.fromList(bytes);
  } finally {
    client.close(force: true);
  }
}
