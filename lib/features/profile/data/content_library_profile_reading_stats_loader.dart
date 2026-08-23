import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/profile/application/profile_reading_stats_loader.dart';
import 'package:mg_read/features/profile/domain/profile_reading_stats.dart';

/// Projects only aggregate local reading totals from Content Library.
final class ContentLibraryProfileReadingStatsLoader
    implements ProfileReadingStatsLoader {
  const ContentLibraryProfileReadingStatsLoader(this._library);

  final ContentLibrary _library;

  @override
  Future<ProfileReadingStats> load() async {
    final items = <LibraryItem>[];
    String? cursor;
    do {
      final page = await _library.listLibrary(
        LibraryQuery(after: cursor, limit: 100),
      );
      items.addAll(page.items);
      cursor = page.nextCursor;
    } while (cursor != null);
    final progress = await _library.readingProgress.loadMany(
      items.map((item) => item.id),
    );
    return ProfileReadingStats(
      totalReadingSeconds: progress.fold<int>(
        0,
        (total, value) => total + value.totalReadingSeconds,
      ),
      readBookCount: progress.length,
      shelfBookCount: items.length,
    );
  }
}
