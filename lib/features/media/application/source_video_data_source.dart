/// Video-source to independent-player adapter.
///
/// Responsibilities:
/// - Decode neutral Runtime media groups into the video player model.
/// - Resolve only proxy URLs and source-supplied request headers for playback.
///
/// Notes:
/// - A group is not interpreted as a season, line, or edition by this host.
/// - This path is independent of the audio player and of library persistence.
library;

import 'package:mg_read_video_player/mg_read_video_player.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/features/discovery/application/source_content_gateway.dart';

/// Converts one video source item into the video player's host port.
final class SourceVideoDataSource implements VideoDataSource {
  SourceVideoDataSource({
    required this.gateway,
    required this.pluginId,
    this.maximumEpisodes = 200,
  }) : assert(maximumEpisodes > 0 && maximumEpisodes <= 500);

  final SourceContentGateway gateway;
  final String pluginId;
  final int maximumEpisodes;

  @override
  Future<VideoContent> load(String contentId) async {
    final detail = await gateway.getDetail(pluginId: pluginId, id: contentId);
    if (detail.summary.contentKind != PluginContentKind.video) {
      throw StateError('Source content is not video.');
    }
    final catalog = await gateway.getChapters(pluginId: pluginId, id: contentId);
    final groups = catalog.groups.isEmpty
        ? <PluginMediaGroup>[
            PluginMediaGroup(
              id: 'default',
              title: '默认分组',
              order: 0,
              episodes: catalog.items,
            ),
          ]
        : catalog.groups;
    final episodeCount = groups.fold<int>(0, (total, group) => total + group.episodes.length);
    if (episodeCount == 0 || episodeCount > maximumEpisodes) {
      throw StateError('Video catalog exceeds the bounded player selection.');
    }
    final resolvedGroups = await Future.wait<VideoEpisodeGroup>(
      groups.map((group) async {
        final episodes = await Future.wait<VideoEpisode>(
          group.episodes.map((episode) async {
            final content = await gateway.getContent(
              pluginId: pluginId,
              id: contentId,
              chapterId: episode.id,
            );
            final media = content.media;
            if (content.contentKind != PluginContentKind.video || media == null) {
              throw StateError('Source video episode has no playable resource.');
            }
            return VideoEpisode(
              id: episode.id,
              title: episode.title,
              uri: media.url.toString(),
              httpHeaders: media.headers,
            );
          }),
        );
        return VideoEpisodeGroup(id: group.id, title: group.title, episodes: episodes);
      }),
    );
    return VideoContent(id: contentId, title: detail.summary.title, groups: resolvedGroups);
  }
}
