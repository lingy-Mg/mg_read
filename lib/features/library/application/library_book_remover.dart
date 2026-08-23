import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Application port for removing one item from the user's bookshelf.
///
/// The presentation layer only knows the stable book ID. Persistence policy
/// and Content Library types stay behind the data adapter.
abstract interface class LibraryBookRemover {
  /// Removes [bookId] from the bookshelf while retaining reusable content.
  Future<void> removeBook(String bookId);
}

/// Provides the app-owned bookshelf removal capability when persistence exists.
final libraryBookRemoverProvider = Provider<LibraryBookRemover?>(
  (Ref ref) => null,
);
