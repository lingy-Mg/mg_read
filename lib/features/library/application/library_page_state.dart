import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/features/library/domain/library_overview.dart';

/// Explicit lifecycle stages for the library page.
enum LibraryPageStatus {
  initialLoading,
  refreshing,
  content,
  empty,
  retryableFailure,
  unavailableFailure,
}

/// Immutable page state that preserves successful data across refresh failures.
final class LibraryPageState {
  const LibraryPageState._({required this.status, this.overview, this.error});

  /// State before the first local overview has completed.
  const LibraryPageState.initialLoading()
    : this._(status: LibraryPageStatus.initialLoading);

  /// State while refreshing a previously successful overview.
  const LibraryPageState.refreshing(LibraryOverview overview)
    : this._(status: LibraryPageStatus.refreshing, overview: overview);

  /// Creates a successful content or successful empty state.
  factory LibraryPageState.loaded(LibraryOverview overview) {
    return LibraryPageState._(
      status: overview.isEmpty
          ? LibraryPageStatus.empty
          : LibraryPageStatus.content,
      overview: overview,
    );
  }

  /// Creates a failure that may retain the preceding successful overview.
  factory LibraryPageState.failure({
    required AppError error,
    LibraryOverview? retainedOverview,
  }) {
    return LibraryPageState._(
      status: error.retryable
          ? LibraryPageStatus.retryableFailure
          : LibraryPageStatus.unavailableFailure,
      overview: retainedOverview,
      error: error,
    );
  }

  /// The current explicit lifecycle state.
  final LibraryPageStatus status;

  /// Local data retained through refreshes and failures when available.
  final LibraryOverview? overview;

  /// A normalized error for the current failure state only.
  final AppError? error;

  /// Whether a prior successful result is available for continued display.
  bool get hasRetainedData => overview != null;

  /// Whether the state represents either category of failure.
  bool get hasFailure {
    return status == LibraryPageStatus.retryableFailure ||
        status == LibraryPageStatus.unavailableFailure;
  }
}
