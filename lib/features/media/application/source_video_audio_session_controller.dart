/// Route-scoped system audio focus and interruption handling for video.
///
/// Video playback activates a media audio session only while playing. Phone
/// calls, focus loss and unplugged headphones request a safe pause; the route
/// never resumes automatically after an interruption.
library;

import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';

@visibleForTesting
abstract interface class SourceVideoAudioSessionPlatform {
  Stream<void> get pauseRequests;

  Future<void> initialize();

  Future<bool> setActive(bool active);

  Future<void> close();
}

final class SystemSourceVideoAudioSessionPlatform implements SourceVideoAudioSessionPlatform {
  final StreamController<void> _pauseRequests = StreamController<void>.broadcast(sync: true);
  final List<StreamSubscription<Object?>> _subscriptions = <StreamSubscription<Object?>>[];
  AudioSession? _session;

  @override
  Stream<void> get pauseRequests => _pauseRequests.stream;

  @override
  Future<void> initialize() async {
    if (_session != null) return;
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());
    _session = session;
    _subscriptions.add(
      session.interruptionEventStream.listen((event) {
        if (event.begin && event.type != AudioInterruptionType.duck) {
          _pauseRequests.add(null);
        }
      }),
    );
    _subscriptions.add(session.becomingNoisyEventStream.listen((_) => _pauseRequests.add(null)));
  }

  @override
  Future<bool> setActive(bool active) async {
    await initialize();
    return _session!.setActive(active);
  }

  @override
  Future<void> close() async {
    await Future.wait<void>(_subscriptions.map((subscription) => subscription.cancel()), eagerError: false);
    _subscriptions.clear();
    await _pauseRequests.close();
  }
}

final class SourceVideoAudioSessionController {
  factory SourceVideoAudioSessionController({required Future<void> Function() onPauseRequested}) =>
      SourceVideoAudioSessionController.withPlatform(SystemSourceVideoAudioSessionPlatform(), onPauseRequested);

  @visibleForTesting
  SourceVideoAudioSessionController.withPlatform(this._platform, this._onPauseRequested) {
    _pauseSubscription = _platform.pauseRequests.listen((_) {
      if (_desiredActive && !_closed) unawaited(_onPauseRequested());
    });
  }

  final SourceVideoAudioSessionPlatform _platform;
  final Future<void> Function() _onPauseRequested;
  late final StreamSubscription<void> _pauseSubscription;

  Future<void> _tail = Future<void>.value();
  bool _desiredActive = false;
  bool _active = false;
  bool _releaseNeeded = false;
  bool _closed = false;

  Future<void> setPlaybackActive(bool active) {
    if (_closed) return Future<void>.value();
    _desiredActive = active;
    return _append(() async {
      if (_closed || (_active == _desiredActive && (_desiredActive || !_releaseNeeded))) {
        return;
      }
      final target = _desiredActive;
      if (target) _releaseNeeded = true;
      final accepted = await _platform.setActive(target);
      if (_closed) return;
      _active = target && accepted;
      if (!target || !accepted) _releaseNeeded = false;
      if (target && !accepted) unawaited(_onPauseRequested());
    });
  }

  Future<void> restoreAndClose() {
    if (_closed) return _tail;
    _closed = true;
    _desiredActive = false;
    return _append(() async {
      try {
        if (_active || _releaseNeeded) await _platform.setActive(false);
      } finally {
        _active = false;
        _releaseNeeded = false;
        await _pauseSubscription.cancel();
        await _platform.close();
      }
    });
  }

  Future<void> _append(Future<void> Function() operation) {
    final next = _tail.then<void>((_) => operation(), onError: (_, _) => operation());
    _tail = next;
    return next;
  }
}
