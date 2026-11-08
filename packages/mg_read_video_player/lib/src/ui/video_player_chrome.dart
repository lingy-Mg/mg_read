/// Adaptive pointer and touch playback chrome for the video player.
///
/// Responsibilities:
/// - Render accessible playback controls over the engine-owned video surface.
/// - Keep mouse transport below and large touch transport over the picture.
/// - Own only presentation; command, seek-preview and modal lifetimes stay explicit.
///
/// Notes:
/// - This file emits semantic callbacks only and never touches a playback engine.
/// - Fullscreen buttons express host intent; they do not mutate system UI.
library;

// Cross-file UI helpers are intentionally package-private despite Dart's
// library-level public naming rules.
// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'package:flutter/material.dart';

import '../api/controller.dart';
import '../api/models.dart';
import 'video_player_details_sheet.dart';
import 'video_player_settings_sheet.dart';
import 'video_player_visuals.dart';
import 'video_player_transport.dart';

/// Package-private overlay for one video session.
final class VideoPlayerChrome extends StatefulWidget {
  const VideoPlayerChrome({
    required this.controller,
    required this.snapshot,
    required this.activeEpisode,
    required this.reduceMotion,
    required this.seekPreviewPosition,
    required this.onExit,
    required this.onSeekPreviewChanged,
    required this.onSeekPreviewEnded,
    required this.onSeekPreviewCanceled,
    required this.onRate,
    required this.onEnhancementMode,
    required this.onFit,
    required this.onEpisodes,
    required this.onFullscreen,
    required this.onPreviousEpisode,
    required this.onNextEpisode,
    required this.onAutoAdvance,
    required this.onInteractionStart,
    required this.onInteractionEnd,
    required this.onControlsHoverChanged,
    this.topRightAction,
    super.key,
  });

  final VideoPlayerController controller;
  final VideoPlayerSnapshot snapshot;
  final VideoEpisode? activeEpisode;
  final bool reduceMotion;
  final Duration? seekPreviewPosition;
  final VoidCallback onExit;
  final ValueChanged<Duration> onSeekPreviewChanged;
  final ValueChanged<Duration> onSeekPreviewEnded;
  final VoidCallback onSeekPreviewCanceled;
  final Future<void> Function(double) onRate;
  final Future<void> Function(VideoEnhancementMode) onEnhancementMode;
  final Future<void> Function() onFit;
  final VoidCallback onEpisodes;
  final ValueChanged<bool> onFullscreen;
  final Future<void> Function() onPreviousEpisode;
  final Future<void> Function() onNextEpisode;
  final Future<void> Function(bool) onAutoAdvance;
  final VoidCallback onInteractionStart;
  final VoidCallback onInteractionEnd;
  final ValueChanged<bool> onControlsHoverChanged;
  final Widget? topRightAction;

  @override
  State<VideoPlayerChrome> createState() => _VideoPlayerChromeState();
}

final class _VideoPlayerChromeState extends State<VideoPlayerChrome> {
  @override
  Widget build(BuildContext context) {
    final snapshot = widget.snapshot;
    final pointer = videoPlayerUsesPointerControls(context);
    return IgnorePointer(
      ignoring: !snapshot.controlsVisible,
      child: ExcludeFocus(
        excluding: !snapshot.controlsVisible,
        child: Listener(
          onPointerDown: (_) => widget.onInteractionStart(),
          onPointerUp: (_) => widget.onInteractionEnd(),
          onPointerCancel: (_) {
            widget.onSeekPreviewCanceled();
            widget.onInteractionEnd();
          },
          child: AnimatedOpacity(
            key: const Key('video-player-controls'),
            opacity: snapshot.controlsVisible ? 1 : 0,
            duration: widget.reduceMotion
                ? Duration.zero
                : const Duration(milliseconds: 160),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Align(
                  alignment: Alignment.topCenter,
                  child: MouseRegion(
                    onEnter: (_) => widget.onControlsHoverChanged(true),
                    onExit: (_) => widget.onControlsHoverChanged(false),
                    child: Container(
                      key: const Key('video-player-top-band'),
                      padding: const EdgeInsets.fromLTRB(8, 8, 8, 32),
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0xB3000000), Colors.transparent],
                        ),
                      ),
                      child: SafeArea(
                        bottom: false,
                        child: Row(
                          children: [
                            videoPlayerControl(
                              'video-player-back',
                              '返回',
                              Icons.arrow_back_rounded,
                              widget.onExit,
                              size: 24,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    snapshot.title,
                                    key: const Key('video-player-title'),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: pointer ? 18 : 15,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  Text(
                                    _episodeLabel(snapshot),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: videoPlayerSecondary,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            ?widget.topRightAction,
                            videoPlayerControl(
                              'video-player-details',
                              '视频详情',
                              Icons.info_outline_rounded,
                              () => _showDetails(context),
                              size: 23,
                            ),
                            if (!pointer)
                              videoPlayerControl(
                                'video-player-settings',
                                '播放设置',
                                Icons.settings_outlined,
                                () => _showSettings(context),
                                size: 24,
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                if (!pointer &&
                    widget.seekPreviewPosition == null &&
                    !snapshot.completed)
                  Center(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        videoPlayerControl(
                          'video-player-rewind',
                          '后退 10 秒',
                          Icons.replay_10_rounded,
                          () => unawaited(
                            widget.controller.skip(
                              const Duration(seconds: -10),
                            ),
                          ),
                          size: 32,
                        ),
                        const SizedBox(width: 28),
                        IconButton(
                          key: const Key('video-player-play-pause'),
                          tooltip: snapshot.playing ? '暂停' : '播放',
                          onPressed: () =>
                              unawaited(widget.controller.playOrPause()),
                          style: IconButton.styleFrom(
                            foregroundColor: Colors.white,
                            backgroundColor: const Color(0x66000000),
                            fixedSize: const Size.square(64),
                          ),
                          icon: Icon(
                            snapshot.playing
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            size: 44,
                          ),
                        ),
                        const SizedBox(width: 28),
                        videoPlayerControl(
                          'video-player-forward',
                          '前进 10 秒',
                          Icons.forward_10_rounded,
                          () => unawaited(
                            widget.controller.skip(const Duration(seconds: 10)),
                          ),
                          size: 32,
                        ),
                      ],
                    ),
                  ),
                Align(
                  alignment: Alignment.bottomCenter,
                  child: MouseRegion(
                    onEnter: (_) => widget.onControlsHoverChanged(true),
                    onExit: (_) => widget.onControlsHoverChanged(false),
                    child: VideoPlayerTransport(
                      controller: widget.controller,
                      snapshot: snapshot,
                      position: widget.seekPreviewPosition ?? snapshot.position,
                      onPreview: widget.onSeekPreviewChanged,
                      onCommit: widget.onSeekPreviewEnded,
                      onInteractionStart: widget.onInteractionStart,
                      onInteractionEnd: widget.onInteractionEnd,
                      onEpisodes: widget.onEpisodes,
                      onSettings: () => _showSettings(context),
                      onFullscreen: () =>
                          widget.onFullscreen(!snapshot.fullscreenRequested),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showDetails(BuildContext context) {
    widget.onInteractionStart();
    showVideoDetailsSheet(
      context,
      controller: widget.controller,
      activeEpisode: widget.activeEpisode,
    ).whenComplete(widget.onInteractionEnd);
  }

  void _showSettings(BuildContext context) {
    widget.onInteractionStart();
    showVideoPlayerSettingsSheet(
      context: context,
      snapshot: widget.snapshot,
      onRate: widget.onRate,
      onEnhancementMode: widget.onEnhancementMode,
      onFit: widget.onFit,
      onPreviousEpisode: widget.onPreviousEpisode,
      onNextEpisode: widget.onNextEpisode,
      onAutoAdvance: widget.onAutoAdvance,
    ).whenComplete(widget.onInteractionEnd);
  }
}

String _episodeLabel(VideoPlayerSnapshot snapshot) {
  for (final group in snapshot.groups) {
    if (group.id != snapshot.activeGroupId) continue;
    for (final episode in group.episodes) {
      if (episode.id == snapshot.activeEpisodeId) {
        return '${group.title} · ${episode.title}';
      }
    }
  }
  return '选集';
}
