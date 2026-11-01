/// Timed TV seek gesture, independent of a remote's key-repeat frequency.
/// A tap seeks ten seconds; a hold accelerates at 200 ms intervals after 450 ms.
/// Only one backend seek runs at once, with intermediate targets coalesced.
/// Release commits the last target once; cancellation discards pending work.
library;

// Internal player composition, not part of the public package surface.
// ignore_for_file: public_member_api_docs

import 'dart:async';

final class VideoTvSeekGesture {
  VideoTvSeekGesture({
    required this.readPosition,
    required this.readDuration,
    required this.onSeek,
    required this.onActivity,
  });

  final Duration Function() readPosition;
  final Duration Function() readDuration;
  final Future<void> Function(Duration) onSeek;
  final void Function() onActivity;
  static const _holdDelay = Duration(milliseconds: 450);
  static const _interval = Duration(milliseconds: 200);
  Timer? _holdTimer;
  Timer? _repeatTimer;
  int _direction = 0;
  Duration? _target;
  Duration? _pending;
  Duration? _inFlight;
  bool _disposed = false;

  bool get isActive => _direction != 0;

  void press(int direction) {
    if (_disposed || direction == _direction) return;
    final start =
        _pending ?? (_target == null ? null : _inFlight) ?? readPosition();
    cancel();
    _direction = direction;
    _target = start;
    _step(10);
    if (!isActive) return;
    _holdTimer = Timer(_holdDelay, () {
      _step(10);
      if (!isActive) return;
      _repeatTimer = Timer.periodic(_interval, (timer) {
        final heldMs =
            _holdDelay.inMilliseconds + timer.tick * _interval.inMilliseconds;
        _step(switch (heldMs) {
          < 2000 => 10,
          < 4000 => 30,
          < 7000 => 60,
          _ => 120,
        });
      });
    });
  }

  void _step(int seconds) {
    if (_disposed || !isActive) return;
    final duration = readDuration();
    var next = _target! + Duration(seconds: seconds * _direction);
    if (next < Duration.zero) next = Duration.zero;
    if (duration > Duration.zero && next > duration) next = duration;
    onActivity();
    if (next == _target) {
      _stopTimers();
      return;
    }
    _target = next;
    _pending = next;
    if (_inFlight == null) unawaited(_drain());
  }

  Future<void> _drain() async {
    while (!_disposed && _pending != null) {
      final target = _pending!;
      _pending = null;
      _inFlight = target;
      try {
        await onSeek(target);
      } finally {
        _inFlight = null;
      }
    }
  }

  void release(int direction) {
    if (direction == _direction) _stopTimers();
  }

  void _stopTimers() {
    _holdTimer?.cancel();
    _repeatTimer?.cancel();
    _holdTimer = null;
    _repeatTimer = null;
    _direction = 0;
  }

  void cancel() {
    _stopTimers();
    _pending = null;
    _target = null;
  }

  void dispose() {
    cancel();
    _disposed = true;
  }
}
