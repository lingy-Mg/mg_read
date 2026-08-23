import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/library/application/library_overview_loader.dart';
import 'package:mg_read/features/library/domain/library_item_summary.dart';
import 'package:mg_read/features/library/domain/library_overview.dart';

/// Reads the app-owned bookshelf through the public Content Library facade.
///
/// The feature receives only stable item summaries; persistence records, paths,
/// and dynamic source payloads remain inside core.
final class ContentLibraryOverviewLoader implements LibraryOverviewLoader {
  const ContentLibraryOverviewLoader(this._library);

  final ContentLibrary _library;

  @override
  Future<LibraryOverview> load() async {
    final page = await _library.listLibrary(const LibraryQuery(limit: 100));
    final progressByItemId = <String, LibraryReadingProgress>{
      for (final progress in await _library.readingProgress.loadMany(
        page.items.map((item) => item.id),
      ))
        progress.itemId.value: progress,
    };
    final items = page.items.map((item) {
      final progress = progressByItemId[item.id.value];
      return LibraryItemSummary(
        id: item.id.value,
        title: item.title,
        author: item.author,
        coverUrl: item.coverUrl,
        sourceName: item.sourceName,
        readingProgress: progress?.bookFraction,
        readingChapterIndex: progress?.chapterIndex,
        lastReadAtUtc: progress?.updatedAtUtc,
      );
    });
    return LibraryOverview(items: items);
  }
}
