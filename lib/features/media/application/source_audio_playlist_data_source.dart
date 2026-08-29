/// Audio-source to independent-player adapter.
///
/// Responsibilities:
/// - Resolve a bounded, host-owned audio queue from typed Runtime content.
/// - Preserve proxy URLs, request headers and refresh policy as opaque data.
///
/// Notes:
/// - This is audio-only; it never creates a video group or shares player state.
/// - A refreshable URL is re-resolved when the player reloads this playlist.
library;

import 'package:mg_read_audio_player/mg_read_audio_player.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/features/discovery/application/source_content_gateway.dart';

/// Converts one audio source collection into the audio player's host port.
final class SourceAudioPlaylistDataSource implements AudioPlayerDataSource {
  SourceAudioPlaylistDataSource({
    required this.gateway,
    required this.pluginId,
    this.maximumTracks = 200,
  }) : assert(maximumTracks > 0 && maximumTracks <= 500);

  final SourceContentGateway gateway;
  final String pluginId;
  final int maximumTracks;

  @override
  Future<AudioPlaylist> loadPlaylist(String collectionId) async {
    final detail = await gateway.getDetail(pluginId: pluginId, id: collectionId);
    if (detail.summary.contentKind != PluginContentKind.audio) {
      throw StateError('Source content is not audio.');
    }
    final catalog = await gateway.getChapters(pluginId: pluginId, id: collectionId);
    if (catalog.items.isEmpty || catalog.items.length > maximumTracks) {
      throw StateError('Audio catalog exceeds the bounded player queue.');
    }
    final tracks = await Future.wait<AudioTrack>(
      catalog.items.map((chapter) async {
        final content = await gateway.getContent(
          pluginId: pluginId,
          id: collectionId,
          chapterId: chapter.id,
        );
        final media = content.media;
        if (content.contentKind != PluginContentKind.audio || media == null) {
          throw StateError('Source audio chapter has no playable resource.');
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
      }),
    );
    return AudioPlaylist(
      collectionId: collectionId,
      title: detail.summary.title,
      creator: detail.summary.author,
      tracks: tracks,
    );
  }
}
