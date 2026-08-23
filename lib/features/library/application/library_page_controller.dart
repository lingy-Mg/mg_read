import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/features/library/application/library_overview_loader.dart';
import 'package:mg_read/features/library/application/library_page_state.dart';
import 'package:mg_read/features/library/domain/library_item_summary.dart';
import 'package:mg_read/features/library/domain/library_overview.dart';

/// Composition port for the current feature-local library overview reader.
final libraryOverviewLoaderProvider = Provider<LibraryOverviewLoader>(
  (Ref ref) => const EmptyLibraryOverviewLoader(),
);

/// Owns the library page lifecycle and its local optimistic shelf projection.
final libraryPageControllerProvider =
    NotifierProvider<LibraryPageController, LibraryPageState>(
      LibraryPageController.new,
    );

/// Immutable-state controller with request-generation protection.
///
/// The durable overview is merged with short-lived shelf mutations so a save or
/// removal is reflected immediately. A successful background reconciliation
/// replaces that projection; a reconciliation failure deliberately keeps the
/// durable mutation outcome visible.
class LibraryPageController extends Notifier<LibraryPageState> {
  late LibraryOverviewLoader _loader;
  late DiagnosticsManager _diagnostics;
  int _latestGeneration = 0;
  bool _disposed = false;
  bool _hasLoadedBase = false;
  LibraryOverview _baseOverview = const LibraryOverview.empty();
  final Map<String, _PendingAddition> _pendingAdditions =
      <String, _PendingAddition>{};
  final Map<String, bool> _pendingRemovals = <String, bool>{};

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

  /// Immediately inserts a provisional shelf item identified by [mutationId].
  void beginAddition({
    required String mutationId,
    required LibraryItemSummary provisionalItem,
  }) {
    if (_disposed) return;
    _pendingAdditions[mutationId] = _PendingAddition(provisionalItem);
    _publishProjectedLoaded();
  }

  /// Replaces a provisional item with its durable identity and reconciles it.
  void commitAddition({
    required String mutationId,
    required LibraryItemSummary durableItem,
  }) {
    if (_disposed) return;
    _pendingAdditions[mutationId] = _PendingAddition(
      durableItem,
      committed: true,
    );
    _publishProjectedLoaded();
    unawaited(_reconcileAfterMutation());
  }

  /// Removes a failed provisional item without affecting durable shelf data.
  void rollbackAddition(String mutationId) {
    if (_disposed || _pendingAdditions.remove(mutationId) == null) return;
    _publishProjectedLoaded();
  }

  /// Hides one persisted item before its removal reaches SQLite.
  void beginRemoval(String itemId) {
    if (_disposed) return;
    _pendingRemovals[itemId] = false;
    _publishProjectedLoaded();
  }

  /// Retains the hidden item until a successful reconciliation observes it gone.
  void commitRemoval(String itemId) {
    if (_disposed || !_pendingRemovals.containsKey(itemId)) return;
    _pendingRemovals[itemId] = true;
    _publishProjectedLoaded();
    unawaited(_reconcileAfterMutation());
  }

  /// Restores an item when its persistence removal fails.
  void rollbackRemoval(String itemId) {
    if (_disposed || _pendingRemovals.remove(itemId) == null) return;
    _publishProjectedLoaded();
  }

  /// Reloads the local overview while retaining prior data when possible.
  Future<void> refresh() {
    final int generation = ++_latestGeneration;
    return _load(generation, retainedOverview: _projectedOverview());
  }

  Future<void> _reconcileAfterMutation() {
    final int generation = ++_latestGeneration;
    return _load(
      generation,
      retainedOverview: _projectedOverview(),
      preserveProjectedStateOnFailure: true,
    );
  }

  Future<void> _load(
    int generation, {
    LibraryOverview? retainedOverview,
    bool preserveProjectedStateOnFailure = false,
  }) async {
    if (!_isCurrent(generation)) return;

    final bool initialLoad = retainedOverview == null &&
        !_hasLoadedBase &&
        _pendingAdditions.isEmpty &&
        _pendingRemovals.isEmpty;
    final span = _diagnostics.startSpan(
      AppDiagnosticEvents.libraryLoad,
      attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
        'requestGeneration': DiagnosticValue.int64(generation),
        'resultState': DiagnosticValue.string(
          initialLoad ? 'initialLoading' : 'refreshing',
        ),
      }),
    );
    final stopwatch = Stopwatch()..start();
    void report(DiagnosticOutcome outcome) {
      stopwatch.stop();
      reportSlowDiagnostic(
        _diagnostics,
        subjectComponent: 'feature.library',
        operation: initialLoad ? 'initialLoad' : 'refresh',
        elapsed: stopwatch.elapsed,
        threshold: AppDiagnosticThresholds.libraryOverview,
        outcome: outcome,
        traceContext: span.traceContext,
      );
    }

    if (initialLoad) {
      state = const LibraryPageState.initialLoading();
    } else {
      state = LibraryPageState.refreshing(
        retainedOverview ?? _projectedOverview(),
      );
    }

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
      _baseOverview = overview;
      _hasLoadedBase = true;
      _discardReconciledMutations();
      final projected = _projectedOverview();
      state = LibraryPageState.loaded(projected);
      span.complete(
        attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
          'requestGeneration': DiagnosticValue.int64(generation),
          'itemCount': DiagnosticValue.int64(projected.items.length),
          'resultState': DiagnosticValue.string(
            projected.isEmpty ? 'empty' : 'content',
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
      if (preserveProjectedStateOnFailure) {
        state = LibraryPageState.loaded(_projectedOverview());
      } else {
        state = LibraryPageState.failure(
          error: appError,
          retainedOverview: retainedOverview ??
              (_hasLoadedBase ? _projectedOverview() : null),
        );
      }
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

  LibraryOverview _projectedOverview() {
    final hiddenIds = _pendingRemovals.keys.toSet();
    final items = <LibraryItemSummary>[
      for (final item in _baseOverview.items)
        if (!hiddenIds.contains(item.id)) item,
    ];
    final knownIds = items.map((item) => item.id).toSet();
    for (final pending in _pendingAdditions.values) {
      if (hiddenIds.contains(pending.item.id) || !knownIds.add(pending.item.id)) {
        continue;
      }
      items.add(pending.item);
    }
    return LibraryOverview(items: items);
  }

  void _publishProjectedLoaded() {
    if (_disposed) return;
    state = LibraryPageState.loaded(_projectedOverview());
  }

  void _discardReconciledMutations() {
    final durableIds = _baseOverview.items.map((item) => item.id).toSet();
    _pendingAdditions.removeWhere(
      (_, pending) => pending.committed && durableIds.contains(pending.item.id),
    );
    _pendingRemovals.removeWhere(
      (itemId, committed) => committed && !durableIds.contains(itemId),
    );
  }

  bool _isCurrent(int generation) =>
      !_disposed && generation == _latestGeneration;
}

final class _PendingAddition {
  const _PendingAddition(this.item, {this.committed = false});

  final LibraryItemSummary item;
  final bool committed;
}
