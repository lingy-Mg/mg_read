import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/library/application/library_overview_loader.dart';
import 'package:mg_read/features/library/domain/library_item_summary.dart';
import 'package:mg_read/features/library/domain/library_overview.dart';

/// Reads the app-owned bookshelf through the public Content Library facade.
///
/// The feature receives only stable item summaries; persistence records, paths,
/// and dynamic source payloads remain inside core.
typedef LibraryCoverFetcher = Future<List<int>?> Function(Uri uri);

final class ContentLibraryOverviewLoader implements LibraryOverviewLoader {
  ContentLibraryOverviewLoader(this._library, {LibraryCoverFetcher? fetcher})
    : _fetcher = fetcher ?? _fetchCover;

  final ContentLibrary _library;
  final LibraryCoverFetcher _fetcher;

  @override
  Future<LibraryOverview> load() async {
    final page = await _library.listLibrary(const LibraryQuery(limit: 100));
    final progressByItemId = <String, LibraryReadingProgress>{
      for (final progress in await _library.readingProgress.loadMany(
        page.items.map((item) => item.id),
      ))
        progress.itemId.value: progress,
    };
    final coverBytesByItemId = await _loadCovers(page.items);
    final items = page.items.map((item) {
      final progress = progressByItemId[item.id.value];
      return LibraryItemSummary(
        id: item.id.value,
        title: item.title,
        author: item.author,
        coverUrl: item.coverUrl,
        coverBytes: coverBytesByItemId[item.id.value],
        sourceName: item.sourceName,
        readingProgress: progress?.bookFraction,
        readingChapterIndex: progress?.chapterIndex,
        lastReadAtUtc: progress?.updatedAtUtc,
      );
    });
    return LibraryOverview(items: items);
  }

  Future<Map<String, List<int>?>> _loadCovers(List<LibraryItem> items) async {
    if (items.isEmpty) return const <String, List<int>?>{};
    final covers = <String, List<int>?>{};
    var nextIndex = 0;

    Future<void> worker() async {
      while (true) {
        final int index;
        if (nextIndex >= items.length) return;
        index = nextIndex++;
        final item = items[index];
        covers[item.id.value] = await _loadCover(item);
      }
    }

    final workerCount = items.length < 4 ? items.length : 4;
    await Future.wait<void>(
      List<Future<void>>.generate(workerCount, (_) => worker()),
    );
    return covers;
  }

  Future<List<int>?> _loadCover(LibraryItem item) async {
    final uri = item.coverUrl;
    if (uri == null) return null;
    final source = item.source;
    final coverKey = source == null
        ? null
        : CoverKey(
            pluginId: source.pluginId,
            pluginVersion: source.pluginVersion,
            remoteContentId: source.remoteContentId,
            coverUrl: uri,
          );
    if (coverKey != null) {
      final persisted = await _library.covers.read(coverKey);
      if (persisted != null && persisted.isNotEmpty) return persisted;
    }
    // Keep reading the legacy item-owned object so existing shelves migrate
    // without forcing a network request on their first post-upgrade load.
    final legacyPersisted = await _library.bookshelf.readCover(item.id);
    if (legacyPersisted != null && legacyPersisted.isNotEmpty) {
      if (coverKey != null) {
        try {
          await _library.covers.save(key: coverKey, bytes: legacyPersisted);
        } catch (_) {
          // The legacy object is still a valid in-memory result.
        }
      }
      return legacyPersisted;
    }
    try {
      final bytes = await _fetcher(uri);
      if (bytes == null || bytes.isEmpty) return null;
      try {
        if (coverKey != null) {
          await _library.covers.save(key: coverKey, bytes: bytes);
        } else {
          await _library.bookshelf.saveCover(
            id: item.id,
            bytes: bytes,
            mimeType: 'image/unknown',
          );
        }
      } catch (_) {
        // The shelf remains usable with this in-memory cover; the next load
        // will retry persistence if the file store was temporarily unavailable.
      }
      return bytes;
    } catch (_) {
      // A cover is optional display data and must not make the shelf fail.
      return null;
    }
  }
}

Future<List<int>?> _fetchCover(Uri uri) async {
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
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
