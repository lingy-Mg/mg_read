import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/discovery/application/bookshelf_membership.dart';

/// Reads the shelf in pages once and projects only the fields needed by
/// discovery/search membership checks.
final class ContentLibraryBookshelfMembershipLoader
    implements BookshelfMembershipLoader {
  const ContentLibraryBookshelfMembershipLoader(this._library);

  final ContentLibrary _library;

  @override
  Future<Iterable<BookshelfMembershipEntry>> load() async {
    final entries = <BookshelfMembershipEntry>[];
    String? cursor;
    do {
      final page = await _library.listLibrary(
        LibraryQuery(after: cursor, limit: 100),
      );
      entries.addAll(
        page.items
            .where((item) => item.source != null)
            .map(
              (item) => BookshelfMembershipEntry(
                pluginId: item.source!.pluginId,
                title: item.title,
              ),
            ),
      );
      cursor = page.nextCursor;
    } while (cursor != null);
    return entries;
  }
}
