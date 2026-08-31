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

import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';

/// Converts one video source item into the video player's host port.
final class SourceVideoDataSource implements VideoEpisodeDataSource {
  SourceVideoDataSource({
    required this.gateway,
    required this.pluginId,
    this.initialDetail,
    this.initialCatalog,
    this.playbackGate,
    this.maximumEpisodes = 200,
  }) : assert(maximumEpisodes > 0 && maximumEpisodes <= 500);

  final SourceContentGateway gateway;
  final String pluginId;
  final PluginContentDetail? initialDetail;
  final PluginChaptersResult? initialCatalog;
  final Future<void>? playbackGate;
  final int maximumEpisodes;
  String? _cachedContentId;
  PluginContentDetail? _cachedDetail;
  PluginChaptersResult? _cachedCatalog;

  @override
  Future<VideoContent> load(String contentId) async {
    final values = await Future.wait<Object>(<Future<Object>>[_loadDetail(contentId), _loadCatalog(contentId)]);
    final detail = values[0] as PluginContentDetail;
    if (detail.summary.contentKind != PluginContentKind.video) {
      throw const VideoPlayerLoadException(code: 'video_content_kind_invalid', location: '校验视频内容类型', message: '数据源返回的内容不是视频。');
    }
    final catalog = values[1] as PluginChaptersResult;
    final groups = _playableGroups(catalog);
    final episodeCount = groups.fold<int>(0, (total, group) => total + group.episodes.length);
    if (episodeCount == 0 || episodeCount > maximumEpisodes) {
      throw const VideoPlayerLoadException(
        code: 'video_catalog_unavailable',
        location: '校验视频分组和选集',
        message: '数据源没有返回可播放选集，或选集数量超出当前播放器限制。',
      );
    }
    return VideoContent(
      id: contentId,
      title: detail.summary.title,
      groups: <VideoEpisodeGroup>[
        for (final group in groups)
          VideoEpisodeGroup(
            id: group.id,
            title: group.title,
            episodes: <VideoEpisode>[for (final episode in group.episodes) VideoEpisode(id: episode.id, title: episode.title)],
          ),
      ],
    );
  }

  @override
  Future<VideoEpisode> loadEpisode(String contentId, {required String groupId, required String episodeId}) async {
    final catalog = await _loadCatalog(contentId);
    PluginChapterSummary? selected;
    for (final group in _playableGroups(catalog)) {
      if (group.id != groupId) continue;
      for (final episode in group.episodes) {
        if (episode.id == episodeId) {
          selected = episode;
          break;
        }
      }
      break;
    }
    if (selected == null) {
      throw const VideoPlayerLoadException(code: 'video_episode_unavailable', location: '校验所选视频', message: '所选视频已下架、锁定或不在当前目录中。');
    }
    final contentFuture = _loadEpisode(contentId, selected.id);
    final gate = playbackGate;
    if (gate != null) {
      await Future.wait<Object?>(<Future<Object?>>[contentFuture, gate]);
    }
    final content = await contentFuture;
    final media = content.media;
    if (content.chapterId != selected.id || content.contentKind != PluginContentKind.video || media == null) {
      throw const VideoPlayerLoadException(code: 'video_episode_resource_missing', location: '解析所选集的播放资源', message: '数据源没有返回可播放的视频资源。');
    }
    return VideoEpisode(id: selected.id, title: selected.title, uri: media.url.toString(), httpHeaders: media.headers);
  }

  Future<PluginContentDetail> _loadDetail(String contentId) async {
    _bindCache(contentId);
    final cached = _cachedDetail;
    if (cached != null) return cached;
    try {
      final detail = initialDetail?.summary.id == contentId ? initialDetail! : await gateway.getDetail(pluginId: pluginId, id: contentId);
      return _cachedDetail = detail;
    } on VideoPlayerLoadException {
      rethrow;
    } on Object {
      throw const VideoPlayerLoadException(code: 'video_detail_load_failed', location: '加载视频详情', message: '视频详情暂时无法加载，请检查数据源或网络后重试。');
    }
  }

  Future<PluginChaptersResult> _loadCatalog(String contentId) async {
    _bindCache(contentId);
    final cached = _cachedCatalog;
    if (cached != null) return cached;
    try {
      final catalog = initialDetail?.summary.id == contentId && initialCatalog != null
          ? initialCatalog!
          : await gateway.getChapters(pluginId: pluginId, id: contentId);
      return _cachedCatalog = catalog;
    } on VideoPlayerLoadException {
      rethrow;
    } on Object {
      throw const VideoPlayerLoadException(code: 'video_catalog_load_failed', location: '加载视频分组和选集', message: '视频分组或选集暂时无法加载，请稍后重试。');
    }
  }

  void _bindCache(String contentId) {
    if (_cachedContentId == contentId) return;
    _cachedContentId = contentId;
    _cachedDetail = null;
    _cachedCatalog = null;
  }

  List<PluginMediaGroup> _playableGroups(PluginChaptersResult catalog) {
    final groups = catalog.groups.isEmpty
        ? <PluginMediaGroup>[PluginMediaGroup(id: 'default', title: '默认分组', order: 0, episodes: catalog.items)]
        : catalog.groups;
    return <PluginMediaGroup>[
      for (final group in groups)
        if (group.episodes.any((episode) => episode.isLocked != true))
          PluginMediaGroup(
            id: group.id,
            title: group.title,
            order: group.order,
            episodes: group.episodes.where((episode) => episode.isLocked != true).toList(growable: false),
          ),
    ];
  }

  Future<PluginChapterContent> _loadEpisode(String contentId, String episodeId) async {
    try {
      return await gateway.getContent(pluginId: pluginId, id: contentId, chapterId: episodeId);
    } on VideoPlayerLoadException {
      rethrow;
    } on AppError catch (error) {
      if (error.code == AppErrorCode.sourceMediaResolutionFailed) {
        throw const VideoPlayerLoadException(
          code: 'video_external_resolver_failed',
          location: '解析外部播放地址',
          message: '外部播放地址解析失败，请稍后重试或更换线路。',
        );
      }
      throw const VideoPlayerLoadException(
        code: 'video_episode_resource_load_failed',
        location: '请求选集播放资源',
        message: '所选集的播放资源暂时无法获取，请稍后重试。',
      );
    } on Object {
      throw const VideoPlayerLoadException(
        code: 'video_episode_resource_load_failed',
        location: '请求选集播放资源',
        message: '所选集的播放资源暂时无法获取，请稍后重试。',
      );
    }
  }
}
