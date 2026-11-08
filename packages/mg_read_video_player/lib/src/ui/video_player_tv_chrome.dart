/// Remote-first video controls; receives callbacks and owns no playback state.
/// A neutral black gradient and red timeline keep controls consistent with touch
/// and desktop. Bottom controls keep a visible focus ring and leave the picture
/// visible; enlarged text can wrap and scroll without losing remote focus.
library;

// Internal package composition, not part of the public import surface.
// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'package:flutter/material.dart';
import '../api/models.dart';
import 'video_tv_shortcuts.dart';
import 'video_player_visuals.dart';

class VideoPlayerTvChrome extends StatelessWidget {
  const VideoPlayerTvChrome({
    required this.snapshot,
    required this.playFocus,
    required this.onPlay,
    required this.onSeek,
    required this.onEpisodes,
    required this.onNext,
    required this.onPrevious,
    required this.onRate,
    required this.onFit,
    required this.onExit,
    required this.onReveal,
    required this.onInteractionStart,
    required this.onInteractionEnd,
    super.key,
  });
  final VideoPlayerSnapshot snapshot;
  final FocusNode playFocus;
  final Future<void> Function() onPlay;
  final Future<void> Function(Duration) onSeek;
  final Future<void> Function() onEpisodes;
  final Future<void> Function() onNext;
  final Future<void> Function() onPrevious;
  final Future<void> Function(double) onRate;
  final Future<void> Function() onFit;
  final Future<void> Function() onExit;
  final Future<void> Function() onReveal;
  final VoidCallback onInteractionStart;
  final VoidCallback onInteractionEnd;

  @override
  Widget build(BuildContext context) => VideoTvShortcuts(
    child: Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: () => unawaited(onReveal()),
            behavior: HitTestBehavior.translucent,
          ),
        ),
        if (snapshot.controlsVisible)
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * .8,
              ),
              key: const Key('tv-video-bottom-band'),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Color(0xE6000000)],
                ),
              ),
              padding: const EdgeInsets.fromLTRB(28, 44, 28, 20),
              child: SafeArea(
                top: false,
                child: SingleChildScrollView(
                  key: const Key('tv-video-controls-scroll'),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              snapshot.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                              ),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Text(
                            '${videoPlayerTime(snapshot.position)} / ${videoPlayerTime(snapshot.duration)}',
                            style: const TextStyle(
                              fontSize: 16,
                              color: Colors.white70,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      LinearProgressIndicator(
                        key: const Key('tv-video-progress'),
                        color: videoPlayerAccent,
                        backgroundColor: Colors.white24,
                        minHeight: 3,
                        value: snapshot.duration.inMilliseconds > 0
                            ? (snapshot.position.inMilliseconds /
                                      snapshot.duration.inMilliseconds)
                                  .clamp(0, 1)
                            : 0,
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _button(
                            'tv-video-play',
                            snapshot.playing ? '暂停' : '播放',
                            onPlay,
                            focus: playFocus,
                          ),
                          _button(
                            'tv-video-backward',
                            '后退 10 秒',
                            () => onSeek(
                              snapshot.position - const Duration(seconds: 10),
                            ),
                          ),
                          _button(
                            'tv-video-forward',
                            '前进 10 秒',
                            () => onSeek(
                              snapshot.position + const Duration(seconds: 10),
                            ),
                          ),
                          _button('tv-video-episodes', '选集 / 线路', onEpisodes),
                          if (snapshot.hasPreviousEpisode)
                            _button('tv-video-previous', '上一集', onPrevious),
                          if (snapshot.hasNextEpisode)
                            _button('tv-video-next', '下一集', onNext),
                          _button(
                            'tv-video-rate',
                            '${snapshot.rate}× 倍速',
                            () => _chooseRate(context),
                          ),
                          _button('tv-video-fit', '画面比例', onFit),
                          _button('tv-video-exit', '退出播放', onExit),
                        ],
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        '方向键选择 · OK 确认 · 返回收起',
                        style: TextStyle(fontSize: 14, color: Colors.white70),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );

  Widget _button(
    String key,
    String label,
    Future<void> Function() action, {
    FocusNode? focus,
  }) => FilledButton.icon(
    key: Key(key),
    focusNode: focus,
    onPressed: () => unawaited(_perform(action)),
    onFocusChange: (focused) {
      if (focused) onInteractionEnd();
    },
    style: ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size(72, 48)),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
      side: WidgetStateProperty.resolveWith(
        (states) => BorderSide(
          color: states.contains(WidgetState.focused)
              ? Colors.white
              : Colors.transparent,
          width: 3,
        ),
      ),
      backgroundColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.focused)
            ? videoPlayerAccent
            : const Color(0x20FFFFFF),
      ),
      foregroundColor: const WidgetStatePropertyAll(Colors.white),
    ),
    icon: Icon(switch (key) {
      'tv-video-play' =>
        snapshot.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
      'tv-video-backward' => Icons.replay_10_rounded,
      'tv-video-forward' => Icons.forward_10_rounded,
      'tv-video-episodes' => Icons.playlist_play_rounded,
      'tv-video-previous' => Icons.skip_previous_rounded,
      'tv-video-next' => Icons.skip_next_rounded,
      'tv-video-rate' => Icons.speed_rounded,
      'tv-video-fit' => Icons.aspect_ratio_rounded,
      _ => Icons.close_rounded,
    }, size: 22),
    label: Text(label, style: const TextStyle(fontSize: 16)),
  );

  Future<void> _perform(Future<void> Function() action) async {
    onInteractionStart();
    try {
      await action();
    } finally {
      onInteractionEnd();
    }
  }

  Future<void> _chooseRate(BuildContext context) async {
    final rate = await showDialog<double>(
      context: context,
      builder: (context) => VideoTvShortcuts(
        child: Theme(
          data: videoPlayerTheme(),
          child: AlertDialog(
            backgroundColor: const Color(0xFF181818),
            surfaceTintColor: Colors.transparent,
            scrollable: true,
            title: const Text('播放速度'),
            content: Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final value in [.5, 1.0, 1.25, 1.5, 2.0])
                  TextButton(
                    autofocus: value == snapshot.rate,
                    onPressed: () => Navigator.pop(context, value),
                    child: Text(
                      '$value×',
                      style: const TextStyle(fontSize: 24),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    if (rate != null && context.mounted) await onRate(rate);
  }
}
