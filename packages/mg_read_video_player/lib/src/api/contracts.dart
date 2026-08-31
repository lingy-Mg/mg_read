/// Public host and backend ports for the video player.
///
/// Responsibilities:
/// - Separate host content/persistence from package-owned playback behavior.
/// - Allow deterministic fake backends without initializing native libraries.
///
/// Notes:
/// - Fullscreen, orientation, PiP and system-awake capabilities remain host-owned.
/// - Backends receive resolved URLs and headers but never host service locators.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'models.dart';

/// Resolves a stable content identifier into immutable video metadata.
abstract interface class VideoDataSource {
  /// Loads the title and ordered host-defined groups for [contentId].
  Future<VideoContent> load(String contentId);
}

/// A source whose catalog is safe to keep while playback resources are not.
///
/// Implementations return metadata-only episodes from [VideoDataSource.load]
/// and resolve one transient URL only when that episode is selected. This is
/// the preferred boundary for signed or session-owned source media.
abstract interface class VideoEpisodeDataSource implements VideoDataSource {
  /// Resolves one selected episode without preloading neighbouring resources.
  Future<VideoEpisode> loadEpisode(
    String contentId, {
    required String groupId,
    required String episodeId,
  });
}

/// Loads and durably saves semantic playback progress.
abstract interface class VideoPlaybackStateStore {
  /// Loads the last saved episode and position for [contentId].
  Future<VideoPlaybackProgress?> load(String contentId);

  /// Saves the latest semantic playback position.
  Future<void> save(VideoPlaybackProgress progress);
}

/// Optional host notifications for session events and platform intents.
class VideoPlayerObserver {
  /// Creates a no-op observer.
  const VideoPlayerObserver();

  /// Called for bounded monotonic stages on the path to first frame.
  FutureOr<void> onStartupEvent(VideoStartupEvent event) {}

  /// Called after the first real video frame becomes visible.
  FutureOr<void> onFirstFrame(VideoPlayerSnapshot snapshot) {}

  /// Called for recoverable public failures.
  FutureOr<void> onFailure(VideoPlayerFailure failure) {}

  /// Requests a host-owned fullscreen transition.
  FutureOr<void> onFullscreenRequested(bool fullscreen) {}

  /// Requests that the host leave this player route.
  FutureOr<void> onExitRequested(VideoPlaybackProgress? progress) {}
}

/// Injectable playback engine contract used by [VideoPlayerView].
abstract interface class VideoPlaybackBackend {
  /// Current engine state and subsequent updates.
  ValueListenable<VideoPlaybackBackendState> get state;

  /// Builds the engine-owned video surface without package-external controls.
  Widget buildSurface({required BoxFit fit, Key? key});

  /// Opens one resolved episode and optionally starts playback.
  ///
  /// Each open must publish `firstFrameReady: false` before a new true signal.
  Future<void> open(
    VideoEpisode episode, {
    required Duration initialPosition,
    required bool play,
  });

  /// Starts playback.
  Future<void> play();

  /// Pauses playback.
  Future<void> pause();

  /// Seeks to an absolute position.
  Future<void> seek(Duration position);

  /// Sets playback speed.
  Future<void> setRate(double rate);

  /// Sets volume in the 0–100 range.
  Future<void> setVolume(double volume);

  /// Releases all backend resources.
  Future<void> dispose();
}

/// Creates a fresh backend for one mounted player session.
typedef VideoPlaybackBackendFactory = VideoPlaybackBackend Function();
