/// Video-source to independent-player adapter.
///
/// Responsibilities:
/// - Decode neutral Runtime media groups into the video player model.
/// - Resolve only proxy URLs and source-supplied request headers for playback.
/// - Load explicitly deferred groups on demand; retain three recent additional
///   whole-group catalogs and reuse the gateway's bounded shared cache.
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
final class SourceVideoDataSource implements VideoGroupDataSource {
  SourceVideoDataSource({
    required this.gateway,
    required this.pluginId,
    this.initialDetail,
    this.initialCatalog,
    this.playbackGate,
    this.maximumEpisodes = 5000,
  }) : assert(maximumEpisodes > 0 && maximumEpisodes <= 5000);

  final SourceContentGateway gateway;
  final String pluginId;
  final PluginContentDetail? initialDetail;
  final PluginChaptersResult? initialCatalog;
  final Future<void>? playbackGate;
  final int maximumEpisodes;
  String? _cachedContentId;
  PluginContentDetail? _cachedDetail;
  PluginChaptersResult? _cachedCatalog;
  final _recentGroups = <String>{};

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
    if (episodeCount == 0 || groups.any((group) => group.episodes.length > maximumEpisodes)) {
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
            deferred: group.deferred,
            episodes: <VideoEpisode>[for (final episode in group.episodes) VideoEpisode(id: episode.id, title: episode.title)],
          ),
      ],
    );
  }

  @override
  Future<VideoEpisodeGroup> loadGroup(String contentId, String groupId) async {
    var catalog = await _loadCatalog(contentId);
    var group = catalog.groups.where((value) => value.id == groupId).firstOrNull;
    if (group?.deferred == true) {
      final loader = gateway;
      if (loader is! SourceChapterGroupGateway) throw StateError('Source does not support deferred groups.');
      final result = await (loader as SourceChapterGroupGateway).getChapterGroup(pluginId: pluginId, id: contentId, groupId: groupId);
      group = result.groups.where((value) => value.id == groupId && !value.deferred).firstOrNull;
      if (group == null) throw StateError('Requested group was not returned.');
      if (_cachedContentId != contentId) throw StateError('Video content changed.');
      _recentGroups.remove(groupId);
      _recentGroups.add(groupId);
      final evicted = _recentGroups.length > 3 ? _recentGroups.first : null;
      if (evicted != null) _recentGroups.remove(evicted);
      final groups = [
        for (final old in (_cachedCatalog ?? catalog).groups)
          if (old.id == groupId)
            group
          else if (old.id == evicted)
            PluginMediaGroup(id: old.id, title: old.title, order: old.order, deferred: true, episodes: [])
          else
            old,
      ];
      catalog = PluginChaptersResult(
        pluginId: catalog.pluginId,
        sourceName: catalog.sourceName,
        groups: groups,
        items: groups.expand((value) => value.episodes).toList(),
      );
      _cachedCatalog = catalog;
    }
    if (group == null || group.episodes.length > maximumEpisodes) throw StateError('Video group is unavailable.');
    return VideoEpisodeGroup(
      id: group.id,
      title: group.title,
      episodes: [
        for (final episode in group.episodes)
          if (episode.isLocked != true) VideoEpisode(id: episode.id, title: episode.title),
      ],
    );
  }

  @override
  Future<VideoEpisode> loadEpisode(String contentId, {required String groupId, required String episodeId}) async {
    if ((await _loadCatalog(contentId)).groups.any((group) => group.id == groupId && group.deferred)) {
      await loadGroup(contentId, groupId);
    }
    final catalog = await _loadCatalog(contentId);
    PluginChapterSummary? selected;
    for (final group
        in (catalog.groups.isEmpty
            ? [PluginMediaGroup(id: 'default', title: '默认分组', order: 0, episodes: catalog.items)]
            : catalog.groups)) {
      if (group.id != groupId) continue;
      for (final episode in group.episodes) {
        if (episode.id == episodeId && episode.isLocked != true) {
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
    return VideoEpisode(
      id: selected.id,
      title: selected.title,
      uri: (await resolveSourceResource(gateway, media.url)).toString(),
      httpHeaders: media.headers,
    );
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
      final catalog = initialDetail?.summary.id == contentId && initialCatalog != null && _containsPlayableCatalogEntry(initialCatalog!)
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
    _recentGroups.clear();
  }

  bool _containsPlayableCatalogEntry(PluginChaptersResult catalog) =>
      catalog.items.isNotEmpty || catalog.groups.any((group) => group.episodes.isNotEmpty);

  List<PluginMediaGroup> _playableGroups(PluginChaptersResult catalog) {
    final groups = catalog.groups.isEmpty
        ? <PluginMediaGroup>[PluginMediaGroup(id: 'default', title: '默认分组', order: 0, episodes: catalog.items)]
        : catalog.groups;
    return <PluginMediaGroup>[
      for (final group in groups)
        if (group.deferred || group.episodes.any((episode) => episode.isLocked != true))
          PluginMediaGroup(
            id: group.id,
            title: group.title,
            order: group.order,
            deferred: group.deferred,
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
