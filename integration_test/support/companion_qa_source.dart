/// Deterministic source metadata for companion acceptance. Only the catalog is
/// synthetic; playback still traverses HTTP, the real MediaKit backend, native
/// Android output and the companion protocol.
library;

import 'package:mg_read_video_player/mg_read_video_player.dart';

final class CompanionQaVideoSource implements VideoEpisodeDataSource {
  const CompanionQaVideoSource(this.mediaUri);

  static const contentId = 'companion-qa-sintel';
  static const groupId = 'qa-group';
  static const firstEpisode = 'sample';
  static const secondEpisode = 'sample-again';
  static const unavailableEpisode = 'unavailable';
  final Uri mediaUri;

  @override
  Future<VideoContent> load(String id) async {
    if (id != contentId) throw StateError('Unexpected QA content identity: $id');
    return VideoContent(
      id: contentId,
      title: 'Companion native acceptance sample',
      groups: [
        VideoEpisodeGroup(
          id: groupId,
          title: 'QA',
          episodes: [
            VideoEpisode(id: firstEpisode, title: 'Sintel sample'),
            VideoEpisode(id: secondEpisode, title: 'Sintel second selection'),
            VideoEpisode(id: unavailableEpisode, title: 'Unavailable sample'),
          ],
        ),
      ],
    );
  }

  @override
  Future<VideoEpisode> loadEpisode(String id, {required String groupId, required String episodeId}) async {
    if (id != contentId || groupId != CompanionQaVideoSource.groupId) {
      throw StateError('Unexpected QA selection: $id/$groupId/$episodeId');
    }
    final uri = episodeId == unavailableEpisode ? mediaUri.replace(path: '${mediaUri.path}.missing') : mediaUri;
    return VideoEpisode(id: episodeId, title: episodeId, uri: uri.toString(), durationHint: const Duration(seconds: 52));
  }
}
