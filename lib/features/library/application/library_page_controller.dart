import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/core/diagnostics/diagnostics.dart';
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
  late DiagnosticsManager _diagnostics;
  int _latestGeneration = 0;
  bool _disposed = false;

  @override
  LibraryPageState build() {
    _loader = ref.watch(libraryOverviewLoaderProvider);
    _diagnostics = ref.watch(diagnosticsManagerProvider);
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

    final span = _diagnostics.startSpan(
      AppDiagnosticEvents.libraryLoad,
      attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
        'requestGeneration': DiagnosticValue.int64(generation),
        'resultState': DiagnosticValue.string(
          retainedOverview == null ? 'initialLoading' : 'refreshing',
        ),
      }),
    );
    final stopwatch = Stopwatch()..start();
    void report(DiagnosticOutcome outcome) {
      stopwatch.stop();
      reportSlowDiagnostic(
        _diagnostics,
        subjectComponent: 'feature.library',
        operation: retainedOverview == null ? 'initialLoad' : 'refresh',
        elapsed: stopwatch.elapsed,
        threshold: AppDiagnosticThresholds.libraryOverview,
        outcome: outcome,
        traceContext: span.traceContext,
      );
    }

    state = retainedOverview == null
        ? const LibraryPageState.initialLoading()
        : LibraryPageState.refreshing(retainedOverview);

    try {
      final LibraryOverview overview = await _loader.load();
      if (!_isCurrent(generation)) {
        span.cancel(
          attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
            'requestGeneration': DiagnosticValue.int64(generation),
            'resultState': DiagnosticValue.string('staleDiscarded'),
          }),
        );
        report(DiagnosticOutcome.cancelled);
        return;
      }
      state = LibraryPageState.loaded(overview);
      span.complete(
        attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
          'requestGeneration': DiagnosticValue.int64(generation),
          'itemCount': DiagnosticValue.int64(overview.items.length),
          'resultState': DiagnosticValue.string(
            overview.isEmpty ? 'empty' : 'content',
          ),
        }),
      );
      report(DiagnosticOutcome.success);
    } on Object catch (error) {
      if (!_isCurrent(generation)) {
        span.cancel(
          attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
            'requestGeneration': DiagnosticValue.int64(generation),
            'resultState': DiagnosticValue.string('staleErrorDiscarded'),
          }),
        );
        report(DiagnosticOutcome.cancelled);
        return;
      }
      final appError = AppError.fromUnknown(error);
      state = LibraryPageState.failure(
        error: appError,
        retainedOverview: retainedOverview,
      );
      span.fail(
        attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
          'requestGeneration': DiagnosticValue.int64(generation),
          'resultState': DiagnosticValue.string('failure'),
          'errorCode': DiagnosticValue.string(appError.code.wireValue),
        }),
      );
      report(DiagnosticOutcome.error);
    }
  }

  bool _isCurrent(int generation) {
    return !_disposed && generation == _latestGeneration;
  }
}
