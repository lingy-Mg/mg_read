/// Route-lifetime video progress for a discovery source playback session.
///
/// The independent video player owns the session. This adapter only supplies
/// the requested neutral group/episode selection and never persists signed
/// resource URLs, headers, cookies or other Runtime session data.
library;

import 'package:mg_read_video_player/mg_read_video_player.dart';

/// Keeps one transient source-video selection and its current position.
final class TransientSourceVideoPlaybackStateStore implements VideoPlaybackStateStore {
  TransientSourceVideoPlaybackStateStore({
    required this.contentId,
    required this.initialGroupId,
    required this.initialEpisodeId,
  });

  final String contentId;
  final String initialGroupId;
  final String initialEpisodeId;
  VideoPlaybackProgress? _progress;

  @override
  Future<VideoPlaybackProgress?> load(String requestedContentId) async {
    if (requestedContentId != contentId) return null;
    return _progress ??
        VideoPlaybackProgress(
          contentId: contentId,
          groupId: initialGroupId,
          episodeId: initialEpisodeId,
          position: Duration.zero,
          duration: Duration.zero,
        );
  }

  @override
  Future<void> save(VideoPlaybackProgress progress) async {
    if (progress.contentId == contentId) _progress = progress;
  }
}
