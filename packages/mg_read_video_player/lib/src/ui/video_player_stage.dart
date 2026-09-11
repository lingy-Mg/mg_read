/// Package-private player surface, status and chrome composition.
///
/// Responsibilities:
/// - Compose the backend surface with package-owned dark video presentation.
/// - Route pointer, keyboard and back intents to the session coordinator.
///
/// Notes:
/// - System text scaling is preserved; child controls own narrow-layout safety.
/// - This file contains no session loading, persistence or backend sequencing.
library;

// Cross-file UI helpers are intentionally package-private despite Dart's
// library-level public naming rules.
// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/contracts.dart';
import '../api/models.dart';
import 'video_player_chrome.dart';
import 'video_player_buffering_indicator.dart';
import 'video_player_completion_layer.dart';
import 'video_player_gestures.dart';
import 'video_player_status_layer.dart';
import 'video_player_visuals.dart';

const _videoPlayerSystemUiStyle = SystemUiOverlayStyle(
  statusBarColor: Colors.transparent,
  statusBarIconBrightness: Brightness.light,
  statusBarBrightness: Brightness.dark,
  systemNavigationBarColor: Colors.transparent,
  systemNavigationBarDividerColor: Colors.transparent,
  systemNavigationBarIconBrightness: Brightness.light,
  systemStatusBarContrastEnforced: false,
  systemNavigationBarContrastEnforced: false,
);

final class VideoPlayerStage extends StatelessWidget {
  const VideoPlayerStage({
    required this.backend,
    required this.snapshot,
    required this.focusNode,
    required this.exitAuthorized,
    required this.onPopAttempt,
    required this.onKeyEvent,
    required this.onToggleControls,
    required this.onRetry,
    required this.onExit,
    required this.onPlayOrPause,
    required this.onSeek,
    required this.onRate,
    required this.onVolume,
    required this.onReplay,
    required this.onPreviousEpisode,
    required this.onNextEpisode,
    required this.onAutoAdvance,
    required this.onControlsLocked,
    required this.onInteractionStart,
    required this.onInteractionEnd,
    required this.onFit,
    required this.onEpisodes,
    required this.onFullscreen,
    required this.onReadBrightness,
    required this.onBrightness,
    super.key,
  });

  final VideoPlaybackBackend backend;
  final VideoPlayerSnapshot snapshot;
  final FocusNode focusNode;
  final bool exitAuthorized;
  final VoidCallback onPopAttempt;
  final KeyEventResult Function(FocusNode, KeyEvent) onKeyEvent;
  final Future<void> Function() onToggleControls;
  final Future<void> Function() onRetry;
  final Future<void> Function() onExit;
  final Future<void> Function() onPlayOrPause;
  final Future<void> Function(Duration) onSeek;
  final Future<void> Function(double) onRate;
  final Future<void> Function(double) onVolume;
  final Future<void> Function() onReplay;
  final Future<void> Function() onPreviousEpisode;
  final Future<void> Function() onNextEpisode;
  final Future<void> Function(bool) onAutoAdvance;
  final Future<void> Function(bool) onControlsLocked;
  final VoidCallback onInteractionStart;
  final VoidCallback onInteractionEnd;
  final Future<void> Function() onFit;
  final Future<void> Function() onEpisodes;
  final Future<void> Function(bool) onFullscreen;
  final Future<double?> Function() onReadBrightness;
  final Future<void> Function(double) onBrightness;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: _videoPlayerSystemUiStyle,
      child: Theme(
        data: videoPlayerTheme(),
        child: PopScope<void>(
          canPop: exitAuthorized,
          onPopInvokedWithResult: (bool didPop, void result) {
            if (!didPop) onPopAttempt();
          },
          child: Focus(
            focusNode: focusNode,
            autofocus: true,
            onKeyEvent: onKeyEvent,
            child: Listener(
              onPointerHover: (_) {
                onInteractionStart();
                onInteractionEnd();
              },
              child: Scaffold(
                backgroundColor: const Color(0xFF050607),
                body: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    Stack(
                      key: const Key('video-player-surface'),
                      fit: StackFit.expand,
                      children: <Widget>[
                        backend.buildSurface(
                          key: const Key('video-player-engine-surface'),
                          fit: videoBoxFit(snapshot.fitMode),
                        ),
                      ],
                    ),
                    if (!snapshot.firstFrameReady ||
                        snapshot.status != VideoPlayerStatus.ready)
                      VideoSessionStatusLayer(
                        snapshot: snapshot,
                        onRetry: onRetry,
                        onExit: onExit,
                        onEpisodes: onEpisodes,
                      ),
                    if (snapshot.status == VideoPlayerStatus.ready)
                      _VideoPlayerInteractionLayer(
                        snapshot: snapshot,
                        reduceMotion: reduceMotion,
                        onToggleControls: onToggleControls,
                        onExit: onExit,
                        onPlayOrPause: onPlayOrPause,
                        onSeek: onSeek,
                        onRate: onRate,
                        onVolume: onVolume,
                        onPreviousEpisode: onPreviousEpisode,
                        onNextEpisode: onNextEpisode,
                        onAutoAdvance: onAutoAdvance,
                        onInteractionStart: onInteractionStart,
                        onInteractionEnd: onInteractionEnd,
                        onFit: onFit,
                        onEpisodes: onEpisodes,
                        onFullscreen: onFullscreen,
                        onReadBrightness: onReadBrightness,
                        onBrightness: onBrightness,
                      ),
                    if (snapshot.status == VideoPlayerStatus.ready)
                      VideoPlayerBufferingIndicator(
                        buffering: snapshot.buffering && !snapshot.completed,
                      ),
                    if (snapshot.status == VideoPlayerStatus.ready &&
                        snapshot.completed &&
                        (!snapshot.autoAdvance || !snapshot.hasNextEpisode))
                      VideoPlayerCompletionLayer(
                        snapshot: snapshot,
                        onReplay: () => unawaited(onReplay()),
                        onNextEpisode: () => unawaited(onNextEpisode()),
                      ),
                    if (snapshot.fullscreenRequested &&
                        snapshot.controlsVisible)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: SafeArea(
                          minimum: const EdgeInsets.only(left: 8),
                          child: IconButton.filledTonal(
                            key: const Key('video-player-controls-lock'),
                            tooltip: snapshot.controlsLocked ? '解锁手势' : '锁定手势',
                            onPressed: () => unawaited(
                              onControlsLocked(!snapshot.controlsLocked),
                            ),
                            style: IconButton.styleFrom(
                              backgroundColor: const Color(0xA305070A),
                              foregroundColor: videoPlayerForeground,
                            ),
                            icon: Icon(
                              snapshot.controlsLocked
                                  ? Icons.lock_rounded
                                  : Icons.lock_open_rounded,
                              size: 20,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _VideoPlayerInteractionLayer extends StatefulWidget {
  const _VideoPlayerInteractionLayer({
    required this.snapshot,
    required this.reduceMotion,
    required this.onToggleControls,
    required this.onExit,
    required this.onPlayOrPause,
    required this.onSeek,
    required this.onRate,
    required this.onVolume,
    required this.onPreviousEpisode,
    required this.onNextEpisode,
    required this.onAutoAdvance,
    required this.onInteractionStart,
    required this.onInteractionEnd,
    required this.onFit,
    required this.onEpisodes,
    required this.onFullscreen,
    required this.onReadBrightness,
    required this.onBrightness,
  });

  final VideoPlayerSnapshot snapshot;
  final bool reduceMotion;
  final Future<void> Function() onToggleControls;
  final Future<void> Function() onExit;
  final Future<void> Function() onPlayOrPause;
  final Future<void> Function(Duration) onSeek;
  final Future<void> Function(double) onRate;
  final Future<void> Function(double) onVolume;
  final Future<void> Function() onPreviousEpisode;
  final Future<void> Function() onNextEpisode;
  final Future<void> Function(bool) onAutoAdvance;
  final VoidCallback onInteractionStart;
  final VoidCallback onInteractionEnd;
  final Future<void> Function() onFit;
  final Future<void> Function() onEpisodes;
  final Future<void> Function(bool) onFullscreen;
  final Future<double?> Function() onReadBrightness;
  final Future<void> Function(double) onBrightness;

  @override
  State<_VideoPlayerInteractionLayer> createState() =>
      _VideoPlayerInteractionLayerState();
}

final class _VideoPlayerInteractionLayerState
    extends State<_VideoPlayerInteractionLayer> {
  Duration? _seekPreviewPosition;

  @override
  void didUpdateWidget(covariant _VideoPlayerInteractionLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.snapshot.activeGroupId != widget.snapshot.activeGroupId ||
        oldWidget.snapshot.activeEpisodeId != widget.snapshot.activeEpisodeId ||
        widget.snapshot.controlsLocked) {
      _seekPreviewPosition = null;
    }
  }

  void _updateSeekPreview(Duration position) {
    if (!mounted || widget.snapshot.controlsLocked) return;
    setState(() => _seekPreviewPosition = position);
  }

  Future<void> _commitSeekPreview(Duration position) async {
    if (!mounted || widget.snapshot.controlsLocked) return;
    setState(() => _seekPreviewPosition = position);
    try {
      await widget.onSeek(position);
    } finally {
      if (mounted && _seekPreviewPosition == position) {
        setState(() => _seekPreviewPosition = null);
      }
    }
  }

  void _cancelSeekPreview() {
    if (mounted && _seekPreviewPosition != null) {
      setState(() => _seekPreviewPosition = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = widget.snapshot;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        VideoPlayerGestureLayer(
          snapshot: snapshot,
          onToggleControls: () => unawaited(widget.onToggleControls()),
          onPlayOrPause: () => unawaited(widget.onPlayOrPause()),
          onSeekPreviewChanged: _updateSeekPreview,
          onSeekPreviewEnded: (position) =>
              unawaited(_commitSeekPreview(position)),
          onSeekPreviewCanceled: _cancelSeekPreview,
          onRate: (value) => unawaited(widget.onRate(value)),
          onVolume: (value) => unawaited(widget.onVolume(value)),
          onReadBrightness: widget.onReadBrightness,
          onBrightness: (value) => unawaited(widget.onBrightness(value)),
          locked: snapshot.controlsLocked,
          onInteractionStart: widget.onInteractionStart,
          onInteractionEnd: widget.onInteractionEnd,
        ),
        if (!snapshot.controlsLocked)
          VideoPlayerChrome(
            snapshot: snapshot,
            reduceMotion: widget.reduceMotion,
            seekPreviewPosition: _seekPreviewPosition,
            onExit: () => unawaited(widget.onExit()),
            onSeekPreviewChanged: _updateSeekPreview,
            onSeekPreviewEnded: (position) =>
                unawaited(_commitSeekPreview(position)),
            onSeekPreviewCanceled: _cancelSeekPreview,
            onRate: widget.onRate,
            onFit: widget.onFit,
            onEpisodes: () => unawaited(widget.onEpisodes()),
            onFullscreen: (value) => unawaited(widget.onFullscreen(value)),
            onPreviousEpisode: widget.onPreviousEpisode,
            onNextEpisode: widget.onNextEpisode,
            onAutoAdvance: widget.onAutoAdvance,
            onInteractionStart: widget.onInteractionStart,
            onInteractionEnd: widget.onInteractionEnd,
          ),
        if (!snapshot.controlsLocked &&
            !snapshot.playing &&
            !snapshot.completed &&
            _seekPreviewPosition == null)
          Center(
            child: IconButton(
              key: const Key('video-player-paused-play'),
              tooltip: '播放',
              onPressed: () => unawaited(widget.onPlayOrPause()),
              iconSize: 34,
              style: IconButton.styleFrom(
                fixedSize: const Size.square(58),
                backgroundColor: const Color(0x38FFFFFF),
                foregroundColor: Colors.white,
                side: const BorderSide(color: Color(0x52FFFFFF)),
                shape: const CircleBorder(),
              ),
              icon: const Icon(Icons.play_arrow_rounded),
            ),
          ),
        if (_seekPreviewPosition case final position?)
          _SeekPreviewOverlay(position: position, duration: snapshot.duration),
      ],
    );
  }
}

final class _SeekPreviewOverlay extends StatelessWidget {
  const _SeekPreviewOverlay({required this.position, required this.duration});

  final Duration position;
  final Duration duration;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Center(
      child: VideoPlayerGlassPanel(
        key: const Key('video-player-seek-preview'),
        borderRadius: BorderRadius.circular(8),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
        showShadow: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Text(
              '拖动进度',
              style: TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${_formatStageDuration(position)} / ${_formatStageDuration(duration)}',
              key: const Key('video-player-seek-preview-time'),
              style: const TextStyle(
                color: videoPlayerForeground,
                fontSize: 13,
                fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

String _formatStageDuration(Duration duration) {
  final total = duration.inSeconds.clamp(0, 359999);
  final hours = total ~/ 3600;
  final minutes = total.remainder(3600) ~/ 60;
  final seconds = total.remainder(60);
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}
