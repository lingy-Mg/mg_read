/// Safe forwarding of playback-owned platform intents to the optional host.
library;

// Cross-file UI helpers are intentionally package-private despite Dart naming.
// ignore_for_file: public_member_api_docs

import 'dart:async';

import '../api/contracts.dart';

final class VideoPlayerHostBridge {
  VideoPlayerHostBridge(this._observer);

  VideoPlayerObserver? _observer;
  bool _playbackActive = false;

  set observer(VideoPlayerObserver? value) {
    if (identical(value, _observer)) return;
    if (_playbackActive) {
      _notifyPlaybackActive(_observer, false);
      _notifyPlaybackActive(value, true);
    }
    _observer = value;
  }

  void reportPlaybackActive(bool active) {
    if (_playbackActive == active) return;
    _playbackActive = active;
    _notifyPlaybackActive(_observer, active);
  }

  Future<double?> readBrightness() async {
    final observer = _observer;
    if (observer == null) return null;
    try {
      return await Future<double?>.sync(observer.onBrightnessReadRequested);
    } on Object {
      return null;
    }
  }

  Future<void> setBrightness(double brightness) async {
    final observer = _observer;
    if (observer == null) return;
    try {
      await Future<void>.sync(
        () => observer.onBrightnessRequested(
          brightness.clamp(0.05, 1).toDouble(),
        ),
      );
    } on Object {
      // Optional platform feedback must not replace valid playback state.
    }
  }

  void dispose() => reportPlaybackActive(false);

  void _notifyPlaybackActive(VideoPlayerObserver? observer, bool active) {
    if (observer == null) return;
    unawaited(
      Future<void>.sync(
        () => observer.onPlaybackActiveChanged(active),
      ).catchError((_) {}),
    );
  }
}
