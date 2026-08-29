/// Immutable public models for one video playback session.
///
/// Responsibilities:
/// - Describe grouped content, episodes, durable progress and visible state.
/// - Keep URLs and headers as data without exposing engine-specific objects.
///
/// Notes:
/// - Collections are defensively copied and cannot be mutated by consumers.
/// - Pixel offsets, native handles and route state are never persisted here.
library;

import 'dart:collection';

import 'package:flutter/foundation.dart';

/// One playable episode resolved by the host.
@immutable
final class VideoEpisode {
  /// Creates an immutable episode.
  VideoEpisode({
    required this.id,
    required this.title,
    required this.uri,
    Map<String, String> httpHeaders = const <String, String>{},
    this.durationHint,
  }) : assert(id != ''),
       assert(title != ''),
       assert(uri != ''),
       httpHeaders = UnmodifiableMapView<String, String>(
         Map<String, String>.of(httpHeaders),
       );

  /// Stable host-owned episode identifier.
  final String id;

  /// User-visible episode title.
  final String title;

  /// Media URI understood by the selected playback backend.
  final String uri;

  /// Request headers used only while opening this episode.
  final Map<String, String> httpHeaders;

  /// Optional duration shown before the backend reports authoritative metadata.
  final Duration? durationHint;
}

/// A host-defined grouping such as a season, source line or edition.
@immutable
final class VideoEpisodeGroup {
  /// Creates a group whose episode identifiers are unique within the group.
  VideoEpisodeGroup({
    required this.id,
    required this.title,
    required Iterable<VideoEpisode> episodes,
  }) : assert(id != ''),
       assert(title != ''),
       episodes = _uniqueEpisodes(episodes);

  /// Stable host-owned group identifier.
  final String id;

  /// User-visible group title without package-owned season/line semantics.
  final String title;

  /// Ordered playable episodes in this group.
  final List<VideoEpisode> episodes;
}

/// A titled video and its ordered host-defined groups.
@immutable
final class VideoContent {
  /// Creates immutable content returned by [VideoDataSource].
  VideoContent({
    required this.id,
    required this.title,
    required Iterable<VideoEpisodeGroup> groups,
  }) : assert(id != ''),
       assert(title != ''),
       groups = _uniqueGroups(groups);

  /// Stable host-owned content identifier.
  final String id;

  /// User-visible video title.
  final String title;

  /// Ordered host-defined groups; group identifiers are content-wide unique.
  final List<VideoEpisodeGroup> groups;
}

/// Durable semantic position for a video session.
@immutable
final class VideoPlaybackProgress {
  /// Creates progress for one content and episode pair.
  const VideoPlaybackProgress({
    required this.contentId,
    required this.groupId,
    required this.episodeId,
    required this.position,
    required this.duration,
  });

  /// Stable host-owned content identifier.
  final String contentId;

  /// Stable host-owned group identifier.
  final String groupId;

  /// Stable host-owned episode identifier.
  final String episodeId;

  /// Playback position clamped by the player before saving.
  final Duration position;

  /// Latest backend duration, or zero while unknown.
  final Duration duration;
}

/// Player surface sizing modes owned by the video UI.
enum VideoFitMode {
  /// Preserve the full image and allow letterboxing.
  contain,

  /// Fill the viewport and crop overflow.
  cover,

  /// Stretch the image to the viewport.
  stretch,
}

/// High-level loading state for [VideoPlayerSnapshot].
enum VideoPlayerStatus {
  /// Resolving content, progress or a new episode.
  loading,

  /// A playable episode is active.
  ready,

  /// The content contains no playable episodes.
  empty,

  /// The session failed and may be retried.
  failure,
}

/// Stable failure domains reported without engine exception objects.
enum VideoPlayerFailureKind {
  /// Content or episode resolution failed.
  data,

  /// Playback engine initialization or control failed.
  playback,

  /// Progress load or save failed.
  persistence,
}

/// Recoverable public failure information.
@immutable
final class VideoPlayerFailure {
  /// Creates a stable failure safe for presentation.
  const VideoPlayerFailure(this.kind, this.message, {this.code});

  /// Failure domain.
  final VideoPlayerFailureKind kind;

  /// User-visible Chinese explanation.
  final String message;

  /// Optional stable host or backend error code.
  final String? code;
}

/// Engine-facing state exposed by an injectable playback backend.
@immutable
final class VideoPlaybackBackendState {
  /// Creates one immutable backend snapshot.
  const VideoPlaybackBackendState({
    this.playing = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.buffering = false,
    this.rate = 1,
    this.volume = 100,
    this.firstFrameReady = false,
    this.errorMessage,
  });

  /// Whether media is currently playing.
  final bool playing;

  /// Current playback position.
  final Duration position;

  /// Current media duration.
  final Duration duration;

  /// Whether the backend is buffering.
  final bool buffering;

  /// Playback rate multiplier.
  final double rate;

  /// Volume in the MediaKit-compatible 0–100 range.
  final double volume;

  /// Whether this open's first real video frame has reached the surface.
  final bool firstFrameReady;

  /// Latest stable backend error message.
  final String? errorMessage;

  /// Returns a new backend state with selected fields replaced.
  VideoPlaybackBackendState copyWith({
    bool? playing,
    Duration? position,
    Duration? duration,
    bool? buffering,
    double? rate,
    double? volume,
    bool? firstFrameReady,
    String? errorMessage,
    bool clearError = false,
  }) => VideoPlaybackBackendState(
    playing: playing ?? this.playing,
    position: position ?? this.position,
    duration: duration ?? this.duration,
    buffering: buffering ?? this.buffering,
    rate: rate ?? this.rate,
    volume: volume ?? this.volume,
    firstFrameReady: firstFrameReady ?? this.firstFrameReady,
    errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
  );
}

/// Immutable state published by [VideoPlayerController].
@immutable
final class VideoPlayerSnapshot {
  /// Creates a session snapshot.
  VideoPlayerSnapshot({
    required this.status,
    required this.contentId,
    required this.title,
    required Iterable<VideoEpisodeGroup> groups,
    required this.activeGroupId,
    required this.activeEpisodeId,
    required this.position,
    required this.duration,
    required this.playing,
    required this.buffering,
    required this.firstFrameReady,
    required this.controlsVisible,
    required this.rate,
    required this.volume,
    required this.fitMode,
    required this.fullscreenRequested,
    this.failure,
  }) : groups = List<VideoEpisodeGroup>.unmodifiable(groups);

  /// Creates the unbound controller state.
  factory VideoPlayerSnapshot.initial() => VideoPlayerSnapshot(
    status: VideoPlayerStatus.loading,
    contentId: '',
    title: '',
    groups: const <VideoEpisodeGroup>[],
    activeGroupId: null,
    activeEpisodeId: null,
    position: Duration.zero,
    duration: Duration.zero,
    playing: false,
    buffering: false,
    firstFrameReady: false,
    controlsVisible: true,
    rate: 1,
    volume: 100,
    fitMode: VideoFitMode.contain,
    fullscreenRequested: false,
  );

  /// Current high-level session status.
  final VideoPlayerStatus status;

  /// Stable host-owned content identifier.
  final String contentId;

  /// Current user-visible title.
  final String title;

  /// Ordered host-defined groups for the selection sheet.
  final List<VideoEpisodeGroup> groups;

  /// Currently selected group identifier.
  final String? activeGroupId;

  /// Currently selected episode identifier.
  final String? activeEpisodeId;

  /// Current playback position.
  final Duration position;

  /// Current backend duration.
  final Duration duration;

  /// Whether the backend is playing.
  final bool playing;

  /// Whether the backend is buffering.
  final bool buffering;

  /// Whether the first real frame is visible.
  final bool firstFrameReady;

  /// Whether the package-owned chrome is visible.
  final bool controlsVisible;

  /// Playback rate multiplier.
  final double rate;

  /// Volume in the 0–100 range.
  final double volume;

  /// Current surface fit mode.
  final VideoFitMode fitMode;

  /// Latest fullscreen intent sent to the host.
  final bool fullscreenRequested;

  /// Recoverable terminal failure, when present.
  final VideoPlayerFailure? failure;
}

List<VideoEpisode> _uniqueEpisodes(Iterable<VideoEpisode> episodes) {
  final result = List<VideoEpisode>.unmodifiable(episodes);
  final ids = <String>{};
  for (final episode in result) {
    if (!ids.add(episode.id)) {
      throw ArgumentError.value(
        episode.id,
        'episodes',
        'Episode identifiers must be unique within a group.',
      );
    }
  }
  return result;
}

List<VideoEpisodeGroup> _uniqueGroups(Iterable<VideoEpisodeGroup> groups) {
  final result = List<VideoEpisodeGroup>.unmodifiable(groups);
  final ids = <String>{};
  for (final group in result) {
    if (!ids.add(group.id)) {
      throw ArgumentError.value(
        group.id,
        'groups',
        'Group identifiers must be unique within video content.',
      );
    }
  }
  return result;
}
