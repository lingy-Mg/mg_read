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
    final items = await _library.loadShelfProjection(limit: bookshelfMaxItemCount);
    final progress = items.where((item) => item.progressKind == ContentKind.novel).toList(growable: false);
    return ProfileReadingStats(
      totalReadingSeconds: progress.fold<int>(0, (total, value) => total + (value.totalReadingSeconds ?? 0)),
      readBookCount: progress.length,
      shelfBookCount: items.length,
    );
  }
}
