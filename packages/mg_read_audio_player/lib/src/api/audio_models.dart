/// Immutable public models for one audio playback session.
///
/// Responsibilities:
/// - Describe host-owned tracks, queues, durable positions and UI snapshots.
/// - Keep URLs and HTTP headers typed without exposing backend objects.
///
/// Notes:
/// - Track IDs are the durable identity; queue indexes are session-only.
/// - Collections are defensively copied and made unmodifiable.
library;

import 'dart:collection';

import 'package:flutter/foundation.dart';

/// Lifetime semantics for a host-resolved media URL.
enum AudioResourcePolicy { sessionOnly, refreshable }

/// One playable audio resource supplied by the host.
@immutable
final class AudioTrack {
  AudioTrack({
    required this.id,
    required this.title,
    required this.resource,
    this.collectionTitle,
    this.creator,
    this.artwork,
    this.resourcePolicy = AudioResourcePolicy.sessionOnly,
    this.expiresAt,
    Map<String, String> httpHeaders = const <String, String>{},
  }) : assert(
         resourcePolicy == AudioResourcePolicy.refreshable || expiresAt == null,
       ),
       httpHeaders = UnmodifiableMapView<String, String>(
         Map<String, String>.of(httpHeaders),
       );

  final String id;
  final String title;
  final String? collectionTitle;
  final String? creator;
  final Uri resource;
  final Uri? artwork;
  final AudioResourcePolicy resourcePolicy;
  final DateTime? expiresAt;
  final Map<String, String> httpHeaders;
}

/// One visible queue entry. Unlike [AudioTrack], it deliberately has no media
/// URL or headers, so a complete source catalog can stay in memory safely.
@immutable
final class AudioQueueEntry {
  const AudioQueueEntry({
    required this.id,
    required this.title,
    this.creator,
    this.artwork,
    this.isLocked = false,
  });

  final String id;
  final String title;
  final String? creator;
  final Uri? artwork;
  final bool isLocked;
}

/// A host-owned ordered queue for one audio collection.
@immutable
final class AudioPlaylist {
  AudioPlaylist({
    required this.collectionId,
    required this.title,
    required List<AudioTrack> tracks,
    List<AudioQueueEntry>? queueEntries,
    this.creator,
  }) : tracks = UnmodifiableListView<AudioTrack>(
         List<AudioTrack>.of(tracks, growable: false),
       ),
       queueEntries = UnmodifiableListView<AudioQueueEntry>(
         List<AudioQueueEntry>.of(
           queueEntries ??
               tracks
                   .map(
                     (track) => AudioQueueEntry(
                       id: track.id,
                       title: track.title,
                       creator: track.creator,
                       artwork: track.artwork,
                     ),
                   )
                   .toList(growable: false),
           growable: false,
         ),
       );

  final String collectionId;
  final String title;
  final String? creator;
  final List<AudioTrack> tracks;
  final List<AudioQueueEntry> queueEntries;
}

/// Durable, queue-order-independent playback position.
@immutable
final class AudioPlaybackProgress {
  const AudioPlaybackProgress({
    required this.collectionId,
    required this.trackId,
    required this.position,
    required this.updatedAt,
  });

  final String collectionId;
  final String trackId;
  final Duration position;
  final DateTime updatedAt;
}

/// Normalized lifecycle states reported to the host.
enum AudioPlayerLifecycleState { resumed, inactive, paused, hidden, detached }

/// Stable player failure exposed to UI and host observers.
@immutable
final class AudioPlayerFailure {
  const AudioPlayerFailure({
    required this.code,
    required this.message,
    required this.location,
    this.debugDetail,
  });

  final String code;
  final String message;
  final String location;
  final String? debugDetail;
}

/// Bounded state captured at a meaningful playback-operation boundary.
@immutable
final class AudioPlayerOperationEvent {
  const AudioPlayerOperationEvent({
    required this.stage,
    required this.playbackDesired,
    required this.playing,
    required this.buffering,
    required this.resourceLoading,
    required this.completed,
    this.currentTrackId,
    this.targetTrackId,
  });

  final String stage;
  final String? currentTrackId;
  final String? targetTrackId;
  final bool playbackDesired;
  final bool playing;
  final bool buffering;
  final bool resourceLoading;
  final bool completed;
}

/// A host-supplied failure that is safe to show in the audio player.
///
/// The host must use a stable code, a user-understandable location and an
/// explanation suitable for the player UI.
final class AudioPlayerLoadException implements Exception {
  const AudioPlayerLoadException({
    required this.code,
    required this.location,
    required this.message,
    this.debugDetail,
  });

  final String code;
  final String location;
  final String message;
  final String? debugDetail;

  @override
  String toString() =>
      '$code at $location: $message${debugDetail == null ? '' : ' ($debugDetail)'}';
}

/// High-level readiness of [AudioPlayerView].
enum AudioPlayerStatus { loading, ready, error }

/// Backend-owned transport state normalized for fake injection and UI use.
@immutable
final class AudioPlaybackBackendSnapshot {
  const AudioPlaybackBackendSnapshot({
    this.playing = false,
    this.buffering = false,
    this.completed = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.rate = 1,
    this.volume = 1,
    this.currentIndex = 0,
    this.errorMessage,
  });

  final bool playing;
  final bool buffering;
  final bool completed;
  final Duration position;
  final Duration duration;
  final double rate;
  final double volume;
  final int currentIndex;
  final String? errorMessage;

  AudioPlaybackBackendSnapshot copyWith({
    bool? playing,
    bool? buffering,
    bool? completed,
    Duration? position,
    Duration? duration,
    double? rate,
    double? volume,
    int? currentIndex,
    String? errorMessage,
    bool clearError = false,
  }) => AudioPlaybackBackendSnapshot(
    playing: playing ?? this.playing,
    buffering: buffering ?? this.buffering,
    completed: completed ?? this.completed,
    position: position ?? this.position,
    duration: duration ?? this.duration,
    rate: rate ?? this.rate,
    volume: volume ?? this.volume,
    currentIndex: currentIndex ?? this.currentIndex,
    errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
  );
}

/// Read-only snapshot published by [AudioPlayerController].
@immutable
final class AudioPlayerSnapshot {
  AudioPlayerSnapshot({
    required this.status,
    required List<AudioTrack> queue,
    List<AudioQueueEntry>? queueEntries,
    this.collectionId,
    this.collectionTitle,
    this.creator,
    this.currentIndex = 0,
    this.playbackDesired = false,
    this.playing = false,
    this.buffering = false,
    this.resourceLoading = false,
    this.completed = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.rate = 1,
    this.volume = 1,
    this.sleepTimerDuration,
    this.failure,
  }) : queue = UnmodifiableListView<AudioTrack>(
         List<AudioTrack>.of(queue, growable: false),
       ),
       queueEntries = UnmodifiableListView<AudioQueueEntry>(
         List<AudioQueueEntry>.of(
           queueEntries ??
               queue
                   .map(
                     (track) => AudioQueueEntry(
                       id: track.id,
                       title: track.title,
                       creator: track.creator,
                       artwork: track.artwork,
                     ),
                   )
                   .toList(growable: false),
           growable: false,
         ),
       );

  AudioPlayerSnapshot.initial()
    : this(status: AudioPlayerStatus.loading, queue: const <AudioTrack>[]);

  final AudioPlayerStatus status;
  final String? collectionId;
  final String? collectionTitle;
  final String? creator;
  final List<AudioTrack> queue;
  final List<AudioQueueEntry> queueEntries;
  final int currentIndex;
  final bool playbackDesired;
  final bool playing;
  final bool buffering;
  final bool resourceLoading;
  final bool completed;
  final Duration position;
  final Duration duration;
  final double rate;
  final double volume;
  final Duration? sleepTimerDuration;
  final AudioPlayerFailure? failure;

  AudioTrack? get currentTrack =>
      currentIndex >= 0 && currentIndex < queue.length
      ? queue[currentIndex]
      : null;

  bool get canGoPrevious {
    final catalogIndex = _currentQueueEntryIndex;
    if (catalogIndex < 0) return currentIndex > 0;
    return queueEntries.take(catalogIndex).any((entry) => !entry.isLocked);
  }

  bool get canGoNext {
    final catalogIndex = _currentQueueEntryIndex;
    if (catalogIndex < 0) {
      return currentIndex >= 0 && currentIndex + 1 < queue.length;
    }
    return queueEntries.skip(catalogIndex + 1).any((entry) => !entry.isLocked);
  }

  int get _currentQueueEntryIndex {
    final trackId = currentTrack?.id;
    if (trackId == null) return -1;
    return queueEntries.indexWhere((entry) => entry.id == trackId);
  }

  AudioPlayerSnapshot copyWith({
    AudioPlayerStatus? status,
    String? collectionId,
    String? collectionTitle,
    String? creator,
    List<AudioTrack>? queue,
    List<AudioQueueEntry>? queueEntries,
    int? currentIndex,
    bool? playbackDesired,
    bool? playing,
    bool? buffering,
    bool? resourceLoading,
    bool? completed,
    Duration? position,
    Duration? duration,
    double? rate,
    double? volume,
    Duration? sleepTimerDuration,
    bool clearSleepTimer = false,
    AudioPlayerFailure? failure,
    bool clearFailure = false,
  }) => AudioPlayerSnapshot(
    status: status ?? this.status,
    collectionId: collectionId ?? this.collectionId,
    collectionTitle: collectionTitle ?? this.collectionTitle,
    creator: creator ?? this.creator,
    queue: queue ?? this.queue,
    queueEntries: queueEntries ?? this.queueEntries,
    currentIndex: currentIndex ?? this.currentIndex,
    playbackDesired: playbackDesired ?? this.playbackDesired,
    playing: playing ?? this.playing,
    buffering: buffering ?? this.buffering,
    resourceLoading: resourceLoading ?? this.resourceLoading,
    completed: completed ?? this.completed,
    position: position ?? this.position,
    duration: duration ?? this.duration,
    rate: rate ?? this.rate,
    volume: volume ?? this.volume,
    sleepTimerDuration: clearSleepTimer
        ? null
        : sleepTimerDuration ?? this.sleepTimerDuration,
    failure: clearFailure ? null : failure ?? this.failure,
  );
}
