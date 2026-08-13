import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/features/library/application/library_overview_loader.dart';
import 'package:mg_read/features/library/application/library_page_state.dart';
import 'package:mg_read/features/library/domain/library_overview.dart';

/// Composition port for the current feature-local library overview reader.
final libraryOverviewLoaderProvider = Provider<LibraryOverviewLoader>(
  (Ref ref) => const EmptyLibraryOverviewLoader(),
);

/// Owns the library page lifecycle and has no mutable view model state.
final libraryPageControllerProvider =
    NotifierProvider.autoDispose<LibraryPageController, LibraryPageState>(
      LibraryPageController.new,
    );

/// Immutable-state controller with request-generation protection.
///
/// Every new load gets a monotonically increasing generation. A completed
/// request can update state only when it is still latest and the provider has
/// not been disposed by its page lifecycle.
class LibraryPageController extends Notifier<LibraryPageState> {
  late LibraryOverviewLoader _loader;
  int _latestGeneration = 0;
  bool _disposed = false;

  @override
  LibraryPageState build() {
    _loader = ref.watch(libraryOverviewLoaderProvider);
    ref.onDispose(() {
      _disposed = true;
    });

    final int initialGeneration = ++_latestGeneration;
    scheduleMicrotask(() {
      unawaited(_load(initialGeneration));
    });
    return const LibraryPageState.initialLoading();
  }

  /// Reloads the local overview while retaining prior data when possible.
  Future<void> refresh() {
    final int generation = ++_latestGeneration;
    return _load(generation, retainedOverview: state.overview);
  }

  Future<void> _load(
    int generation, {
    LibraryOverview? retainedOverview,
  }) async {
    if (!_isCurrent(generation)) {
      return;
    }

    state = retainedOverview == null
        ? const LibraryPageState.initialLoading()
        : LibraryPageState.refreshing(retainedOverview);

    try {
      final LibraryOverview overview = await _loader.load();
      if (!_isCurrent(generation)) {
        return;
      }
      state = LibraryPageState.loaded(overview);
    } on Object catch (error) {
      if (!_isCurrent(generation)) {
        return;
      }
      state = LibraryPageState.failure(
        error: AppError.fromUnknown(error),
        retainedOverview: retainedOverview,
      );
    }
  }

  bool _isCurrent(int generation) {
    return !_disposed && generation == _latestGeneration;
  }
}
