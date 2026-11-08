/// Immersive, cover-led spoken-audio player surface owned by this package.
///
/// Responsibilities:
/// - Bind either a self-managed engine or a host-owned controller to the UI.
/// - Project session state into responsive, accessible portrait components.
/// - Bridge lifecycle and route-exit intent without taking host ownership.
///
/// Notes:
/// - Content, persistence, artwork I/O and background services remain host-owned.
/// - Remember-position controls are exposed only with a host change callback.
/// - Essential state changes stay immediate when animations are disabled.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
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
import 'audio_player_layout.dart';
import 'audio_player_observer_proxy.dart';
import 'audio_player_sheets.dart';
import 'audio_player_states.dart';
import 'audio_player_theme.dart';

const _audioPlayerSystemUiStyle = SystemUiOverlayStyle(
  statusBarColor: Colors.transparent,
  statusBarIconBrightness: Brightness.light,
  statusBarBrightness: Brightness.dark,
  systemNavigationBarColor: Colors.transparent,
  systemNavigationBarDividerColor: Colors.transparent,
  systemNavigationBarIconBrightness: Brightness.light,
  systemStatusBarContrastEnforced: false,
  systemNavigationBarContrastEnforced: false,
);

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
    this.queueArtworkBuilder,
    this.resourceUrlDecoder,
    this.saveInterval = const Duration(milliseconds: 800),
    this.autoplay = true,
    this.prefetchThreshold = 1,
    this.prefetchBatchSize = 3,
    this.prefetchLeadTime,
    this.keepScreenOn = true,
    this.onKeepScreenOnChanged,
    this.rememberPosition = true,
    this.onRememberPositionChanged,
    super.key,
  }) : controlled = false;

  /// A presentation-only view for a host-owned playback engine.
  ///
  /// This constructor creates no backend, resolves no resource, and never
  /// closes [controller]. Rebuilding or disposing it cannot affect playback.
  const AudioPlayerView.controlled({
    required this.controller,
    this.artworkBuilder,
    this.queueArtworkBuilder,
    this.resourceUrlDecoder,
    this.keepScreenOn = true,
    this.onKeepScreenOnChanged,
    this.rememberPosition = true,
    this.onRememberPositionChanged,
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
  final AudioQueueArtworkBuilder? queueArtworkBuilder;

  /// Optional host callback for inspecting Runtime-generated resource URLs.
  final AudioResourceUrlDecoder? resourceUrlDecoder;

  /// Position persistence throttle; exposed to keep tests deterministic.
  final Duration saveInterval;

  final bool autoplay;
  final int prefetchThreshold;
  final int prefetchBatchSize;
  final Duration? prefetchLeadTime;
  final bool keepScreenOn;
  final Future<void> Function(bool enabled)? onKeepScreenOnChanged;

  /// Host-owned durable progress preference; does not alter session recovery.
  final bool rememberPosition;
  final Future<void> Function(bool enabled)? onRememberPositionChanged;
  final bool controlled;

  @override
  State<AudioPlayerView> createState() => _AudioViewState();
}

class _AudioViewState extends State<AudioPlayerView>
    with WidgetsBindingObserver {
  late final AudioPlayerController _controller;
  late final bool _ownsController;
  late AudioPlayerSnapshot _surfaceSnapshot;
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
    _surfaceSnapshot = _controller.snapshot;
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
    if (!mounted) return;
    final next = _controller.snapshot;
    if (!_requiresSurfaceRebuild(_surfaceSnapshot, next)) return;
    setState(() => _surfaceSnapshot = next);
  }

  bool _requiresSurfaceRebuild(
    AudioPlayerSnapshot previous,
    AudioPlayerSnapshot next,
  ) =>
      previous.status != next.status ||
      previous.collectionId != next.collectionId ||
      previous.collectionTitle != next.collectionTitle ||
      previous.creator != next.creator ||
      previous.currentIndex != next.currentIndex ||
      previous.playbackDesired != next.playbackDesired ||
      previous.playing != next.playing ||
      previous.buffering != next.buffering ||
      previous.resourceLoading != next.resourceLoading ||
      previous.completed != next.completed ||
      previous.duration != next.duration ||
      previous.rate != next.rate ||
      previous.volume != next.volume ||
      previous.sleepTimerDuration != next.sleepTimerDuration ||
      previous.failure != next.failure ||
      !listEquals(previous.queue, next.queue) ||
      !listEquals(previous.queueEntries, next.queueEntries);

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
    final snapshot = _surfaceSnapshot;
    return Theme(
      data: audioPlayerTheme(Theme.of(context)),
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: _audioPlayerSystemUiStyle,
        child: PopScope<void>(
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
                // Modal routes must capture the player theme, including when
                // the host uses a light theme or custom IconButton defaults.
                body: Builder(
                  builder: (context) => switch (snapshot.status) {
                    AudioPlayerStatus.loading => AudioLoadingView(
                      onBack: _requestExit,
                    ),
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
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        AudioPlayerArtworkBackdrop(
          track: track,
          artworkBuilder: widget.artworkBuilder,
          disableAnimations: disableAnimations,
        ),
        AudioPlayerLayout(
          topBar: AudioPlayerTopBar(
            collectionTitle: track.collectionTitle ?? snapshot.collectionTitle,
            playing: snapshot.playing,
            buffering: snapshot.buffering || snapshot.resourceLoading,
            disableAnimations: disableAnimations,
            onBack: _requestExit,
            onDetails: () => _showDetails(context, snapshot),
          ),
          failure: snapshot.failure == null
              ? null
              : AudioInlineFailure(
                  failure: snapshot.failure!,
                  onRetry: _controller.recover,
                ),
          coverBuilder: (size) => AudioPlayerCover(
            track: track,
            artworkBuilder: widget.artworkBuilder,
            size: size,
            currentIndex: snapshot.currentIndex,
            disableAnimations: disableAnimations,
          ),
          metadata: AudioPlayerMetadata(
            snapshot: snapshot,
            track: track,
            onDetails: () => _showDetails(context, snapshot),
          ),
          progress: AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              final progressSnapshot = _controller.snapshot;
              final displayedPosition = Duration(
                milliseconds:
                    (_dragPositionMilliseconds ??
                            progressSnapshot.position.inMilliseconds.toDouble())
                        .clamp(
                          0,
                          math.max(0, progressSnapshot.duration.inMilliseconds),
                        )
                        .round(),
              );
              return AudioProgressControl(
                position: displayedPosition,
                duration: progressSnapshot.duration,
                enabled: progressSnapshot.duration > Duration.zero,
                dragging: _dragPositionMilliseconds != null,
                onChanged: (value) => setState(() {
                  _dragPositionMilliseconds = value;
                }),
                onChangeEnd: (value) {
                  setState(() {
                    _dragPositionMilliseconds = null;
                  });
                  unawaited(
                    _controller.seek(Duration(milliseconds: value.round())),
                  );
                },
              );
            },
          ),
          transport: AudioTransportControls(
            snapshot: snapshot,
            disableAnimations: disableAnimations,
            onPrevious: _controller.previous,
            onBackFifteen: () =>
                _controller.seekBy(const Duration(seconds: -15)),
            onToggle: _controller.toggle,
            onForwardFifteen: () =>
                _controller.seekBy(const Duration(seconds: 15)),
            onNext: _controller.next,
          ),
          shortcuts: AudioSettingsLauncher(
            snapshot: snapshot,
            onQueue: () => showAudioQueueSheet(
              context,
              snapshot: snapshot,
              controller: _controller,
              artworkBuilder: widget.queueArtworkBuilder,
            ),
            onRate: () =>
                _showSettings(context, snapshot, AudioSettingsSection.rate),
            onTimer: () =>
                _showSettings(context, snapshot, AudioSettingsSection.timer),
            onPressed: () => _showSettings(context, snapshot),
          ),
        ),
      ],
    );
  }

  void _showDetails(BuildContext context, AudioPlayerSnapshot snapshot) =>
      unawaited(
        showAudioDetailsSheet(
          context,
          snapshot: snapshot,
          controller: _controller,
          artworkBuilder: widget.artworkBuilder,
          resourceUrlDecoder: widget.resourceUrlDecoder,
        ),
      );

  void _showSettings(
    BuildContext context,
    AudioPlayerSnapshot snapshot, [
    AudioSettingsSection? section,
  ]) => unawaited(
    showAudioPlaybackSettingsSheet(
      context,
      snapshot: snapshot,
      controller: _controller,
      keepScreenOn: widget.keepScreenOn,
      onKeepScreenOnChanged: widget.onKeepScreenOnChanged,
      rememberPosition: widget.rememberPosition,
      onRememberPositionChanged: widget.onRememberPositionChanged,
      initialSection: section,
    ),
  );

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
