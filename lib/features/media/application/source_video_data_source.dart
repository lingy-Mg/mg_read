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
    final detail = await _loadDetail(contentId);
    if (detail.summary.contentKind != PluginContentKind.video) {
      throw const VideoPlayerLoadException(
        code: 'video_content_kind_invalid',
        location: '校验视频内容类型',
        message: '数据源返回的内容不是视频。',
      );
    }
    final catalog = await _loadCatalog(contentId);
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
      throw const VideoPlayerLoadException(
        code: 'video_catalog_unavailable',
        location: '校验视频分组和选集',
        message: '数据源没有返回可播放选集，或选集数量超出当前播放器限制。',
      );
    }
    final resolvedGroups = await Future.wait<VideoEpisodeGroup>(
      groups.map((group) async {
        final episodes = await Future.wait<VideoEpisode>(
          group.episodes.map((episode) async {
            final content = await _loadEpisode(contentId, episode.id);
            final media = content.media;
            if (content.contentKind != PluginContentKind.video || media == null) {
              throw const VideoPlayerLoadException(
                code: 'video_episode_resource_missing',
                location: '解析所选集的播放资源',
                message: '数据源没有返回可播放的视频资源。',
              );
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

  Future<PluginContentDetail> _loadDetail(String contentId) async {
    try {
      return await gateway.getDetail(pluginId: pluginId, id: contentId);
    } on VideoPlayerLoadException {
      rethrow;
    } on Object {
      throw const VideoPlayerLoadException(
        code: 'video_detail_load_failed',
        location: '加载视频详情',
        message: '视频详情暂时无法加载，请检查数据源或网络后重试。',
      );
    }
  }

  Future<PluginChaptersResult> _loadCatalog(String contentId) async {
    try {
      return await gateway.getChapters(pluginId: pluginId, id: contentId);
    } on VideoPlayerLoadException {
      rethrow;
    } on Object {
      throw const VideoPlayerLoadException(
        code: 'video_catalog_load_failed',
        location: '加载视频分组和选集',
        message: '视频分组或选集暂时无法加载，请稍后重试。',
      );
    }
  }

  Future<PluginChapterContent> _loadEpisode(
    String contentId,
    String episodeId,
  ) async {
    try {
      return await gateway.getContent(
        pluginId: pluginId,
        id: contentId,
        chapterId: episodeId,
      );
    } on VideoPlayerLoadException {
      rethrow;
    } on Object {
      throw const VideoPlayerLoadException(
        code: 'video_episode_resource_load_failed',
        location: '请求选集播放资源',
        message: '所选集的播放资源暂时无法获取，请稍后重试。',
      );
    }
  }
}
