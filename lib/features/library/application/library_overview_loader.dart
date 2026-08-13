import 'package:mg_read/features/library/domain/library_overview.dart';

/// Application port that supplies a local library overview.
///
/// M2.2 will provide the persisted implementation. This M2.1 default is an
/// explicit empty local projection, never a network or Runtime request.
abstract interface class LibraryOverviewLoader {
  /// Reads the latest locally available overview.
  Future<LibraryOverview> load();
}

/// Temporary no-op implementation used before the M2.2 repository exists.
final class EmptyLibraryOverviewLoader implements LibraryOverviewLoader {
  /// Creates an empty local loader.
  const EmptyLibraryOverviewLoader();

  @override
  Future<LibraryOverview> load() async => const LibraryOverview.empty();
}
