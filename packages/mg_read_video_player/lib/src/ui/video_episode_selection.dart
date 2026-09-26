/// Group-aware episode lookup for video restoration and switching.
///
/// Responsibilities:
/// - Resolve an episode only inside its explicit host-defined group.
/// - Fall back to the first episode in the first non-empty group.
///
/// Notes:
/// - Episode identifiers may repeat across groups and are never searched alone.
library;

// Cross-file helpers are intentionally package-private despite Dart naming.
// ignore_for_file: public_member_api_docs

import '../api/models.dart';

typedef VideoEpisodeSelection = ({
  VideoEpisodeGroup group,
  VideoEpisode episode,
});

VideoEpisodeSelection? restoredVideoSelection(
  List<VideoEpisodeGroup> groups,
  VideoPlaybackProgress? progress,
) => progress == null
    ? null
    : videoSelectionById(groups, progress.groupId, progress.episodeId);

VideoEpisodeSelection? firstPlayableVideoSelection(
  List<VideoEpisodeGroup> groups,
) {
  for (final group in groups) {
    if (group.episodes.isNotEmpty) {
      return (group: group, episode: group.episodes.first);
    }
  }
  return null;
}

VideoEpisodeSelection? videoSelectionById(
  List<VideoEpisodeGroup> groups,
  String groupId,
  String episodeId,
) {
  for (final group in groups) {
    if (group.id != groupId) continue;
    for (final episode in group.episodes) {
      if (episode.id == episodeId) return (group: group, episode: episode);
    }
    return null;
  }
  return null;
}

VideoEpisodeSelection? adjacentVideoSelection(
  List<VideoEpisodeGroup> groups,
  String? groupId,
  String? episodeId, {
  required int direction,
}) {
  if (direction != -1 && direction != 1) {
    throw ArgumentError.value(direction, 'direction', 'Must be -1 or 1.');
  }
  final groupIndex = groups.indexWhere((group) => group.id == groupId);
  if (groupIndex < 0) return null;
  final group = groups[groupIndex];
  final episodeIndex = group.episodes.indexWhere(
    (episode) => episode.id == episodeId,
  );
  if (episodeIndex < 0) return null;
  final target = episodeIndex + direction;
  if (target >= 0 && target < group.episodes.length) {
    return (group: group, episode: group.episodes[target]);
  }
  for (
    var index = groupIndex + direction;
    index >= 0 && index < groups.length;
    index += direction
  ) {
    final next = groups[index];
    // A deferred group is not an empty group: never silently skip it.
    if (next.deferred) return null;
    if (next.episodes.isNotEmpty) {
      return (
        group: next,
        episode: direction > 0 ? next.episodes.first : next.episodes.last,
      );
    }
  }
  return null;
}

Duration restorableVideoPosition(VideoPlaybackProgress? progress) {
  if (progress == null || progress.position <= Duration.zero) {
    return Duration.zero;
  }
  final duration = progress.duration;
  if (duration <= Duration.zero) return progress.position;
  final remaining = duration - progress.position;
  final ratio = progress.position.inMilliseconds / duration.inMilliseconds;
  if (remaining <= const Duration(seconds: 10) || ratio >= .95) {
    return Duration.zero;
  }
  return progress.position;
}
