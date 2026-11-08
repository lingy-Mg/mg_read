/// Adaptive video transport: pointer controls share a bottom row; touch controls
/// keep large central playback targets. Emits existing controller commands only.
/// Seek drags preview locally and commit once on release; volume is backend volume.
library;

// Internal composition, not exported from the package.
// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'package:flutter/material.dart';
import '../api/controller.dart';
import '../api/models.dart';
import 'video_player_visuals.dart';

class VideoPlayerTransport extends StatelessWidget {
  const VideoPlayerTransport({
    required this.controller,
    required this.snapshot,
    required this.position,
    required this.onPreview,
    required this.onCommit,
    required this.onInteractionStart,
    required this.onInteractionEnd,
    required this.onEpisodes,
    required this.onSettings,
    required this.onFullscreen,
    super.key,
  });

  final VideoPlayerController controller;
  final VideoPlayerSnapshot snapshot;
  final Duration position;
  final ValueChanged<Duration> onPreview, onCommit;
  final VoidCallback onInteractionStart, onInteractionEnd;
  final VoidCallback onEpisodes, onSettings, onFullscreen;

  @override
  Widget build(BuildContext context) {
    final pointer = videoPlayerUsesPointerControls(context);
    final max = snapshot.duration.inMilliseconds > 0
        ? snapshot.duration.inMilliseconds.toDouble()
        : 1.0;
    final value = position.inMilliseconds.clamp(0, max.toInt()).toDouble();
    return Container(
      key: const Key('video-player-bottom-band'),
      padding: const EdgeInsets.fromLTRB(12, 28, 12, 4),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Color(0xD9000000)],
        ),
      ),
      child: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final roomy =
                pointer &&
                constraints.maxWidth >= 600 &&
                MediaQuery.textScalerOf(context).scale(14) <= 22;
            final time = Text(
              '${videoPlayerTime(position)} / ${videoPlayerTime(snapshot.duration)}',
              key: const Key('video-player-time'),
              maxLines: 1,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            );
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    activeTrackColor: videoPlayerAccent,
                    secondaryActiveTrackColor: Colors.white54,
                    inactiveTrackColor: Colors.white24,
                    thumbColor: videoPlayerAccent,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 6,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 14,
                    ),
                    trackShape: const RectangularSliderTrackShape(),
                  ),
                  child: SizedBox(
                    height: 28,
                    child: Slider(
                      key: const Key('video-player-slider'),
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      value: value,
                      max: max,
                      semanticFormatterCallback: (v) =>
                          videoPlayerTime(Duration(milliseconds: v.round())),
                      secondaryTrackValue: snapshot
                          .bufferedPosition
                          .inMilliseconds
                          .clamp(value.toInt(), max.toInt())
                          .toDouble(),
                      onChangeStart: (_) => onInteractionStart(),
                      onChanged: (v) =>
                          onPreview(Duration(milliseconds: v.round())),
                      onChangeEnd: (v) {
                        onCommit(Duration(milliseconds: v.round()));
                        onInteractionEnd();
                      },
                    ),
                  ),
                ),
                if (!roomy)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: time,
                    ),
                  ),
                Row(
                  children: [
                    if (pointer) ...[
                      videoPlayerControl(
                        'video-player-play-pause',
                        snapshot.playing ? '暂停 (K)' : '播放 (K)',
                        snapshot.playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        () => unawaited(controller.playOrPause()),
                      ),
                      if (roomy)
                        videoPlayerControl(
                          'video-player-next',
                          '下一集 (N)',
                          Icons.skip_next_rounded,
                          snapshot.hasNextEpisode
                              ? () => unawaited(controller.playNextEpisode())
                              : null,
                        ),
                    ],
                    videoPlayerControl(
                      'video-player-mute',
                      snapshot.volume == 0 ? '取消静音 (M)' : '静音 (M)',
                      snapshot.volume == 0
                          ? Icons.volume_off_rounded
                          : Icons.volume_up_rounded,
                      () => unawaited(controller.toggleMute()),
                    ),
                    if (roomy) ...[
                      SizedBox(
                        width: 76,
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            activeTrackColor: Colors.white,
                            thumbColor: Colors.white,
                            trackHeight: 3,
                            thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 5,
                            ),
                            overlayShape: const RoundSliderOverlayShape(
                              overlayRadius: 10,
                            ),
                          ),
                          child: Slider(
                            key: const Key('video-player-volume'),
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            value: snapshot.volume.clamp(0, 100),
                            max: 100,
                            semanticFormatterCallback: (v) =>
                                '音量 ${v.round()}%',
                            onChangeStart: (_) => onInteractionStart(),
                            onChangeEnd: (_) => onInteractionEnd(),
                            onChanged: (v) =>
                                unawaited(controller.setVolume(v)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      time,
                    ],
                    const Spacer(),
                    if (roomy)
                      videoPlayerControl(
                        'video-player-fit-quick',
                        '画面比例',
                        Icons.aspect_ratio_rounded,
                        () => unawaited(controller.cycleFitMode()),
                      ),
                    videoPlayerControl(
                      'video-player-episodes',
                      '选集 / 线路',
                      Icons.playlist_play_rounded,
                      onEpisodes,
                    ),
                    if (pointer)
                      videoPlayerControl(
                        'video-player-settings',
                        '播放设置',
                        Icons.settings_outlined,
                        onSettings,
                      ),
                    videoPlayerControl(
                      'video-player-fullscreen',
                      snapshot.fullscreenRequested ? '退出全屏 (F)' : '进入全屏 (F)',
                      snapshot.fullscreenRequested
                          ? Icons.fullscreen_exit_rounded
                          : Icons.fullscreen_rounded,
                      onFullscreen,
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

Widget videoPlayerControl(
  String key,
  String label,
  IconData icon,
  VoidCallback? onPressed, {
  double size = 28,
}) => IconButton(
  key: Key(key),
  tooltip: label,
  onPressed: onPressed,
  style: IconButton.styleFrom(
    foregroundColor: Colors.white,
    disabledForegroundColor: Colors.white30,
    minimumSize: const Size.square(44),
    padding: const EdgeInsets.all(8),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
    hoverColor: Colors.white12,
    focusColor: Colors.white24,
  ),
  icon: Icon(icon, size: size),
);
