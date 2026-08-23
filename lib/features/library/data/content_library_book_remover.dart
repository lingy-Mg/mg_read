import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/library/application/library_book_remover.dart';

/// Adapts the app-owned Content Library bookshelf removal operation.
final class ContentLibraryBookRemover implements LibraryBookRemover {
  /// Creates a remover backed by the shared app-owned Content Library.
  const ContentLibraryBookRemover(this._library);

  final ContentLibrary _library;

  @override
  Future<void> removeBook(String bookId) {
    return _library.bookshelf.remove(
      LibraryItemId(bookId),
      LibraryRemovalPolicy.removeFromShelfKeepContent,
    );
  }
}
