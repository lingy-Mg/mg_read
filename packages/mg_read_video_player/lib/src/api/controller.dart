/// Imperative controller for a mounted [VideoPlayerView].
///
/// Responsibilities:
/// - Expose explicit playback, episode, fit, fullscreen and exit commands.
/// - Publish immutable view snapshots without owning backend resources.
///
/// Notes:
/// - Commands fail when no view is attached instead of silently mutating state.
/// - A controller may be rebound after its previous view detaches.
library;

import 'package:flutter/foundation.dart';

import 'models.dart';

/// Package-internal command surface implemented by the mounted view state.
abstract interface class VideoPlayerControllerDelegate {
  /// Starts playback.
  Future<void> play();

  /// Pauses playback and flushes progress.
  Future<void> pause();

  /// Toggles playback.
  Future<void> playOrPause();

  /// Seeks to an absolute position.
  Future<void> seek(Duration position);

  /// Seeks relative to the current position.
  Future<void> skip(Duration delta);

  /// Changes playback speed.
  Future<void> setRate(double rate);

  /// Changes output volume.
  Future<void> setVolume(double volume);

  /// Opens another episode.
  Future<void> selectEpisode(String episodeId);

  /// Advances to the next fit mode.
  Future<void> cycleFitMode();

  /// Toggles package-owned controls.
  Future<void> toggleControls();

  /// Requests a host-owned fullscreen state.
  Future<void> requestFullscreen(bool fullscreen);

  /// Flushes progress and requests route exit.
  Future<void> requestExit();
}

/// Imperative command and snapshot bridge for [VideoPlayerView].
final class VideoPlayerController extends ChangeNotifier {
  /// Creates an initially unbound controller.
  VideoPlayerController() : _snapshot = VideoPlayerSnapshot.initial();

  VideoPlayerSnapshot _snapshot;
  VideoPlayerControllerDelegate? _delegate;
  Object? _owner;
  bool _disposed = false;

  /// Latest immutable state published by the mounted view.
  VideoPlayerSnapshot get snapshot => _snapshot;

  /// Starts playback.
  Future<void> play() => _requireDelegate().play();

  /// Pauses playback and flushes progress.
  Future<void> pause() => _requireDelegate().pause();

  /// Toggles playing state.
  Future<void> playOrPause() => _requireDelegate().playOrPause();

  /// Seeks to [position].
  Future<void> seek(Duration position) => _requireDelegate().seek(position);

  /// Seeks relative to the current position.
  Future<void> skip(Duration delta) => _requireDelegate().skip(delta);

  /// Sets playback speed.
  Future<void> setRate(double rate) => _requireDelegate().setRate(rate);

  /// Sets volume in the 0–100 range.
  Future<void> setVolume(double volume) => _requireDelegate().setVolume(volume);

  /// Switches to the episode identified by [episodeId].
  Future<void> selectEpisode(String episodeId) =>
      _requireDelegate().selectEpisode(episodeId);

  /// Cycles through the package-owned video fit modes.
  Future<void> cycleFitMode() => _requireDelegate().cycleFitMode();

  /// Toggles package-owned controls.
  Future<void> toggleControls() => _requireDelegate().toggleControls();

  /// Requests a host-owned fullscreen transition.
  Future<void> requestFullscreen(bool fullscreen) =>
      _requireDelegate().requestFullscreen(fullscreen);

  /// Flushes progress and requests host route exit.
  Future<void> requestExit() => _requireDelegate().requestExit();

  /// Attaches package-owned commands to this controller.
  @internal
  void attach(Object owner, VideoPlayerControllerDelegate delegate) {
    if (_disposed) {
      throw StateError('Cannot attach a disposed VideoPlayerController.');
    }
    if (_owner != null && !identical(_owner, owner)) {
      throw StateError(
        'VideoPlayerController is already attached to another view.',
      );
    }
    _owner = owner;
    _delegate = delegate;
  }

  /// Detaches commands owned by [owner].
  @internal
  void detach(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    _delegate = null;
  }

  /// Publishes state from the attached view.
  @internal
  void publish(Object owner, VideoPlayerSnapshot snapshot) {
    if (_disposed || !identical(_owner, owner)) return;
    _snapshot = snapshot;
    notifyListeners();
  }

  VideoPlayerControllerDelegate _requireDelegate() {
    final delegate = _delegate;
    if (_disposed) throw StateError('VideoPlayerController is disposed.');
    if (delegate == null) {
      throw StateError(
        'VideoPlayerController is not attached to a VideoPlayerView.',
      );
    }
    return delegate;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _owner = null;
    _delegate = null;
    super.dispose();
  }
}
