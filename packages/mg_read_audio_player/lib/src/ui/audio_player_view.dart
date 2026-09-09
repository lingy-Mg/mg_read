/// Immersive, cover-led spoken-audio player surface owned by this package.
///
/// Responsibilities:
/// - Bind either a self-managed engine or a host-owned controller to the UI.
/// - Project session state into responsive, accessible portrait components.
/// - Bridge lifecycle and route-exit intent without taking host ownership.
///
/// Notes:
/// - Content, persistence, artwork I/O and background services remain host-owned.
/// - Essential state changes stay immediate when animations are disabled.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/audio_artwork.dart';
import '../api/audio_contracts.dart';
import '../api/audio_controller.dart';
import '../api/audio_player_engine.dart';
import '../api/audio_models.dart';
import 'audio_playback_settings_sheet.dart';
import 'audio_player_artwork_stage.dart';
import 'audio_player_components.dart';
import 'audio_player_detail_sheet.dart';
import 'audio_player_observer_proxy.dart';
import 'audio_player_sheets.dart';
import 'audio_player_states.dart';
import 'audio_player_theme.dart';

/// A complete audio playback page with an independently owned design.
class AudioPlayerView extends StatefulWidget {
  const AudioPlayerView({
    required this.collectionId,
    required this.dataSource,
    required this.stateStore,
    this.observer,
    this.controller,
    this.backend,
    this.proxyUri,
    this.artworkBuilder,
    this.saveInterval = const Duration(milliseconds: 800),
    this.autoplay = true,
    this.prefetchThreshold = 1,
    this.prefetchBatchSize = 3,
    this.prefetchLeadTime,
    this.keepScreenOn = true,
    this.onKeepScreenOnChanged,
    super.key,
  }) : controlled = false;

  /// A presentation-only view for a host-owned playback engine.
  ///
  /// This constructor creates no backend, resolves no resource, and never
  /// closes [controller]. Rebuilding or disposing it cannot affect playback.
  const AudioPlayerView.controlled({
    required this.controller,
    this.artworkBuilder,
    this.keepScreenOn = true,
    this.onKeepScreenOnChanged,
    super.key,
  }) : collectionId = null,
       dataSource = null,
       stateStore = null,
       observer = null,
       backend = null,
       proxyUri = null,
       saveInterval = const Duration(milliseconds: 800),
       autoplay = true,
       prefetchThreshold = 1,
       prefetchBatchSize = 3,
       prefetchLeadTime = null,
       controlled = true;

  final String? collectionId;
  final AudioPlayerDataSource? dataSource;
  final AudioPlaybackStateStore? stateStore;
  final AudioPlayerObserver? observer;
  final AudioPlayerController? controller;

  /// Optional fake or custom backend. The view owns and disposes it.
  final AudioPlaybackBackend? backend;

  /// Optional HTTP proxy used by the default MediaKit backend.
  final Uri? proxyUri;

  /// Optional host renderer for network, file or cached artwork.
  ///
  /// When omitted, the package renders its I/O-free cover placeholder.
  final AudioArtworkBuilder? artworkBuilder;

  /// Position persistence throttle; exposed to keep tests deterministic.
  final Duration saveInterval;

  final bool autoplay;
  final int prefetchThreshold;
  final int prefetchBatchSize;
  final Duration? prefetchLeadTime;
  final bool keepScreenOn;
  final Future<void> Function(bool enabled)? onKeepScreenOnChanged;
  final bool controlled;

  @override
  State<AudioPlayerView> createState() => _AudioViewState();
}

class _AudioViewState extends State<AudioPlayerView>
    with WidgetsBindingObserver {
  late final AudioPlayerController _controller;
  late final bool _ownsController;
  AudioPlayerEngine? _engine;
  final FocusNode _focusNode = FocusNode(debugLabel: 'AudioPlayerView');
  double? _dragPositionMilliseconds;
  Future<void>? _exitRequest;
  bool _exitAuthorized = false;
  bool _motionVisible = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ownsController = !widget.controlled && widget.controller == null;
    _controller = widget.controller ?? AudioPlayerController();
    _controller.addListener(_onSessionChanged);
    if (!widget.controlled) {
      _engine = AudioPlayerEngine(
        collectionId: widget.collectionId!,
        dataSource: widget.dataSource!,
        stateStore: widget.stateStore!,
        backend: widget.backend,
        proxyUri: widget.proxyUri,
        controller: _controller,
        observer: AudioPlayerObserverProxy(
          delegate: widget.observer,
          authorizeExit: _authorizeExit,
        ),
        saveInterval: widget.saveInterval,
        autoplay: widget.autoplay,
        prefetchThreshold: widget.prefetchThreshold,
        prefetchBatchSize: widget.prefetchBatchSize,
        prefetchLeadTime: widget.prefetchLeadTime,
      );
      unawaited(_engine!.initialize());
    }
  }

  void _onSessionChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final normalized = switch (state) {
      AppLifecycleState.resumed => AudioPlayerLifecycleState.resumed,
      AppLifecycleState.inactive => AudioPlayerLifecycleState.inactive,
      AppLifecycleState.paused => AudioPlayerLifecycleState.paused,
      AppLifecycleState.hidden => AudioPlayerLifecycleState.hidden,
      AppLifecycleState.detached => AudioPlayerLifecycleState.detached,
    };
    final motionVisible = state == AppLifecycleState.resumed;
    if (_motionVisible != motionVisible && mounted) {
      setState(() => _motionVisible = motionVisible);
    }
    final engine = _engine;
    if (engine != null) unawaited(engine.handleLifecycle(normalized));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _focusNode.dispose();
    _controller.removeListener(_onSessionChanged);
    final engine = _engine;
    if (engine != null) unawaited(engine.close());
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _controller.snapshot;
    return PopScope<void>(
      canPop: _exitAuthorized,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) unawaited(_requestExit());
      },
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              unawaited(_requestExit()),
        },
        child: Focus(
          focusNode: _focusNode,
          autofocus: true,
          child: Scaffold(
            backgroundColor: AudioPlayerColors.backgroundBottom,
            body: switch (snapshot.status) {
              AudioPlayerStatus.loading => const AudioLoadingView(),
              AudioPlayerStatus.error => AudioErrorView(
                title: snapshot.failure?.code == 'audio_queue_empty'
                    ? '暂无可播放内容'
                    : '暂时无法播放',
                message: snapshot.failure?.message ?? '音频加载失败。',
                location: snapshot.failure?.location,
                diagnosticCode: snapshot.failure?.code,
                technicalDetail: snapshot.failure?.debugDetail,
                onBack: _requestExit,
                onRetry: _controller.retry,
              ),
              AudioPlayerStatus.ready => _buildReady(context, snapshot),
            },
          ),
        ),
      ),
    );
  }

  Widget _buildReady(BuildContext context, AudioPlayerSnapshot snapshot) {
    final track = snapshot.currentTrack;
    if (track == null) {
      return AudioErrorView(
        title: '暂无可播放内容',
        message: '当前章节列表为空，请返回后重新选择内容。',
        onBack: _requestExit,
        onRetry: _controller.retry,
      );
    }
    final disableAnimations =
        (MediaQuery.maybeOf(context)?.disableAnimations ?? false) ||
        !_motionVisible;
    final playbackActive = snapshot.playing && !snapshot.buffering;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        AudioPlayerArtworkBackdrop(
          track: track,
          artworkBuilder: widget.artworkBuilder,
          playing: playbackActive,
          disableAnimations: disableAnimations,
        ),
        SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final veryCompactHeight = constraints.maxHeight < 650;
              final compactHeight = constraints.maxHeight < 780;
              final horizontalPadding = constraints.maxWidth < 380
                  ? 16.0
                  : 20.0;
              final availableWidth =
                  constraints.maxWidth - horizontalPadding * 2 - 12;
              final coverSize = math.min(
                availableWidth,
                veryCompactHeight
                    ? 198.0
                    : compactHeight
                    ? 232.0
                    : 268.0,
              );
              final displayedPosition = Duration(
                milliseconds:
                    (_dragPositionMilliseconds ??
                            snapshot.position.inMilliseconds.toDouble())
                        .clamp(0, math.max(0, snapshot.duration.inMilliseconds))
                        .round(),
              );
              return ScrollConfiguration(
                behavior: ScrollConfiguration.of(
                  context,
                ).copyWith(scrollbars: false),
                child: SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(
                    horizontalPadding,
                    6,
                    horizontalPadding,
                    20,
                  ),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxWidth: AudioPlayerMetrics.pageMaxWidth,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          AudioPlayerTopBar(
                            collectionTitle:
                                track.collectionTitle ??
                                snapshot.collectionTitle,
                            queueCount: snapshot.queueEntries.length,
                            playing: snapshot.playing,
                            buffering: snapshot.buffering,
                            disableAnimations: disableAnimations,
                            onBack: _requestExit,
                            onQueue: () => showAudioQueueSheet(
                              context,
                              snapshot: snapshot,
                              controller: _controller,
                            ),
                          ),
                          if (snapshot.failure != null) ...<Widget>[
                            const SizedBox(height: 10),
                            AudioInlineFailure(
                              failure: snapshot.failure!,
                              onRetry: _controller.recover,
                            ),
                          ],
                          SizedBox(height: compactHeight ? 8 : 14),
                          Center(
                            child: AudioPlayerCover(
                              track: track,
                              artworkBuilder: widget.artworkBuilder,
                              size: coverSize,
                              currentIndex: snapshot.currentIndex,
                              playing: snapshot.playing,
                              buffering: snapshot.buffering,
                              disableAnimations: disableAnimations,
                            ),
                          ),
                          SizedBox(height: compactHeight ? 13 : 20),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: AudioPlayerMetadata(
                              snapshot: snapshot,
                              track: track,
                              onDetails: () => showAudioDetailsSheet(
                                context,
                                snapshot: snapshot,
                                controller: _controller,
                                artworkBuilder: widget.artworkBuilder,
                              ),
                            ),
                          ),
                          SizedBox(height: compactHeight ? 11 : 16),
                          Container(
                            padding: EdgeInsets.fromLTRB(
                              compactHeight ? 14 : 17,
                              compactHeight ? 12 : 16,
                              compactHeight ? 14 : 17,
                              compactHeight ? 13 : 16,
                            ),
                            decoration: BoxDecoration(
                              color: AudioPlayerColors.surface.withValues(
                                alpha: 0.96,
                              ),
                              borderRadius: BorderRadius.circular(
                                AudioPlayerMetrics.cardRadius,
                              ),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.82),
                              ),
                              boxShadow: const <BoxShadow>[
                                BoxShadow(
                                  color: AudioPlayerColors.shadow,
                                  blurRadius: 28,
                                  offset: Offset(0, 12),
                                ),
                              ],
                            ),
                            child: Column(
                              children: <Widget>[
                                AudioProgressControl(
                                  position: displayedPosition,
                                  duration: snapshot.duration,
                                  enabled: snapshot.duration > Duration.zero,
                                  playing: snapshot.playing,
                                  buffering: snapshot.buffering,
                                  dragging: _dragPositionMilliseconds != null,
                                  disableAnimations: disableAnimations,
                                  onChanged: (value) => setState(() {
                                    _dragPositionMilliseconds = value;
                                  }),
                                  onChangeEnd: (value) {
                                    setState(() {
                                      _dragPositionMilliseconds = null;
                                    });
                                    unawaited(
                                      _controller.seek(
                                        Duration(milliseconds: value.round()),
                                      ),
                                    );
                                  },
                                ),
                                SizedBox(height: compactHeight ? 6 : 9),
                                AudioTransportControls(
                                  snapshot: snapshot,
                                  disableAnimations: disableAnimations,
                                  onPrevious: _controller.previous,
                                  onBackFifteen: () => _controller.seekBy(
                                    const Duration(seconds: -15),
                                  ),
                                  onToggle: _controller.toggle,
                                  onForwardFifteen: () => _controller.seekBy(
                                    const Duration(seconds: 15),
                                  ),
                                  onNext: _controller.next,
                                ),
                              ],
                            ),
                          ),
                          SizedBox(height: compactHeight ? 9 : 11),
                          AudioSettingsLauncher(
                            snapshot: snapshot,
                            compact: compactHeight,
                            onPressed: () => showAudioPlaybackSettingsSheet(
                              context,
                              snapshot: snapshot,
                              controller: _controller,
                              keepScreenOn: widget.keepScreenOn,
                              onKeepScreenOnChanged:
                                  widget.onKeepScreenOnChanged,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _requestExit() => _exitRequest ??= _beginExitRequest();

  Future<void> _beginExitRequest() async {
    try {
      await _controller.requestExit();
      if (!widget.controlled &&
          widget.observer == null &&
          mounted &&
          _exitAuthorized) {
        await Navigator.of(context).maybePop();
      }
    } finally {
      if (mounted) {
        setState(() => _exitAuthorized = false);
        _exitRequest = null;
      }
    }
  }

  Future<bool> _authorizeExit() async {
    if (!mounted) return false;
    if (!_exitAuthorized) setState(() => _exitAuthorized = true);
    await WidgetsBinding.instance.endOfFrame;
    return mounted && _exitAuthorized;
  }
}
