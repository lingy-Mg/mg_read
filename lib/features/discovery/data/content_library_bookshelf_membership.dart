import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/discovery/application/bookshelf_membership.dart';

/// Reads the one bounded shelf snapshot and projects only the fields needed by
/// discovery/search membership checks.
final class ContentLibraryBookshelfMembershipLoader implements BookshelfMembershipLoader {
  const ContentLibraryBookshelfMembershipLoader(this._library);

  final ContentLibrary _library;

  @override
  Future<Iterable<BookshelfMembershipEntry>> load() async {
    final page = await _library.listLibrary(const LibraryQuery(limit: bookshelfMaxItemCount));
    return page.items
        .where((item) => item.source != null)
        .map((item) => BookshelfMembershipEntry(itemId: item.id.value, pluginId: item.source!.pluginId, title: item.title));
  }
}
