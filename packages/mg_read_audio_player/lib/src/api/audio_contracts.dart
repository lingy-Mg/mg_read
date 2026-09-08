/// Host and backend contracts for the independent audio player.
///
/// Responsibilities:
/// - Keep content loading and durable state owned by the host.
/// - Allow deterministic fake playback backends in tests.
///
/// Notes:
/// - Implementations expose typed playback data rather than storage or native
///   player handles through these contracts.
library;

import 'dart:async';

import 'audio_models.dart';

/// Loads one ordered audio queue by stable collection identity.
abstract interface class AudioPlayerDataSource {
  Future<AudioPlaylist> loadPlaylist(String collectionId);
}

/// Optional cancellation owned by a data source with expensive in-flight I/O.
///
/// The session calls this before a newer selection/recovery supersedes an old
/// request and during close. Implementations must keep cancellation idempotent.
abstract interface class AudioPlayerCancellationDataSource {
  void cancelPendingLoads();
}

/// Optional incremental queue loader for long-running spoken-audio playlists.
///
/// The player calls this before it reaches the tail of the currently loaded
/// queue. Implementations must return only tracks after [afterTrackId], and
/// must not return the supplied track again.
abstract interface class AudioPlaylistContinuationDataSource
    implements AudioPlayerDataSource {
  Future<List<AudioTrack>> loadFollowingTracks(
    String collectionId, {
    required String afterTrackId,
    required int limit,
  });
}

/// A source that exposes its complete safe-to-cache chapter catalog while
/// resolving transient media URLs only for an explicit playback request.
abstract interface class AudioPlaylistQueueDataSource
    implements AudioPlaylistContinuationDataSource {
  Future<AudioTrack> loadTrackById(
    String collectionId, {
    required String trackId,
  });
}

/// Persists semantic audio progress without constraining host storage.
abstract interface class AudioPlaybackStateStore {
  Future<AudioPlaybackProgress?> loadProgress(String collectionId);
  Future<void> saveProgress(AudioPlaybackProgress progress);
}

/// Optional host notifications for audio session and lifecycle events.
class AudioPlayerObserver {
  const AudioPlayerObserver();

  FutureOr<void> onSessionStarted(String collectionId) {}
  FutureOr<void> onSessionEnded(
    String collectionId,
    AudioPlaybackProgress? progress,
  ) {}
  FutureOr<void> onTrackChanged(AudioTrack track) {}
  FutureOr<void> onLifecycleChanged(
    AudioPlayerLifecycleState state,
    AudioPlaybackProgress? progress,
  ) {}
  FutureOr<void> onFailure(AudioPlayerFailure failure) {}
  FutureOr<void> onOperation(AudioPlayerOperationEvent event) {}
  FutureOr<void> onExitRequested(AudioPlaybackProgress? progress) {}
}

/// Injectible transport boundary implemented by MediaKit in production.
abstract interface class AudioPlaybackBackend {
  AudioPlaybackBackendSnapshot get snapshot;
  Stream<AudioPlaybackBackendSnapshot> get snapshots;

  Future<void> open(
    List<AudioTrack> tracks, {
    required int initialIndex,
    bool play = false,
  });
  Future<void> append(List<AudioTrack> tracks);
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> setRate(double rate);
  Future<void> setVolume(double volume);
  Future<void> previous();
  Future<void> next();
  Future<void> jump(int index);
  Future<void> dispose();
}
