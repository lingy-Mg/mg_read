import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/profile/application/profile_reading_stats_loader.dart';
import 'package:mg_read/features/profile/domain/profile_reading_stats.dart';

/// Projects aggregate local reading totals from the same bounded shelf snapshot
/// used by the main shelf and LAN export.
final class ContentLibraryProfileReadingStatsLoader implements ProfileReadingStatsLoader {
  const ContentLibraryProfileReadingStatsLoader(this._library);

  final ContentLibrary _library;

  @override
  Future<ProfileReadingStats> load() async {
    final items = (await _library.listLibrary(const LibraryQuery(limit: bookshelfMaxItemCount))).items;
    final progress = await _library.readingProgress.loadMany(items.map((item) => item.id));
    return ProfileReadingStats(
      totalReadingSeconds: progress.fold<int>(0, (total, value) => total + value.totalReadingSeconds),
      readBookCount: progress.length,
      shelfBookCount: items.length,
    );
  }
}
