/// Default MediaKit implementation of the video playback backend.
///
/// Responsibilities:
/// - Open resolved URIs with request headers and forward engine state updates.
/// - Render a raw MediaKit video surface without MediaKit-owned controls.
///
/// Notes:
/// - Native library bundles are deliberately selected by the host application.
/// - Fullscreen, orientation, PiP and system-awake behavior are disabled here.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../api/contracts.dart';
import '../api/models.dart';

/// Creates the package default backend without exposing MediaKit publicly.
VideoPlaybackBackend createMediaKitVideoPlaybackBackend() =>
    MediaKitVideoPlaybackBackend();

/// MediaKit-backed implementation used by default in production hosts.
final class MediaKitVideoPlaybackBackend implements VideoPlaybackBackend {
  /// Creates a player and its single video surface controller.
  MediaKitVideoPlaybackBackend() {
    MediaKit.ensureInitialized();
    _player = Player();
    _videoController = VideoController(_player);
    _subscriptions.addAll(<StreamSubscription<Object?>>[
      _player.stream.playing.listen(
        (bool value) => _emit(_value.copyWith(playing: value)),
      ),
      _player.stream.position.listen(
        (Duration value) => _emit(_value.copyWith(position: value)),
      ),
      _player.stream.duration.listen(
        (Duration value) => _emit(_value.copyWith(duration: value)),
      ),
      _player.stream.buffering.listen(
        (bool value) => _emit(_value.copyWith(buffering: value)),
      ),
      _player.stream.rate.listen(
        (double value) => _emit(_value.copyWith(rate: value)),
      ),
      _player.stream.volume.listen(
        (double value) => _emit(_value.copyWith(volume: value)),
      ),
      _player.stream.error.listen((String value) {
        if (value.trim().isNotEmpty) {
          _emit(_value.copyWith(errorMessage: value));
        }
      }),
    ]);
  }

  late final Player _player;
  late final VideoController _videoController;
  final ValueNotifier<VideoPlaybackBackendState> _state =
      ValueNotifier<VideoPlaybackBackendState>(
        const VideoPlaybackBackendState(),
      );
  final List<StreamSubscription<Object?>> _subscriptions =
      <StreamSubscription<Object?>>[];
  int _openGeneration = 0;
  bool _disposed = false;

  VideoPlaybackBackendState get _value => _state.value;

  @override
  ValueListenable<VideoPlaybackBackendState> get state => _state;

  @override
  Widget buildSurface({required BoxFit fit, Key? key}) => Video(
    key: key,
    controller: _videoController,
    fit: fit,
    fill: const Color(0xFF050607),
    controls: NoVideoControls,
    wakelock: false,
    pauseUponEnteringBackgroundMode: false,
    resumeUponEnteringForegroundMode: false,
    onEnterFullscreen: _noPlatformFullscreen,
    onExitFullscreen: _noPlatformFullscreen,
  );

  @override
  Future<void> open(
    VideoEpisode episode, {
    required Duration initialPosition,
    required bool play,
  }) async {
    _ensureActive();
    final generation = ++_openGeneration;
    _emit(
      VideoPlaybackBackendState(
        duration: episode.durationHint ?? Duration.zero,
        rate: _value.rate,
        volume: _value.volume,
        buffering: true,
      ),
    );
    await _player.open(
      Media(episode.uri, httpHeaders: episode.httpHeaders),
      play: false,
    );
    if (_disposed || generation != _openGeneration) return;
    if (initialPosition > Duration.zero) await _player.seek(initialPosition);
    if (_disposed || generation != _openGeneration) return;
    if (play) await _player.play();
    if (_disposed || generation != _openGeneration) return;
    _emit(_value.copyWith(buffering: false, clearError: true));
    unawaited(_markFirstFrame(generation));
  }

  Future<void> _markFirstFrame(int generation) async {
    try {
      await _videoController.waitUntilFirstFrameRendered;
      if (_disposed || generation != _openGeneration) return;
      _emit(_value.copyWith(firstFrameReady: true));
    } on Object catch (error) {
      if (_disposed || generation != _openGeneration) return;
      _emit(_value.copyWith(errorMessage: error.toString(), buffering: false));
    }
  }

  @override
  Future<void> play() async {
    _ensureActive();
    await _player.play();
  }

  @override
  Future<void> pause() async {
    if (_disposed) return;
    await _player.pause();
  }

  @override
  Future<void> seek(Duration position) async {
    _ensureActive();
    await _player.seek(position);
  }

  @override
  Future<void> setRate(double rate) async {
    _ensureActive();
    await _player.setRate(rate);
    _emit(_value.copyWith(rate: rate));
  }

  @override
  Future<void> setVolume(double volume) async {
    _ensureActive();
    await _player.setVolume(volume);
    _emit(_value.copyWith(volume: volume));
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _openGeneration++;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    await _player.dispose();
    _state.dispose();
  }

  void _emit(VideoPlaybackBackendState value) {
    if (_disposed) return;
    _state.value = value;
  }

  void _ensureActive() {
    if (_disposed) throw StateError('Video playback backend is disposed.');
  }

  static Future<void> _noPlatformFullscreen() async {}
}
