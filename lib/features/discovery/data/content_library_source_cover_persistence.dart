import 'dart:io';
import 'dart:typed_data';

import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/discovery/application/source_cover_persistence.dart';

/// Production cover adapter shared by search, discovery and detail.
final class ContentLibrarySourceCoverPersistence
    implements SourceCoverPersistence {
  ContentLibrarySourceCoverPersistence(
    this._library, {
    SourceCoverFetcher? fetcher,
  }) : _fetcher = fetcher ?? _fetchCover;

  final ContentLibrary _library;
  final SourceCoverFetcher _fetcher;

  @override
  Future<List<int>?> resolve({
    required String pluginId,
    String pluginVersion = 'unknown',
    required String remoteContentId,
    required Uri? coverUrl,
  }) async {
    final url = coverUrl;
    if (url == null || (url.scheme != 'http' && url.scheme != 'https')) {
      return null;
    }
    final key = CoverKey(
      pluginId: pluginId,
      pluginVersion: pluginVersion,
      remoteContentId: remoteContentId,
      coverUrl: url,
    );
    final persisted = await _library.covers.read(key);
    if (persisted != null && persisted.isNotEmpty) return persisted;
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

Future<List<int>?> _fetchCover(Uri uri) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..idleTimeout = const Duration(seconds: 10);
  try {
    final request = await client
        .getUrl(uri)
        .timeout(const Duration(seconds: 15));
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
