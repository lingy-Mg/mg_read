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
