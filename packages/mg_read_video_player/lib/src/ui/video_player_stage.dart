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
    required this.onSkip,
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
  final Future<void> Function(Duration) onSkip;
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
      value: SystemUiOverlayStyle.light,
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
                        if (snapshot.status == VideoPlayerStatus.ready)
                          VideoPlayerGestureLayer(
                            snapshot: snapshot,
                            onToggleControls: () =>
                                unawaited(onToggleControls()),
                            onPlayOrPause: () => unawaited(onPlayOrPause()),
                            onSeek: (value) => unawaited(onSeek(value)),
                            onRate: (value) => unawaited(onRate(value)),
                            onVolume: (value) => unawaited(onVolume(value)),
                            onReadBrightness: onReadBrightness,
                            onBrightness: (value) =>
                                unawaited(onBrightness(value)),
                            locked: snapshot.controlsLocked,
                            onInteractionStart: onInteractionStart,
                            onInteractionEnd: onInteractionEnd,
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
                    if (snapshot.status == VideoPlayerStatus.ready &&
                        !snapshot.controlsLocked)
                      VideoPlayerChrome(
                        snapshot: snapshot,
                        reduceMotion: reduceMotion,
                        onExit: () => unawaited(onExit()),
                        onPlayOrPause: () => unawaited(onPlayOrPause()),
                        onSeek: (value) => unawaited(onSeek(value)),
                        onSkip: (value) => unawaited(onSkip(value)),
                        onRate: (value) => unawaited(onRate(value)),
                        onFit: () => unawaited(onFit()),
                        onEpisodes: () => unawaited(onEpisodes()),
                        onFullscreen: (value) => unawaited(onFullscreen(value)),
                        onPreviousEpisode: () => unawaited(onPreviousEpisode()),
                        onNextEpisode: () => unawaited(onNextEpisode()),
                        onAutoAdvance: (value) =>
                            unawaited(onAutoAdvance(value)),
                        onInteractionStart: onInteractionStart,
                        onInteractionEnd: onInteractionEnd,
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
