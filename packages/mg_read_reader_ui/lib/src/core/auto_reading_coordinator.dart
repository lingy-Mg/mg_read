import 'dart:async';

import 'package:flutter/foundation.dart';

enum ReaderAutoReadingPace {
  slow(horizontalSeconds: 8, verticalPixelsPerSecond: 18),
  normal(horizontalSeconds: 5, verticalPixelsPerSecond: 28),
  fast(horizontalSeconds: 3, verticalPixelsPerSecond: 42);

  const ReaderAutoReadingPace({
    required this.horizontalSeconds,
    required this.verticalPixelsPerSecond,
  });

  final int horizontalSeconds;
  final double verticalPixelsPerSecond;

  Duration get horizontalInterval => Duration(seconds: horizontalSeconds);
}

enum ReaderAutoReadingMode { horizontalPages, verticalScroll }

typedef ReaderAutoPageCallback = FutureOr<bool> Function();
typedef ReaderAutoScrollCallback = FutureOr<bool> Function(double delta);

/// Drives session-only automatic reading without owning reader UI state.
///
/// A callback returns false when the end of the book or another terminal state
/// is reached. Exceptions are reported through [onError] and stop the session.
class ReaderAutoReadingCoordinator {
  ReaderAutoReadingCoordinator({
    required this.onNextPage,
    required this.onScrollBy,
    this.onRunningChanged,
    this.onError,
  });

  static const Duration _verticalTick = Duration(milliseconds: 40);

  final ReaderAutoPageCallback onNextPage;
  final ReaderAutoScrollCallback onScrollBy;
  final ValueChanged<bool>? onRunningChanged;
  final ValueChanged<Object>? onError;

  Timer? _timer;
  Stopwatch? _verticalClock;
  Duration _lastVerticalElapsed = Duration.zero;
  int _generation = 0;
  bool _callbackActive = false;
  bool _disposed = false;
  ReaderAutoReadingMode? _mode;
  ReaderAutoReadingPace _pace = ReaderAutoReadingPace.normal;

  bool get isRunning => _mode != null;
  ReaderAutoReadingMode? get mode => _mode;
  ReaderAutoReadingPace get pace => _pace;

  void startHorizontal({
    ReaderAutoReadingPace pace = ReaderAutoReadingPace.normal,
  }) {
    if (_disposed) return;
    _restart(ReaderAutoReadingMode.horizontalPages, pace);
    final int generation = _generation;
    _armHorizontal(generation);
    _notifyRunning(true);
  }

  void _armHorizontal(int generation) {
    if (!_isCurrent(generation) ||
        _mode != ReaderAutoReadingMode.horizontalPages) {
      return;
    }
    _timer?.cancel();
    _timer = Timer(_pace.horizontalInterval, () {
      _timer = null;
      unawaited(_advancePage(generation));
    });
  }

  void startVertical({
    ReaderAutoReadingPace pace = ReaderAutoReadingPace.normal,
  }) {
    if (_disposed) return;
    _restart(ReaderAutoReadingMode.verticalScroll, pace);
    final Stopwatch clock = Stopwatch()..start();
    _verticalClock = clock;
    _lastVerticalElapsed = Duration.zero;
    final int generation = _generation;
    _timer = Timer.periodic(
      _verticalTick,
      (_) => unawaited(_scroll(generation, clock)),
    );
    _notifyRunning(true);
  }

  void stop() {
    if (!isRunning && _mode == null) return;
    _generation++;
    _timer?.cancel();
    _timer = null;
    _verticalClock?.stop();
    _verticalClock = null;
    _lastVerticalElapsed = Duration.zero;
    _callbackActive = false;
    _mode = null;
    _notifyRunning(false);
  }

  void dispose() {
    if (_disposed) return;
    stop();
    _disposed = true;
  }

  void _restart(ReaderAutoReadingMode mode, ReaderAutoReadingPace pace) {
    stop();
    _generation++;
    _mode = mode;
    _pace = pace;
  }

  Future<void> _advancePage(int generation) async {
    if (!_canRun(generation)) return;
    _callbackActive = true;
    try {
      final bool shouldContinue = await onNextPage();
      if (!_isCurrent(generation)) return;
      if (!shouldContinue) {
        stop();
      } else {
        _callbackActive = false;
        _armHorizontal(generation);
      }
    } catch (error) {
      if (!_isCurrent(generation)) return;
      _reportError(error);
      stop();
    } finally {
      if (_isCurrent(generation)) _callbackActive = false;
    }
  }

  Future<void> _scroll(int generation, Stopwatch clock) async {
    if (!_canRun(generation)) return;
    final Duration elapsed = clock.elapsed;
    final Duration step = elapsed - _lastVerticalElapsed;
    _lastVerticalElapsed = elapsed;
    final double delta =
        _pace.verticalPixelsPerSecond * step.inMicroseconds / 1000000;
    if (delta <= 0) return;

    _callbackActive = true;
    try {
      final bool shouldContinue = await onScrollBy(delta);
      if (!_isCurrent(generation)) return;
      if (!shouldContinue) stop();
    } catch (error) {
      if (!_isCurrent(generation)) return;
      _reportError(error);
      stop();
    } finally {
      if (_isCurrent(generation)) {
        _callbackActive = false;
        _lastVerticalElapsed = clock.elapsed;
      }
    }
  }

  bool _canRun(int generation) =>
      _isCurrent(generation) && isRunning && !_callbackActive;

  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  void _notifyRunning(bool running) {
    try {
      onRunningChanged?.call(running);
    } catch (error, stackTrace) {
      debugPrint(
        'novel_reader_ui auto-reading state callback failed: '
        '$error\n$stackTrace',
      );
    }
  }

  void _reportError(Object error) {
    try {
      onError?.call(error);
    } catch (callbackError, stackTrace) {
      debugPrint(
        'novel_reader_ui auto-reading error callback failed: '
        '$callbackError\n$stackTrace',
      );
    }
  }
}
