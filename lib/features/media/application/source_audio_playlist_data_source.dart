/// Audio-source to independent-player adapter.
///
/// Responsibilities:
/// - Expose the complete safe chapter catalog while resolving URLs on demand.
/// - Preserve proxy URLs, request headers and refresh policy as opaque data.
///
/// Notes:
/// - This is audio-only; it never creates a video group or shares player state.
/// - Locked or failed neighbouring entries never prevent a selected free track
///   from opening. Signed resources are never persisted.
library;

import 'package:mg_read_audio_player/mg_read_audio_player.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/features/discovery/application/source_content_gateway.dart';

/// Converts one audio source collection into the audio player's host port.
final class SourceAudioPlaylistDataSource implements AudioPlaylistQueueDataSource {
  SourceAudioPlaylistDataSource({
    required this.gateway,
    required this.pluginId,
    this.initialTrackId,
    this.initialDetail,
    this.initialCatalog,
  });

  final SourceContentGateway gateway;
  final String pluginId;
  final String? initialTrackId;
  final PluginContentDetail? initialDetail;
  final PluginChaptersResult? initialCatalog;

  @override
  Future<AudioPlaylist> loadPlaylist(String collectionId) async {
    final detail = initialDetail ?? await gateway.getDetail(pluginId: pluginId, id: collectionId);
    if (detail.summary.contentKind != PluginContentKind.audio) {
      throw const AudioPlayerLoadException(code: 'audio_source_kind_invalid', location: '音频详情', message: '当前内容不是可播放音频，请返回详情页后重试。');
    }
    if (detail.summary.id != collectionId) {
      throw const AudioPlayerLoadException(code: 'audio_detail_outdated', location: '音频详情', message: '当前详情已更新，请返回详情页后重新打开。');
    }
    final catalog = initialCatalog ?? await gateway.getChapters(pluginId: pluginId, id: collectionId);
    final available = _availableChapters(catalog.items);
    final candidates = _selectCandidates(available);
    if (available.isEmpty || candidates.isEmpty) {
      throw const AudioPlayerLoadException(code: 'audio_catalog_no_playable_chapter', location: '音频目录', message: '目录中没有可播放的免费章节。');
    }
    final tracks = <AudioTrack>[];
    try {
      tracks.add(await _loadTrack(detail: detail, collectionId: collectionId, chapter: candidates.first));
    } on AudioPlayerLoadException {
      rethrow;
    } on Object {
      throw const AudioPlayerLoadException(
        code: 'audio_selected_resource_unavailable',
        location: '所选章节的播放地址',
        message: '数据源未能返回可播放地址。请检查网络或稍后重试。',
      );
    }
    return AudioPlaylist(
      collectionId: collectionId,
      title: detail.summary.title,
      creator: detail.summary.author,
      tracks: tracks,
      queueEntries: <AudioQueueEntry>[
        for (final chapter in catalog.items)
          AudioQueueEntry(
            id: chapter.id,
            title: chapter.title,
            creator: detail.summary.author,
            artwork: detail.summary.coverUrl,
            isLocked: chapter.isLocked == true,
          ),
      ],
    );
  }

  List<PluginChapterSummary> _selectCandidates(List<PluginChapterSummary> catalog) {
    final available = _availableChapters(catalog);
    if (available.isEmpty) return const <PluginChapterSummary>[];
    final requestedIndex = initialTrackId == null ? 0 : available.indexWhere((chapter) => chapter.id == initialTrackId);
    // A removed or newly locked remembered chapter must not make the shelf
    // item unusable. Resume the saved chapter when it still exists; otherwise
    // start at the first currently playable chapter.
    return <PluginChapterSummary>[available[requestedIndex < 0 ? 0 : requestedIndex]];
  }

  List<PluginChapterSummary> _availableChapters(List<PluginChapterSummary> catalog) =>
      catalog.where((chapter) => chapter.isLocked != true).toList(growable: false);

  @override
  Future<AudioTrack> loadTrackById(String collectionId, {required String trackId}) async {
    final detail = initialDetail ?? await gateway.getDetail(pluginId: pluginId, id: collectionId);
    final catalog = initialCatalog ?? await gateway.getChapters(pluginId: pluginId, id: collectionId);
    PluginChapterSummary? chapter;
    for (final item in _availableChapters(catalog.items)) {
      if (item.id == trackId) {
        chapter = item;
        break;
      }
    }
    if (detail.summary.id != collectionId || detail.summary.contentKind != PluginContentKind.audio || chapter == null) {
      throw const AudioPlayerLoadException(code: 'audio_selected_chapter_unavailable', location: '所选章节', message: '所选章节已下架、锁定或不在当前目录中。');
    }
    return _loadTrack(detail: detail, collectionId: collectionId, chapter: chapter);
  }

  @override
  Future<List<AudioTrack>> loadFollowingTracks(String collectionId, {required String afterTrackId, required int limit}) async {
    if (limit <= 0) return const <AudioTrack>[];
    final detail = initialDetail ?? await gateway.getDetail(pluginId: pluginId, id: collectionId);
    if (detail.summary.id != collectionId || detail.summary.contentKind != PluginContentKind.audio) {
      return const <AudioTrack>[];
    }
    final catalog = initialCatalog ?? await gateway.getChapters(pluginId: pluginId, id: collectionId);
    final available = _availableChapters(catalog.items);
    final currentIndex = available.indexWhere((chapter) => chapter.id == afterTrackId);
    if (currentIndex < 0) return const <AudioTrack>[];
    final tracks = <AudioTrack>[];
    for (final chapter in available.skip(currentIndex + 1)) {
      if (tracks.length >= limit) break;
      try {
        tracks.add(await _loadTrack(detail: detail, collectionId: collectionId, chapter: chapter));
      } on Object {
        // Skip expired or locked-in-practice resources. The next available
        // chapter is still useful for uninterrupted sequential listening.
      }
    }
    return tracks;
  }

  Future<AudioTrack> _loadTrack({
    required PluginContentDetail detail,
    required String collectionId,
    required PluginChapterSummary chapter,
  }) async {
    final content = await gateway.getContent(pluginId: pluginId, id: collectionId, chapterId: chapter.id);
    final media = content.media;
    if (content.contentKind != PluginContentKind.audio || media == null) {
      throw const AudioPlayerLoadException(code: 'audio_resource_missing', location: '播放地址', message: '数据源没有返回该章节的可播放地址。');
    }
    return AudioTrack(
      id: chapter.id,
      title: chapter.title,
      collectionTitle: detail.summary.title,
      creator: detail.summary.author,
      resource: media.url,
      artwork: detail.summary.coverUrl,
      httpHeaders: media.headers,
    );
  }
}
