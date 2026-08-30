/// Audio-source to independent-player adapter.
///
/// Responsibilities:
/// - Resolve the selected track first, then a very small adjacent queue.
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
final class SourceAudioPlaylistDataSource implements AudioPlayerDataSource {
  SourceAudioPlaylistDataSource({
    required this.gateway,
    required this.pluginId,
    this.initialTrackId,
    this.initialDetail,
    this.initialCatalog,
    this.maximumTracks = 3,
  }) : assert(maximumTracks > 0 && maximumTracks <= 500);

  final SourceContentGateway gateway;
  final String pluginId;
  final String? initialTrackId;
  final PluginContentDetail? initialDetail;
  final PluginChaptersResult? initialCatalog;
  final int maximumTracks;

  @override
  Future<AudioPlaylist> loadPlaylist(String collectionId) async {
    final detail = initialDetail ??
        await gateway.getDetail(pluginId: pluginId, id: collectionId);
    if (detail.summary.contentKind != PluginContentKind.audio) {
      throw const AudioPlayerLoadException(
        code: 'audio_source_kind_invalid',
        location: '音频详情',
        message: '当前内容不是可播放音频，请返回详情页后重试。',
      );
    }
    if (detail.summary.id != collectionId) {
      throw const AudioPlayerLoadException(
        code: 'audio_detail_outdated',
        location: '音频详情',
        message: '当前详情已更新，请返回详情页后重新打开。',
      );
    }
    final catalog = initialCatalog ??
        await gateway.getChapters(pluginId: pluginId, id: collectionId);
    final candidates = _selectCandidates(catalog.items);
    if (candidates.isEmpty) {
      throw const AudioPlayerLoadException(
        code: 'audio_catalog_no_playable_chapter',
        location: '音频目录',
        message: '目录中没有可播放的免费章节。',
      );
    }
    final tracks = <AudioTrack>[];
    try {
      tracks.add(
        await _loadTrack(
          detail: detail,
          collectionId: collectionId,
          chapter: candidates.first,
        ),
      );
    } on AudioPlayerLoadException {
      rethrow;
    } on Object {
      throw const AudioPlayerLoadException(
        code: 'audio_selected_resource_unavailable',
        location: '所选章节的播放地址',
        message: '数据源未能返回可播放地址。请检查网络或稍后重试。',
      );
    }
    for (final chapter in candidates.skip(1)) {
      try {
        tracks.add(
          await _loadTrack(
            detail: detail,
            collectionId: collectionId,
            chapter: chapter,
          ),
        );
      } on Object {
        // The selected episode is already ready. Do not fail playback because
        // an adjacent item is paid, expired, or temporarily unavailable.
      }
    }
    return AudioPlaylist(
      collectionId: collectionId,
      title: detail.summary.title,
      creator: detail.summary.author,
      tracks: tracks,
    );
  }

  List<PluginChapterSummary> _selectCandidates(
    List<PluginChapterSummary> catalog,
  ) {
    final available = catalog.where((chapter) => !chapter.isLocked).toList();
    if (available.isEmpty) return const <PluginChapterSummary>[];
    final requestedIndex = initialTrackId == null
        ? 0
        : available.indexWhere((chapter) => chapter.id == initialTrackId);
    if (requestedIndex < 0) {
      throw const AudioPlayerLoadException(
        code: 'audio_selected_chapter_unavailable',
        location: '所选章节',
        message: '所选章节已锁定或不在当前目录中。',
      );
    }
    return available.skip(requestedIndex).take(maximumTracks).toList();
  }

  Future<AudioTrack> _loadTrack({
    required PluginContentDetail detail,
    required String collectionId,
    required PluginChapterSummary chapter,
  }) async {
    final content = await gateway.getContent(
      pluginId: pluginId,
      id: collectionId,
      chapterId: chapter.id,
    );
    final media = content.media;
    if (content.contentKind != PluginContentKind.audio || media == null) {
      throw const AudioPlayerLoadException(
        code: 'audio_resource_missing',
        location: '播放地址',
        message: '数据源没有返回该章节的可播放地址。',
      );
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
