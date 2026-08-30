/// Audio-source route launcher for the independently maintained player.
///
/// This host creates only audio playback sessions. It retains no media URL,
/// request header, cookie or other Runtime session state after route exit.
library;

import 'dart:async';
import 'dart:typed_data';

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
import 'package:mg_read/features/media/presentation/media_entry_cover.dart';
import 'package:mg_read/features/network_proxy/application/flutter_network_proxy_manager.dart';
import 'package:mg_read/features/network_proxy/application/network_proxy_settings.dart';
import 'package:mg_read/shared/presentation/widgets/async_book_cover_loader.dart';

/// Opens an audio chapter through the independent audio player.
Future<void> openTransientSourceAudioPlayer(
  BuildContext context, {
  required NavigatorState navigator,
  required PluginContentDetail detail,
  required PluginChaptersResult firstCatalogPage,
  required PluginChapterSummary chapter,
  String? libraryItemId,
}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  return navigator.push<void>(
    MaterialPageRoute<void>(
      builder: (_) => _SourceAudioPlayerDestination(
        container: container,
        navigator: navigator,
        detail: detail,
        firstCatalogPage: firstCatalogPage,
        chapter: chapter,
        libraryItemId: libraryItemId,
      ),
    ),
  );
}

final class _SourceAudioPlayerDestination extends StatefulWidget {
  const _SourceAudioPlayerDestination({
    required this.container,
    required this.navigator,
    required this.detail,
    required this.firstCatalogPage,
    required this.chapter,
    required this.libraryItemId,
  });

  final ProviderContainer container;
  final NavigatorState navigator;
  final PluginContentDetail detail;
  final PluginChaptersResult firstCatalogPage;
  final PluginChapterSummary chapter;
  final String? libraryItemId;

  @override
  State<_SourceAudioPlayerDestination> createState() => _SourceAudioPlayerDestinationState();
}

final class _SourceAudioPlayerDestinationState extends State<_SourceAudioPlayerDestination> {
  _AudioPlayerSetup? _setup;
  Object? _setupFailure;
  bool _playerPresented = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    final generation = ++_generation;
    final previous = _setup;
    setState(() {
      _setup = null;
      _setupFailure = null;
      _playerPresented = false;
    });
    previous?.controller.dispose();
    final controller = AudioPlayerController();
    try {
      final library = widget.libraryItemId == null ? null : await widget.container.read(appStartupControllerProvider).contentLibrary;
      final itemId = widget.libraryItemId == null ? null : LibraryItemId(widget.libraryItemId!);
      final savedProgress = library == null || itemId == null ? null : await library.loadAudioProgress(itemId);
      final proxyUri = await widget.container.read(configuredFlutterNetworkProxyManagerProvider).proxyUriFor(NetworkProxyTraffic.audio);
      final observer = await AndroidAudioBackgroundService.instance.attach(
        controller: controller,
        observer: _DismissAudioPlayerObserver(widget.navigator),
      );
      if (!mounted || generation != _generation) {
        await AndroidAudioBackgroundService.instance.detach(controller);
        controller.dispose();
        return;
      }
      setState(() {
        _setup = _AudioPlayerSetup(
          library: library,
          itemId: itemId,
          initialTrackId: savedProgress?.chapterId ?? widget.chapter.id,
          proxyUri: proxyUri,
          controller: controller,
          observer: observer,
        );
      });
    } on Object catch (error) {
      controller.dispose();
      if (!mounted || generation != _generation) return;
      setState(() => _setupFailure = error);
    }
  }

  void _exit() {
    if (widget.navigator.mounted && widget.navigator.canPop()) widget.navigator.pop();
  }

  void _presentPlayer() {
    if (mounted && !_playerPresented) setState(() => _playerPresented = true);
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
          kind: MediaEntryKind.audio,
          title: widget.detail.summary.title,
          coverBytes: widget.detail.summary.coverBytes,
          failureMessage: _setupFailure == null ? null : '播放器准备失败，请重试。',
          onRetry: _setupFailure == null ? null : () => unawaited(_prepare()),
          onExit: _exit,
        ),
      );
    }
    return MediaEntryCoverTransition(
      kind: MediaEntryKind.audio,
      title: widget.detail.summary.title,
      coverBytes: widget.detail.summary.coverBytes,
      presented: _playerPresented,
      onExit: _exit,
      child: AudioPlayerView(
        key: const Key('source-audio-player'),
        collectionId: widget.detail.summary.id,
        dataSource: SourceAudioPlaylistDataSource(
          gateway: widget.container.read(sourceContentGatewayProvider),
          pluginId: widget.detail.pluginId,
          initialTrackId: setup.initialTrackId,
          initialDetail: widget.detail,
          // Shelf metadata is deliberately local-first. Refresh its catalog
          // after the cover route is visible instead of blocking the tap.
          initialCatalog: widget.libraryItemId == null ? widget.firstCatalogPage : null,
        ),
        stateStore: TransientSourceAudioPlaybackStateStore(
          collectionId: widget.detail.summary.id,
          initialTrackId: setup.initialTrackId,
          library: setup.library,
          libraryItemId: setup.itemId,
        ),
        controller: setup.controller,
        proxyUri: setup.proxyUri,
        observer: _AudioEntryObserver(delegate: setup.observer, onPresented: _presentPlayer),
        artworkBuilder: (context, track) => _sourceAudioArtwork(context, track, widget.detail, libraryItemId: widget.libraryItemId),
        prefetchBatchSize: 1,
        prefetchLeadTime: const Duration(seconds: 30),
      ),
    );
  }

  @override
  void dispose() {
    _generation++;
    _setup?.controller.dispose();
    super.dispose();
  }
}

final class _AudioPlayerSetup {
  const _AudioPlayerSetup({
    required this.library,
    required this.itemId,
    required this.initialTrackId,
    required this.proxyUri,
    required this.controller,
    required this.observer,
  });

  final ContentLibrary? library;
  final LibraryItemId? itemId;
  final String initialTrackId;
  final Uri? proxyUri;
  final AudioPlayerController controller;
  final AudioPlayerObserver? observer;
}

final class _AudioEntryObserver extends AudioPlayerObserver {
  const _AudioEntryObserver({required this.delegate, required this.onPresented});

  final AudioPlayerObserver? delegate;
  final VoidCallback onPresented;

  @override
  FutureOr<void> onSessionStarted(String collectionId) {
    onPresented();
    return delegate?.onSessionStarted(collectionId);
  }

  @override
  FutureOr<void> onSessionEnded(String collectionId, AudioPlaybackProgress? progress) => delegate?.onSessionEnded(collectionId, progress);

  @override
  FutureOr<void> onTrackChanged(AudioTrack track) => delegate?.onTrackChanged(track);

  @override
  FutureOr<void> onLifecycleChanged(AudioPlayerLifecycleState state, AudioPlaybackProgress? progress) =>
      delegate?.onLifecycleChanged(state, progress);

  @override
  FutureOr<void> onFailure(AudioPlayerFailure failure) {
    onPresented();
    return delegate?.onFailure(failure);
  }

  @override
  FutureOr<void> onExitRequested(AudioPlaybackProgress? progress) => delegate?.onExitRequested(progress);
}

Widget _sourceAudioArtwork(BuildContext context, AudioTrack track, PluginContentDetail detail, {String? libraryItemId}) {
  final artwork = track.artwork;
  if (artwork == null || (artwork.scheme != 'http' && artwork.scheme != 'https')) {
    return const _SourceAudioArtworkFallback();
  }
  final request = BookCoverRequest(
    pluginId: detail.pluginId,
    pluginVersion: 'unknown',
    remoteContentId: detail.summary.id,
    coverUrl: artwork,
    legacyLibraryItemId: libraryItemId,
  );
  return Consumer(
    builder: (context, ref, _) => ref
        .watch(bookCoverBytesProvider(request))
        .when(
          data: (bytes) => bytes == null || bytes.isEmpty
              ? const _SourceAudioArtworkFallback()
              : Image.memory(Uint8List.fromList(bytes), fit: BoxFit.cover, gaplessPlayback: true),
          error: (_, _) => const _SourceAudioArtworkFallback(),
          loading: () => const _SourceAudioArtworkFallback(),
        ),
  );
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
