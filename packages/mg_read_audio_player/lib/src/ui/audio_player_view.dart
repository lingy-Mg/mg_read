/// Light, cover-led audio player surface owned by this package.
///
/// Responsibilities:
/// - Present an accessible responsive audio transport and queue controls.
/// - Bridge Flutter lifecycle and route-exit intent into the audio session.
///
/// Notes:
/// - Content, persistence and background services remain host-owned.
/// - Essential state changes remain immediate when animations are disabled.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/audio_artwork.dart';
import '../api/audio_contracts.dart';
import '../api/audio_controller.dart';
import '../api/audio_models.dart';
import '../backend/media_kit_audio_backend.dart';
import '../core/audio_player_session.dart';
import 'audio_player_observer_proxy.dart';
import 'audio_player_support.dart';

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
    super.key,
  });

  final String collectionId;
  final AudioPlayerDataSource dataSource;
  final AudioPlaybackStateStore stateStore;
  final AudioPlayerObserver? observer;
  final AudioPlayerController? controller;

  /// Optional fake or custom backend. The view owns and disposes it.
  final AudioPlaybackBackend? backend;

  /// Optional credential-free HTTP proxy used by the default MediaKit backend.
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

  @override
  State<AudioPlayerView> createState() => _AudioViewState();
}

class _AudioViewState extends State<AudioPlayerView>
    with WidgetsBindingObserver {
  late final AudioPlayerController _controller;
  late final bool _ownsController;
  late final AudioPlayerSession _session;
  final FocusNode _focusNode = FocusNode(debugLabel: 'AudioPlayerView');
  double? _dragPositionMilliseconds;
  Future<void>? _exitRequest;
  bool _exitAuthorized = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ownsController = widget.controller == null;
    _controller = widget.controller ?? AudioPlayerController();
    _session = AudioPlayerSession(
      collectionId: widget.collectionId,
      dataSource: widget.dataSource,
      stateStore: widget.stateStore,
      backend:
          widget.backend ??
          AudioMediaKitPlaybackBackend(proxyUri: widget.proxyUri),
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
    )..addListener(_onSessionChanged);
    unawaited(_session.initialize());
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
    unawaited(_session.handleLifecycle(normalized));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _focusNode.dispose();
    _session.removeListener(_onSessionChanged);
    unawaited(_session.close());
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _session.snapshot;
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
            backgroundColor: AudioPlayerColors.background,
            body: SafeArea(
              child: switch (snapshot.status) {
                AudioPlayerStatus.loading => const AudioLoadingView(),
                AudioPlayerStatus.error => AudioErrorView(
                  message: snapshot.failure?.message ?? '音频加载失败。',
                  location: snapshot.failure?.location,
                  diagnosticCode: snapshot.failure?.code,
                  onBack: _requestExit,
                  onRetry: _controller.retry,
                ),
                AudioPlayerStatus.ready => _buildReady(context, snapshot),
              },
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
        message: '播放队列为空。',
        onBack: _requestExit,
        onRetry: _controller.retry,
      );
    }
    final disableAnimations =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return LayoutBuilder(
      builder: (context, constraints) {
        final horizontalPadding = constraints.maxWidth < 380 ? 16.0 : 24.0;
        final coverSize = math.min(
          constraints.maxWidth - horizontalPadding * 2,
          constraints.maxHeight < 650 ? 210.0 : 286.0,
        );
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            4,
            horizontalPadding,
            28,
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _AudioTopBar(
                    collectionTitle:
                        track.collectionTitle ?? snapshot.collectionTitle,
                    onBack: _requestExit,
                    onQueue: () => showAudioQueueSheet(
                      context,
                      snapshot: snapshot,
                      controller: _controller,
                    ),
                  ),
                  const SizedBox(height: 18),
                  Center(
                    child: _AudioCover(
                      track: track,
                      artworkBuilder: widget.artworkBuilder,
                      size: coverSize,
                      playing: snapshot.playing,
                      disableAnimations: disableAnimations,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    track.title,
                    key: const Key('audio-track-title'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: AudioPlayerColors.ink,
                      fontWeight: FontWeight.w700,
                      height: 1.22,
                    ),
                  ),
                  if ((track.creator ?? snapshot.creator)?.trim().isNotEmpty ==
                      true) ...<Widget>[
                    const SizedBox(height: 7),
                    Text(
                      track.creator ?? snapshot.creator!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: AudioPlayerColors.muted,
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  _buildProgress(context, snapshot),
                  const SizedBox(height: 10),
                  _AudioTransportControls(
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
                  const SizedBox(height: 18),
                  AudioUtilityControls(
                    snapshot: snapshot,
                    onRate: () => _cycleRate(snapshot.rate),
                    onTimer: () => _showSleepTimer(context),
                    onQueue: () => showAudioQueueSheet(
                      context,
                      snapshot: snapshot,
                      controller: _controller,
                    ),
                  ),
                  if (snapshot.failure != null) ...<Widget>[
                    const SizedBox(height: 16),
                    Text(
                      snapshot.failure!.message,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AudioPlayerColors.warning,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildProgress(BuildContext context, AudioPlayerSnapshot snapshot) {
    final durationMs = math.max(1, snapshot.duration.inMilliseconds).toDouble();
    final currentMs =
        (_dragPositionMilliseconds ??
                snapshot.position.inMilliseconds.toDouble())
            .clamp(0, durationMs)
            .toDouble();
    return Column(
      children: <Widget>[
        Semantics(
          label: '播放进度',
          value:
              '${formatAudioDuration(Duration(milliseconds: currentMs.round()))} / ${formatAudioDuration(snapshot.duration)}',
          child: Slider(
            key: const Key('audio-progress-slider'),
            min: 0,
            max: durationMs,
            value: currentMs,
            activeColor: AudioPlayerColors.accent,
            inactiveColor: AudioPlayerColors.track,
            onChanged: snapshot.duration <= Duration.zero
                ? null
                : (value) => setState(() {
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
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              Text(
                formatAudioDuration(Duration(milliseconds: currentMs.round())),
              ),
              Text(formatAudioDuration(snapshot.duration)),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _requestExit() => _exitRequest ??= _beginExitRequest();

  Future<void> _beginExitRequest() async {
    try {
      await _controller.requestExit();
      if (widget.observer == null && mounted && _exitAuthorized) {
        await Navigator.of(context).maybePop();
      }
    } finally {
      if (mounted) {
        setState(() {
          _exitAuthorized = false;
        });
        _exitRequest = null;
      }
    }
  }

  Future<bool> _authorizeExit() async {
    if (!mounted) return false;
    if (!_exitAuthorized) {
      setState(() {
        _exitAuthorized = true;
      });
    }
    await WidgetsBinding.instance.endOfFrame;
    return mounted && _exitAuthorized;
  }

  Future<void> _cycleRate(double current) {
    const rates = <double>[0.75, 1, 1.25, 1.5, 2];
    final currentIndex = rates.indexWhere(
      (rate) => (rate - current).abs() < 0.01,
    );
    final next = rates[(currentIndex + 1) % rates.length];
    return _controller.setRate(next);
  }

  Future<void> _showSleepTimer(BuildContext context) async {
    const options = <Duration?>[
      null,
      Duration(minutes: 15),
      Duration(minutes: 30),
      Duration(minutes: 60),
    ];
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AudioPlayerColors.sheet,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                child: Text(
                  '定时停止',
                  style: Theme.of(sheetContext).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              for (final option in options)
                ListTile(
                  key: Key(
                    option == null
                        ? 'audio-timer-off'
                        : 'audio-timer-${option.inMinutes}',
                  ),
                  leading: Icon(
                    option == null
                        ? Icons.timer_off_outlined
                        : Icons.timer_outlined,
                  ),
                  title: Text(
                    option == null ? '关闭定时' : '${option.inMinutes} 分钟',
                  ),
                  onTap: () async {
                    await _controller.setSleepTimer(option);
                    if (sheetContext.mounted) {
                      Navigator.of(sheetContext).pop();
                    }
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AudioTopBar extends StatelessWidget {
  const _AudioTopBar({
    required this.collectionTitle,
    required this.onBack,
    required this.onQueue,
  });

  final String? collectionTitle;
  final VoidCallback onBack;
  final VoidCallback onQueue;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        IconButton(
          key: const Key('audio-back'),
          tooltip: '返回',
          onPressed: onBack,
          icon: const Icon(Icons.arrow_back_ios_new_rounded),
        ),
        Expanded(
          child: Text(
            collectionTitle ?? '音频播放',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: AudioPlayerColors.ink,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        IconButton(
          tooltip: '播放队列',
          onPressed: onQueue,
          icon: const Icon(Icons.queue_music_rounded),
        ),
      ],
    );
  }
}

class _AudioCover extends StatelessWidget {
  const _AudioCover({
    required this.track,
    required this.artworkBuilder,
    required this.size,
    required this.playing,
    required this.disableAnimations,
  });

  final AudioTrack track;
  final AudioArtworkBuilder? artworkBuilder;
  final double size;
  final bool playing;
  final bool disableAnimations;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      key: const Key('audio-cover'),
      duration: disableAnimations
          ? Duration.zero
          : const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      width: size,
      height: size,
      transform: Matrix4.diagonal3Values(
        playing ? 1 : 0.985,
        playing ? 1 : 0.985,
        1,
      ),
      transformAlignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            AudioPlayerColors.coverStart,
            AudioPlayerColors.coverEnd,
          ],
        ),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x332E2318),
            blurRadius: 30,
            offset: Offset(0, 16),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child:
          artworkBuilder?.call(context, track) ??
          const _AudioCoverPlaceholder(),
    );
  }
}

class _AudioCoverPlaceholder extends StatelessWidget {
  const _AudioCoverPlaceholder();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(-0.25, -0.35),
          radius: 1.1,
          colors: <Color>[Color(0xFFFFE4B8), Color(0x00FFE4B8)],
        ),
      ),
      child: const Center(
        child: Icon(
          Icons.headphones_rounded,
          size: 86,
          color: Color(0xFFFFF7EB),
        ),
      ),
    );
  }
}

class _SeekFifteenIcon extends StatelessWidget {
  const _SeekFifteenIcon({this.forward = false});

  final bool forward;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 30,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          Icon(
            forward ? Icons.rotate_right_rounded : Icons.rotate_left_rounded,
          ),
          Text(
            '15',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              fontSize: 9,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _AudioTransportControls extends StatelessWidget {
  const _AudioTransportControls({
    required this.snapshot,
    required this.disableAnimations,
    required this.onPrevious,
    required this.onBackFifteen,
    required this.onToggle,
    required this.onForwardFifteen,
    required this.onNext,
  });

  final AudioPlayerSnapshot snapshot;
  final bool disableAnimations;
  final VoidCallback onPrevious;
  final VoidCallback onBackFifteen;
  final VoidCallback onToggle;
  final VoidCallback onForwardFifteen;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 4,
      runSpacing: 8,
      children: <Widget>[
        IconButton(
          key: const Key('audio-previous'),
          tooltip: '上一首',
          onPressed: snapshot.canGoPrevious ? onPrevious : null,
          icon: const Icon(Icons.skip_previous_rounded),
        ),
        IconButton(
          key: const Key('audio-seek-back'),
          tooltip: '后退 15 秒',
          onPressed: onBackFifteen,
          icon: const _SeekFifteenIcon(),
        ),
        SizedBox(
          width: 72,
          height: 72,
          child: FilledButton(
            key: const Key('audio-play-pause'),
            style: FilledButton.styleFrom(
              shape: const CircleBorder(),
              padding: EdgeInsets.zero,
              backgroundColor: AudioPlayerColors.accent,
              foregroundColor: Colors.white,
            ),
            onPressed: onToggle,
            child: AnimatedSwitcher(
              duration: disableAnimations
                  ? Duration.zero
                  : const Duration(milliseconds: 150),
              child: snapshot.buffering
                  ? const SizedBox(
                      key: Key('audio-buffering'),
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: Colors.white,
                      ),
                    )
                  : Icon(
                      snapshot.playing
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      key: ValueKey<bool>(snapshot.playing),
                      size: 38,
                    ),
            ),
          ),
        ),
        IconButton(
          key: const Key('audio-seek-forward'),
          tooltip: '前进 15 秒',
          onPressed: onForwardFifteen,
          icon: const _SeekFifteenIcon(forward: true),
        ),
        IconButton(
          key: const Key('audio-next'),
          tooltip: '下一首',
          onPressed: snapshot.canGoNext ? onNext : null,
          icon: const Icon(Icons.skip_next_rounded),
        ),
      ],
    );
  }
}
