/// Video-source route launcher for the independently maintained player.
///
/// This host keeps source groups neutral and creates only video playback
/// sessions. It retains no media URL, request header, cookie or Runtime state.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mg_read_video_player/mg_read_video_player.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_startup.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/media/application/source_video_data_source.dart';
import 'package:mg_read/features/media/application/transient_source_video_playback_state_store.dart';
import 'package:mg_read/features/network_proxy/application/flutter_network_proxy_manager.dart';
import 'package:mg_read/features/network_proxy/application/network_proxy_settings.dart';

/// Opens one selected neutral video group/episode in the video player.
Future<void> openTransientSourceVideoPlayer(
  BuildContext context, {
  required NavigatorState navigator,
  required PluginContentDetail detail,
  required PluginChaptersResult firstCatalogPage,
  required PluginChapterSummary chapter,
  String? libraryItemId,
}) async {
  final group = firstCatalogPage.groups.cast<PluginMediaGroup?>().firstWhere(
    (candidate) => candidate?.episodes.any((episode) => episode.id == chapter.id) ?? false,
    orElse: () => null,
  );
  final container = ProviderScope.containerOf(context);
  final gateway = container.read(sourceContentGatewayProvider);
  final ContentLibrary? library = libraryItemId == null ? null : await container.read(appStartupControllerProvider).contentLibrary;
  final itemId = libraryItemId == null ? null : LibraryItemId(libraryItemId);
  final proxyUri = await container.read(configuredFlutterNetworkProxyManagerProvider).proxyUriFor(NetworkProxyTraffic.video);
  await navigator.push<void>(
    MaterialPageRoute<void>(
      builder: (_) => VideoPlayerView(
        contentId: detail.summary.id,
        dataSource: SourceVideoDataSource(gateway: gateway, pluginId: detail.pluginId),
        stateStore: TransientSourceVideoPlaybackStateStore(
          contentId: detail.summary.id,
          initialGroupId: group?.id ?? 'default',
          initialEpisodeId: chapter.id,
          library: library,
          libraryItemId: itemId,
        ),
        observer: _DismissVideoPlayerObserver(navigator),
        backendFactory: () => createMediaKitVideoPlaybackBackend(proxyUri: proxyUri),
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
