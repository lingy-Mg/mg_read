import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/core/content_library/content_library.dart';

/// Narrow feature port for changing one persisted shelf item's visibility.
abstract interface class LibraryBookVisibilityChanger {
  Future<void> setBookVisibility(String bookId, LibraryVisibility visibility);
}

/// Provides the app-owned visibility capability when persistence exists.
final libraryBookVisibilityChangerProvider =
    Provider<LibraryBookVisibilityChanger?>((Ref ref) => null);
