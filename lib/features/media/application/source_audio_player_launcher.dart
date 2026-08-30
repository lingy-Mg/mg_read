/// Audio-source route launcher for the independently maintained player.
///
/// This host creates only audio playback sessions. It retains no media URL,
/// request header, cookie or other Runtime session state after route exit.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mg_read_audio_player/mg_read_audio_player.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/media/application/source_audio_playlist_data_source.dart';
import 'package:mg_read/features/media/application/transient_source_audio_playback_state_store.dart';

/// Opens an audio chapter through the independent audio player.
Future<void> openTransientSourceAudioPlayer(
  BuildContext context, {
  required NavigatorState navigator,
  required PluginContentDetail detail,
  required PluginChaptersResult firstCatalogPage,
  required PluginChapterSummary chapter,
}) async {
  final gateway = ProviderScope.containerOf(context).read(sourceContentGatewayProvider);
  await navigator.push<void>(
    MaterialPageRoute<void>(
      builder: (_) => AudioPlayerView(
        collectionId: detail.summary.id,
        dataSource: SourceAudioPlaylistDataSource(
          gateway: gateway,
          pluginId: detail.pluginId,
          initialTrackId: chapter.id,
          initialDetail: detail,
          initialCatalog: firstCatalogPage,
        ),
        stateStore: TransientSourceAudioPlaybackStateStore(collectionId: detail.summary.id, initialTrackId: chapter.id),
        observer: _DismissAudioPlayerObserver(navigator),
      ),
    ),
  );
}

final class _DismissAudioPlayerObserver extends AudioPlayerObserver {
  const _DismissAudioPlayerObserver(this._navigator);

  final NavigatorState _navigator;

  @override
  Future<void> onExitRequested(AudioPlaybackProgress? progress) async {
    if (_navigator.mounted && _navigator.canPop()) _navigator.pop();
  }
}
