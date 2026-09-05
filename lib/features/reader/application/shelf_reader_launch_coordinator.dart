import 'dart:async';
import 'dart:collection';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/features/reader/application/library_reader_launcher.dart';
import 'package:mg_read/features/reader/application/reader_launch_failure.dart';
import 'package:mg_read/features/reader/application/reader_launch_request.dart';

/// Visible preparation lifecycle for the one shelf item being opened.
enum ShelfReaderPreparationStatus { idle, preparing, ready, failed }

/// Small immutable state consumed by the shelf presentation.
final class ShelfReaderLaunchState {
  const ShelfReaderLaunchState._({required this.status, this.bookId, this.failure});

  const ShelfReaderLaunchState.idle() : this._(status: ShelfReaderPreparationStatus.idle);

  const ShelfReaderLaunchState.preparing(String bookId) : this._(status: ShelfReaderPreparationStatus.preparing, bookId: bookId);

  const ShelfReaderLaunchState.ready(String bookId) : this._(status: ShelfReaderPreparationStatus.ready, bookId: bookId);

  const ShelfReaderLaunchState.failed(String bookId, ReaderLaunchFailure failure)
    : this._(status: ShelfReaderPreparationStatus.failed, bookId: bookId, failure: failure);

  final ShelfReaderPreparationStatus status;
  final String? bookId;
  final ReaderLaunchFailure? failure;

  bool isPreparing(String candidate) => status == ShelfReaderPreparationStatus.preparing && bookId == candidate;
}

/// Bounded, content-free timing sample used by Profile performance probes.
final class ShelfReaderLaunchSample {
  const ShelfReaderLaunchSample({
    required this.total,
    required this.preparation,
    required this.firstPageLayout,
    required this.preparationKind,
    required this.paginationPreparation,
    required this.windowClass,
  });

  final Duration total;
  final Duration preparation;
  final Duration firstPageLayout;
  final ReaderLaunchPreparationKind preparationKind;
  final String paginationPreparation;
  final String windowClass;
}

/// A launcher may optionally warm only already-local data without networking.
abstract interface class LocalShelfReaderPrewarmer {
  Future<ReaderLaunchRequest?> warmLocal(String libraryItemId);
}

/// Owns shelf-tap preparation and the single `reader.launch` owner span.
///
/// A missing body is prepared before navigation. The ready request is handed
/// to the route once, while the owner span stays open until the reader reports
/// a frame containing actual body text or a real comic image.
final shelfReaderLaunchCoordinatorProvider = NotifierProvider<ShelfReaderLaunchCoordinator, ShelfReaderLaunchState>(
  ShelfReaderLaunchCoordinator.new,
);

final class ShelfReaderLaunchCoordinator extends Notifier<ShelfReaderLaunchState> {
  static const int _maximumWarmBooks = 3;
  static const int _maximumWarmBytes = 2 * 1024 * 1024;

  late LibraryReaderLauncher _launcher;
  late DiagnosticsManager _diagnostics;
  final Map<String, Future<bool>> _inFlight = <String, Future<bool>>{};
  final LinkedHashMap<String, ReaderLaunchRequest> _warm = LinkedHashMap<String, ReaderLaunchRequest>();
  final Map<String, _LaunchAttempt> _attempts = <String, _LaunchAttempt>{};
  int _warmBytes = 0;
  bool _disposed = false;
  ShelfReaderLaunchSample? _lastCompletedSample;

  ShelfReaderLaunchSample? get lastCompletedSample => _lastCompletedSample;

  @override
  ShelfReaderLaunchState build() {
    _launcher = ref.watch(libraryReaderLauncherProvider);
    _diagnostics = ref.watch(diagnosticsManagerProvider);
    ref.onDispose(() {
      _disposed = true;
      clear();
    });
    return const ShelfReaderLaunchState.idle();
  }

  /// Deduplicates repeated taps and prepares the target body before routing.
  Future<bool> prepare(String bookId) {
    final existing = _inFlight[bookId];
    if (existing != null) return existing;
    final ready = _attempts[bookId];
    if (ready != null && !ready.consumed) return Future<bool>.value(true);

    final task = _prepare(bookId);
    _inFlight[bookId] = task;
    return task.whenComplete(() => _inFlight.remove(bookId));
  }

  Future<bool> _prepare(String bookId) async {
    if (_disposed) return false;
    state = ShelfReaderLaunchState.preparing(bookId);
    final prior = _attempts.remove(bookId);
    prior?.cancel('superseded');
    DiagnosticSpanHandle? span;
    if (!_diagnostics.isClosed) {
      try {
        span = _diagnostics.startSpan(
          AppDiagnosticEvents.readerLaunch,
          attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
            'sourceKind': DiagnosticValue.string('shelf'),
            'resultState': DiagnosticValue.string('preparing'),
          }),
        );
      } on Object {
        // Diagnostics must never prevent an otherwise valid local launch.
      }
    }
    final attempt = _LaunchAttempt(span: span, stopwatch: Stopwatch()..start());
    _attempts[bookId] = attempt;

    final stage = _startStage(attempt, 'preparation');
    final preparationStopwatch = Stopwatch()..start();
    try {
      final warmed = _takeWarm(bookId);
      final request = warmed ?? await _launcher.launch(bookId);
      attempt.readerMode = switch (request) {
        NovelReaderLaunchRequest() => 'text',
        ComicReaderLaunchRequest() => 'comic',
      };
      attempt.preparationKind = warmed == null ? request.preparationKind : ReaderLaunchPreparationKind.memory;
      preparationStopwatch.stop();
      attempt.preparationElapsed = preparationStopwatch.elapsed;
      if (request.networkPreparationElapsed > Duration.zero) {
        final networkStage = _startStage(attempt, 'networkPreparation');
        networkStage?.complete(attributes: _stageAttributes('networkPreparation', 'success', duration: request.networkPreparationElapsed));
      }
      stage?.complete(attributes: _stageAttributes('preparation', 'success'));
      if (_disposed || _attempts[bookId] != attempt) {
        attempt.cancel('stale');
        return false;
      }
      attempt.request = request;
      state = ShelfReaderLaunchState.ready(bookId);
      return true;
    } on Object catch (error) {
      preparationStopwatch.stop();
      if (stage != null && !stage.isEnded) {
        stage.fail(attributes: _stageAttributes('preparation', 'failure', errorCode: 'reader_preparation_failed'));
      }
      final failure = ReaderLaunchFailure.fromError(error);
      attempt.fail(failure.error.code.wireValue);
      _attempts.remove(bookId);
      if (!_disposed) state = ShelfReaderLaunchState.failed(bookId, failure);
      return false;
    }
  }

  /// Returns a prepared request once. Direct/deep-link routes receive null.
  ReaderLaunchRequest? takePrepared(String bookId) {
    final attempt = _attempts[bookId];
    if (attempt == null || attempt.consumed || attempt.request == null) {
      return null;
    }
    attempt.consumed = true;
    return attempt.request;
  }

  /// Lets only the first waiter navigate after a deduplicated preparation.
  bool claimNavigation(String bookId) {
    final attempt = _attempts[bookId];
    if (attempt == null || attempt.navigationClaimed || attempt.request == null) {
      return false;
    }
    attempt.navigationClaimed = true;
    return true;
  }

  /// Starts a child stage under the tap-owned span when it exists.
  DiagnosticSpanHandle? startStage(String bookId, String stage) {
    final attempt = _attempts[bookId];
    if (attempt == null || attempt.span?.isEnded == true) return null;
    return _startStage(attempt, stage);
  }

  /// Finishes the launch only after a frame with non-empty body text.
  void completeFirstContent(
    String bookId, {
    required String preparationKind,
    required Duration firstPageLayout,
    String windowClass = 'unknown',
  }) {
    final attempt = _attempts.remove(bookId);
    if (attempt == null || attempt.span?.isEnded == true) return;
    attempt.stopwatch.stop();
    _lastCompletedSample = ShelfReaderLaunchSample(
      total: attempt.stopwatch.elapsed,
      preparation: attempt.preparationElapsed,
      firstPageLayout: firstPageLayout,
      preparationKind: attempt.preparationKind,
      paginationPreparation: preparationKind,
      windowClass: windowClass,
    );
    attempt.complete(
      DiagnosticObjectValue(<String, DiagnosticValue>{
        'readerMode': DiagnosticValue.string(attempt.readerMode),
        'sourceKind': DiagnosticValue.string('shelf'),
        'pathCategory': DiagnosticValue.string(attempt.preparationKind.wireValue),
        'cacheHit': DiagnosticValue.boolean(attempt.preparationKind != ReaderLaunchPreparationKind.network),
        'windowClass': DiagnosticValue.string(windowClass),
        'resultState': DiagnosticValue.string('firstContentFrame'),
      }),
    );
    reportSlowDiagnostic(
      _diagnostics,
      subjectComponent: 'feature.reader',
      operation: 'firstContentFrame',
      elapsed: attempt.stopwatch.elapsed,
      threshold: AppDiagnosticThresholds.readerFirstFrame,
      outcome: DiagnosticOutcome.success,
      traceContext: attempt.span?.traceContext,
    );
    if (!_disposed && state.bookId == bookId) {
      state = const ShelfReaderLaunchState.idle();
    }
  }

  void failFromReader(String bookId, String errorCode) {
    final attempt = _attempts.remove(bookId);
    attempt?.fail(errorCode);
    if (!_disposed && state.bookId == bookId) {
      state = const ShelfReaderLaunchState.idle();
    }
  }

  void cancel(String bookId, {String resultState = 'cancelled'}) {
    final attempt = _attempts.remove(bookId);
    attempt?.cancel(resultState);
    if (!_disposed && state.bookId == bookId) {
      state = const ShelfReaderLaunchState.idle();
    }
  }

  /// Low-priority, local-only, single-concurrency warm-up for up to three IDs.
  Future<void> warm(Iterable<String> bookIds) async {
    final launcher = _launcher;
    if (_disposed || launcher is! LocalShelfReaderPrewarmer) return;
    final prewarmer = launcher as LocalShelfReaderPrewarmer;
    for (final bookId in bookIds.take(_maximumWarmBooks)) {
      if (_disposed || _warm.containsKey(bookId) || _attempts.containsKey(bookId)) {
        continue;
      }
      try {
        final request = await prewarmer.warmLocal(bookId);
        if (request == null || _disposed) continue;
        _putWarm(bookId, request);
      } on Object {
        // Prewarming is best effort and never changes shelf behavior.
      }
    }
  }

  void invalidate(String bookId) {
    final request = _warm.remove(bookId);
    if (request != null) _warmBytes -= request.estimatedWarmBytes;
    cancel(bookId, resultState: 'invalidated');
  }

  void clear() {
    clearWarmCache();
    for (final attempt in _attempts.values) {
      attempt.cancel('cacheCleared');
    }
    _attempts.clear();
  }

  /// Drops only speculative requests; an active launch keeps its owner span.
  void clearWarmCache() {
    _warm.clear();
    _warmBytes = 0;
  }

  ReaderLaunchRequest? _takeWarm(String bookId) {
    final request = _warm.remove(bookId);
    if (request != null) _warmBytes -= request.estimatedWarmBytes;
    return request;
  }

  void _putWarm(String bookId, ReaderLaunchRequest request) {
    final replaced = _warm.remove(bookId);
    if (replaced != null) _warmBytes -= replaced.estimatedWarmBytes;
    _warm[bookId] = request;
    _warmBytes += request.estimatedWarmBytes;
    while (_warm.length > _maximumWarmBooks || _warmBytes > _maximumWarmBytes) {
      final oldest = _warm.keys.first;
      final removed = _warm.remove(oldest)!;
      _warmBytes -= removed.estimatedWarmBytes;
    }
  }

  DiagnosticSpanHandle? _startStage(_LaunchAttempt attempt, String stage) {
    final parent = attempt.span;
    if (_diagnostics.isClosed || parent == null || parent.isEnded) return null;
    try {
      final child = _diagnostics.startSpan(
        AppDiagnosticEvents.readerLaunchStage,
        parentContext: parent.traceContext,
        attributes: () => _stageAttributes(stage, 'started'),
      );
      attempt.children.add(child);
      return child;
    } on Object {
      return null;
    }
  }

  DiagnosticObjectValue _stageAttributes(String stage, String resultState, {String? errorCode, Duration? duration}) =>
      DiagnosticObjectValue(<String, DiagnosticValue>{
        'stage': DiagnosticValue.string(stage),
        'resultState': DiagnosticValue.string(resultState),
        if (duration != null) 'durationMicros': DiagnosticValue.int64(duration.inMicroseconds),
        if (errorCode != null) 'errorCode': DiagnosticValue.string(errorCode),
      });
}

final class _LaunchAttempt {
  _LaunchAttempt({required this.span, required this.stopwatch});

  final DiagnosticSpanHandle? span;
  final Stopwatch stopwatch;
  final Set<DiagnosticSpanHandle> children = <DiagnosticSpanHandle>{};
  ReaderLaunchRequest? request;
  bool consumed = false;
  bool navigationClaimed = false;
  ReaderLaunchPreparationKind preparationKind = ReaderLaunchPreparationKind.persistent;
  Duration preparationElapsed = Duration.zero;
  String readerMode = 'unknown';

  void complete(DiagnosticObjectValue attributes) {
    _finishChildren('ownerCompleted');
    final owner = span;
    if (owner == null || owner.isEnded) return;
    try {
      owner.complete(attributes: attributes);
    } on Object {
      // Diagnostics failure never changes the completed reader launch.
    }
  }

  void fail(String errorCode) {
    stopwatch.stop();
    _finishChildren('ownerFailed');
    final owner = span;
    if (owner == null || owner.isEnded) return;
    try {
      owner.fail(
        attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
          'readerMode': DiagnosticValue.string(readerMode),
          'sourceKind': DiagnosticValue.string('shelf'),
          'resultState': DiagnosticValue.string('failure'),
          'errorCode': DiagnosticValue.string(errorCode),
        }),
      );
    } on Object {
      // Diagnostics failure never replaces the domain failure.
    }
  }

  void cancel(String resultState) {
    stopwatch.stop();
    _finishChildren(resultState);
    final owner = span;
    if (owner == null || owner.isEnded) return;
    try {
      owner.cancel(
        attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
          'readerMode': DiagnosticValue.string(readerMode),
          'sourceKind': DiagnosticValue.string('shelf'),
          'resultState': DiagnosticValue.string(resultState),
        }),
      );
    } on Object {
      // Diagnostics failure never changes cancellation behavior.
    }
  }

  void _finishChildren(String resultState) {
    for (final child in children) {
      if (child.isEnded) continue;
      try {
        child.cancel(attributes: DiagnosticObjectValue(<String, DiagnosticValue>{'resultState': DiagnosticValue.string(resultState)}));
      } on Object {
        // Best-effort terminal cleanup for diagnostic-only child stages.
      }
    }
    children.clear();
  }
}
