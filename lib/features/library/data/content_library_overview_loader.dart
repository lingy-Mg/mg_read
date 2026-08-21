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
    final items = await Future.wait(
      page.items.map((item) async {
        final progress = await _library.readingProgress.load(item.id);
        return LibraryItemSummary(
          id: item.id.value,
          title: item.title,
          readingProgress: progress?.bookFraction,
          readingChapterIndex: progress?.chapterIndex,
          lastReadAtUtc: progress?.updatedAtUtc,
        );
      }),
    );
    return LibraryOverview(
      items: items,
    );
  }
}
