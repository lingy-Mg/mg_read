import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/library/application/library_book_visibility_changer.dart';

/// Adapts the public Content Library visibility operation for the library UI.
final class ContentLibraryBookVisibilityChanger implements LibraryBookVisibilityChanger {
  const ContentLibraryBookVisibilityChanger(this._library);

  final ContentLibrary _library;

  @override
  Future<void> setBookVisibility(String bookId, LibraryVisibility visibility) =>
      _library.setLibraryItemVisibility(LibraryItemId(bookId), visibility);
}
