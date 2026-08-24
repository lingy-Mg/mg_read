import 'package:mg_read/features/library/domain/library_overview.dart';
import 'package:mg_read/core/content_library/content_library.dart';

/// Application port that supplies a local library overview.
///
/// The normal application composition supplies the persisted implementation.
/// This default keeps isolated widget tests explicitly local and empty.
abstract interface class LibraryOverviewLoader {
  /// Reads the latest locally available overview.
  Future<LibraryOverview> load({
    LibraryVisibility visibility = LibraryVisibility.normal,
  });
}

/// Explicit no-op implementation for isolated tests without app composition.
final class EmptyLibraryOverviewLoader implements LibraryOverviewLoader {
  /// Creates an empty local loader.
  const EmptyLibraryOverviewLoader();

  @override
  Future<LibraryOverview> load({
    LibraryVisibility visibility = LibraryVisibility.normal,
  }) async => const LibraryOverview.empty();
}
