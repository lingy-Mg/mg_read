/// Video-source route launcher for the independently maintained player.
///
/// This host keeps source groups neutral and creates only video playback
/// sessions. It retains no media URL, request header, cookie or Runtime state.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mg_read_video_player/mg_read_video_player.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/media/application/source_video_data_source.dart';
import 'package:mg_read/features/media/application/transient_source_video_playback_state_store.dart';

/// Opens one selected neutral video group/episode in the video player.
Future<void> openTransientSourceVideoPlayer(
  BuildContext context, {
  required NavigatorState navigator,
  required PluginContentDetail detail,
  required PluginChaptersResult firstCatalogPage,
  required PluginChapterSummary chapter,
}) async {
  final group = firstCatalogPage.groups.cast<PluginMediaGroup?>().firstWhere(
    (candidate) => candidate?.episodes.any((episode) => episode.id == chapter.id) ?? false,
    orElse: () => null,
  );
  final gateway = ProviderScope.containerOf(context).read(sourceContentGatewayProvider);
  await navigator.push<void>(
    MaterialPageRoute<void>(
      builder: (_) => VideoPlayerView(
        contentId: detail.summary.id,
        dataSource: SourceVideoDataSource(gateway: gateway, pluginId: detail.pluginId),
        stateStore: TransientSourceVideoPlaybackStateStore(
          contentId: detail.summary.id,
          initialGroupId: group?.id ?? 'default',
          initialEpisodeId: chapter.id,
        ),
        observer: _DismissVideoPlayerObserver(navigator),
      ),
    ),
  );
}

final class _DismissVideoPlayerObserver extends VideoPlayerObserver {
  const _DismissVideoPlayerObserver(this._navigator);

  final NavigatorState _navigator;

  @override
  Future<void> onExitRequested(VideoPlaybackProgress? progress) async {
    if (_navigator.mounted && _navigator.canPop()) _navigator.pop();
  }
}
