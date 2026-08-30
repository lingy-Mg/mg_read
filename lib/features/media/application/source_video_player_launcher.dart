/// Video-source route launcher for the independently maintained player.
///
/// This host keeps source groups neutral, creates video playback sessions, and
/// owns their route-scoped platform fullscreen lifetime. It retains no media
/// URL, request header, cookie or Runtime state.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mg_read_video_player/mg_read_video_player.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_startup.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/media/application/source_audio_playback_coordinator.dart';
import 'package:mg_read/features/media/application/source_video_data_source.dart';
import 'package:mg_read/features/media/application/source_video_fullscreen_controller.dart';
import 'package:mg_read/features/media/application/transient_source_video_playback_state_store.dart';
import 'package:mg_read/features/media/presentation/media_entry_cover.dart';
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
  final container = ProviderScope.containerOf(context, listen: false);
  await container.read(sourceAudioPlaybackCoordinatorProvider.notifier).stop();
  if (!navigator.mounted) return;
  return navigator.push<void>(
    MaterialPageRoute<void>(
      builder: (_) => _SourceVideoPlayerDestination(
        container: container,
        navigator: navigator,
        detail: detail,
        initialGroupId: group?.id ?? 'default',
        initialEpisodeId: chapter.id,
        libraryItemId: libraryItemId,
      ),
    ),
  );
}

final class _SourceVideoPlayerDestination extends StatefulWidget {
  const _SourceVideoPlayerDestination({
    required this.container,
    required this.navigator,
    required this.detail,
    required this.initialGroupId,
    required this.initialEpisodeId,
    required this.libraryItemId,
  });

  final ProviderContainer container;
  final NavigatorState navigator;
  final PluginContentDetail detail;
  final String initialGroupId;
  final String initialEpisodeId;
  final String? libraryItemId;

  @override
  State<_SourceVideoPlayerDestination> createState() => _SourceVideoPlayerDestinationState();
}

final class _SourceVideoPlayerDestinationState extends State<_SourceVideoPlayerDestination> {
  late final SourceVideoFullscreenController _fullscreenController;
  _VideoPlayerSetup? _setup;
  Object? _setupFailure;
  bool _firstFramePresented = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _fullscreenController = SourceVideoFullscreenController();
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    final generation = ++_generation;
    setState(() {
      _setup = null;
      _setupFailure = null;
      _firstFramePresented = false;
    });
    try {
      final library = widget.libraryItemId == null ? null : await widget.container.read(appStartupControllerProvider).contentLibrary;
      final itemId = widget.libraryItemId == null ? null : LibraryItemId(widget.libraryItemId!);
      final proxyUri = widget.container.read(configuredFlutterNetworkProxyManagerProvider).playerProxyUriFor(NetworkProxyTraffic.video);
      if (!mounted || generation != _generation) return;
      setState(() => _setup = _VideoPlayerSetup(library: library, itemId: itemId, proxyUri: proxyUri));
    } on Object catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() => _setupFailure = error);
    }
  }

  void _exit() {
    if (widget.navigator.mounted && widget.navigator.canPop()) widget.navigator.pop();
  }

  void _presentPlayer() {
    if (mounted && !_firstFramePresented) setState(() => _firstFramePresented = true);
  }

  @override
  Widget build(BuildContext context) {
    final setup = _setup;
    if (setup == null) {
      return PopScope<void>(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop) _exit();
        },
        child: MediaEntryCoverSurface(
          kind: MediaEntryKind.video,
          title: widget.detail.summary.title,
          coverBytes: widget.detail.summary.coverBytes,
          failureMessage: _setupFailure == null ? null : '播放器准备失败，请重试。',
          onRetry: _setupFailure == null ? null : () => unawaited(_prepare()),
          onExit: _exit,
        ),
      );
    }
    return MediaEntryCoverTransition(
      kind: MediaEntryKind.video,
      title: widget.detail.summary.title,
      coverBytes: widget.detail.summary.coverBytes,
      presented: _firstFramePresented,
      onExit: _exit,
      child: VideoPlayerView(
        key: const Key('source-video-player'),
        contentId: widget.detail.summary.id,
        dataSource: SourceVideoDataSource(gateway: widget.container.read(sourceContentGatewayProvider), pluginId: widget.detail.pluginId),
        stateStore: TransientSourceVideoPlaybackStateStore(
          contentId: widget.detail.summary.id,
          initialGroupId: widget.initialGroupId,
          initialEpisodeId: widget.initialEpisodeId,
          library: setup.library,
          libraryItemId: setup.itemId,
        ),
        observer: _VideoEntryObserver(
          delegate: _DismissVideoPlayerObserver(widget.navigator, _fullscreenController),
          onPresented: _presentPlayer,
        ),
        backendFactory: () => createMediaKitVideoPlaybackBackend(proxyUri: setup.proxyUri),
      ),
    );
  }

  @override
  void dispose() {
    _generation++;
    unawaited(_fullscreenController.restoreAndClose());
    super.dispose();
  }
}

final class _VideoPlayerSetup {
  const _VideoPlayerSetup({required this.library, required this.itemId, required this.proxyUri});

  final ContentLibrary? library;
  final LibraryItemId? itemId;
  final Uri? proxyUri;
}

final class _VideoEntryObserver extends VideoPlayerObserver {
  const _VideoEntryObserver({required this.delegate, required this.onPresented});

  final VideoPlayerObserver delegate;
  final VoidCallback onPresented;

  @override
  FutureOr<void> onFirstFrame(VideoPlayerSnapshot snapshot) {
    onPresented();
    return delegate.onFirstFrame(snapshot);
  }

  @override
  FutureOr<void> onFailure(VideoPlayerFailure failure) {
    if (failure.kind == VideoPlayerFailureKind.data) onPresented();
    return delegate.onFailure(failure);
  }

  @override
  FutureOr<void> onFullscreenRequested(bool fullscreen) => delegate.onFullscreenRequested(fullscreen);

  @override
  FutureOr<void> onExitRequested(VideoPlaybackProgress? progress) => delegate.onExitRequested(progress);
}

final class _DismissVideoPlayerObserver extends VideoPlayerObserver {
  const _DismissVideoPlayerObserver(this._navigator, this._fullscreenController);

  final NavigatorState _navigator;
  final SourceVideoFullscreenController _fullscreenController;

  @override
  Future<void> onFullscreenRequested(bool fullscreen) => _fullscreenController.setFullscreen(fullscreen);

  @override
  Future<void> onExitRequested(VideoPlaybackProgress? progress) async {
    await _fullscreenController.restoreAndClose();
    if (_navigator.mounted && _navigator.canPop()) _navigator.pop();
  }
}
