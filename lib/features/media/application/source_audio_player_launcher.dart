/// Audio-source route launcher for the independently maintained player.
///
/// This host creates only audio playback sessions. It retains no media URL,
/// request header, cookie or other Runtime session state after route exit.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mg_read_audio_player/mg_read_audio_player.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_startup.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/media/application/android_audio_background_service.dart';
import 'package:mg_read/features/media/application/source_audio_playlist_data_source.dart';
import 'package:mg_read/features/media/application/transient_source_audio_playback_state_store.dart';

/// Opens an audio chapter through the independent audio player.
Future<void> openTransientSourceAudioPlayer(
  BuildContext context, {
  required NavigatorState navigator,
  required PluginContentDetail detail,
  required PluginChaptersResult firstCatalogPage,
  required PluginChapterSummary chapter,
  String? libraryItemId,
}) async {
  final container = ProviderScope.containerOf(context);
  final gateway = container.read(sourceContentGatewayProvider);
  final ContentLibrary? library = libraryItemId == null ? null : await container.read(appStartupControllerProvider).contentLibrary;
  final itemId = libraryItemId == null ? null : LibraryItemId(libraryItemId);
  final savedProgress = library == null || itemId == null ? null : await library.loadAudioProgress(itemId);
  final initialTrackId = savedProgress?.chapterId ?? chapter.id;
  final controller = AudioPlayerController();
  final observer = await AndroidAudioBackgroundService.instance.attach(
    controller: controller,
    observer: _DismissAudioPlayerObserver(navigator),
  );
  await navigator.push<void>(
    MaterialPageRoute<void>(
      builder: (_) => AudioPlayerView(
        collectionId: detail.summary.id,
        dataSource: SourceAudioPlaylistDataSource(
          gateway: gateway,
          pluginId: detail.pluginId,
          initialTrackId: initialTrackId,
          initialDetail: detail,
          initialCatalog: firstCatalogPage,
        ),
        stateStore: TransientSourceAudioPlaybackStateStore(
          collectionId: detail.summary.id,
          initialTrackId: initialTrackId,
          library: library,
          libraryItemId: itemId,
        ),
        controller: controller,
        observer: observer,
        artworkBuilder: _sourceAudioArtwork,
        prefetchBatchSize: 1,
        prefetchLeadTime: const Duration(seconds: 30),
      ),
    ),
  );
  controller.dispose();
}

Widget _sourceAudioArtwork(BuildContext context, AudioTrack track) {
  final artwork = track.artwork;
  if (artwork == null || !artwork.hasScheme) {
    return const _SourceAudioArtworkFallback();
  }
  return Image.network(artwork.toString(), fit: BoxFit.cover, errorBuilder: (_, _, _) => const _SourceAudioArtworkFallback());
}

final class _SourceAudioArtworkFallback extends StatelessWidget {
  const _SourceAudioArtworkFallback();

  @override
  Widget build(BuildContext context) => const Center(child: Icon(Icons.headphones_rounded, size: 86, color: Color(0xFFFFF7EB)));
}

final class _DismissAudioPlayerObserver extends AudioPlayerObserver {
  const _DismissAudioPlayerObserver(this._navigator);

  final NavigatorState _navigator;

  @override
  Future<void> onExitRequested(AudioPlaybackProgress? progress) async {
    if (_navigator.mounted && _navigator.canPop()) _navigator.pop();
  }
}
