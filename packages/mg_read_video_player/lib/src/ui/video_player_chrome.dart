/// Package-private dark chrome and episode selector for the video player.
///
/// Responsibilities:
/// - Render accessible playback controls over the engine-owned video surface.
/// - Adapt controls to narrow windows and bounded system text scaling.
///
/// Notes:
/// - This file emits semantic callbacks only and never touches a playback engine.
/// - Fullscreen buttons express host intent; they do not mutate system UI.
library;

// Cross-file UI helpers are intentionally package-private despite Dart's
// library-level public naming rules.
// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';

import '../api/models.dart';
import 'video_player_visuals.dart';

/// Package-private overlay for one video session.
final class VideoPlayerChrome extends StatefulWidget {
  const VideoPlayerChrome({
    required this.snapshot,
    required this.reduceMotion,
    required this.seekPreviewPosition,
    required this.onExit,
    required this.onSeekPreviewChanged,
    required this.onSeekPreviewEnded,
    required this.onSeekPreviewCanceled,
    required this.onRate,
    required this.onFit,
    required this.onEpisodes,
    required this.onFullscreen,
    required this.onPreviousEpisode,
    required this.onNextEpisode,
    required this.onAutoAdvance,
    required this.onInteractionStart,
    required this.onInteractionEnd,
    super.key,
  });

  final VideoPlayerSnapshot snapshot;
  final bool reduceMotion;
  final Duration? seekPreviewPosition;
  final VoidCallback onExit;
  final ValueChanged<Duration> onSeekPreviewChanged;
  final ValueChanged<Duration> onSeekPreviewEnded;
  final VoidCallback onSeekPreviewCanceled;
  final ValueChanged<double> onRate;
  final VoidCallback onFit;
  final VoidCallback onEpisodes;
  final ValueChanged<bool> onFullscreen;
  final VoidCallback onPreviousEpisode;
  final VoidCallback onNextEpisode;
  final ValueChanged<bool> onAutoAdvance;
  final VoidCallback onInteractionStart;
  final VoidCallback onInteractionEnd;

  @override
  State<VideoPlayerChrome> createState() => _VideoPlayerChromeState();
}

final class _VideoPlayerChromeState extends State<VideoPlayerChrome> {
  @override
  Widget build(BuildContext context) {
    final snapshot = widget.snapshot;
    return IgnorePointer(
      ignoring: !snapshot.controlsVisible,
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
          curve: Curves.easeOut,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              const IgnorePointer(child: _ChromeGradient()),
              Column(
                children: <Widget>[
                  VideoPlayerGlassPanel(
                    key: const Key('video-player-top-band'),
                    borderRadius: BorderRadius.zero,
                    padding: EdgeInsets.only(
                      top: MediaQuery.paddingOf(context).top,
                    ),
                    showBorder: false,
                    showShadow: false,
                    blurSigma: 22,
                    child: _TopBar(
                      title: snapshot.title,
                      subtitle: _episodeLabel(snapshot),
                      fullscreen: snapshot.fullscreenRequested,
                      onExit: widget.onExit,
                      onFullscreen: widget.onFullscreen,
                    ),
                  ),
                  const Expanded(child: SizedBox.shrink()),
                  _buildBottomControls(context),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomControls(BuildContext context) {
    final snapshot = widget.snapshot;
    final Duration duration = snapshot.duration;
    final Duration shownPosition =
        widget.seekPreviewPosition ?? snapshot.position;
    final double max = duration.inMilliseconds <= 0
        ? 1
        : duration.inMilliseconds.toDouble();
    final double value = shownPosition.inMilliseconds
        .clamp(0, max.toInt())
        .toDouble();
    final double buffered = snapshot.bufferedPosition.inMilliseconds
        .clamp(0, max.toInt())
        .toDouble();
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool compact = constraints.maxWidth < 680;
        final bool iconsOnly =
            constraints.maxWidth < 480 ||
            MediaQuery.textScalerOf(context).scale(14) > 20;
        final slider = Row(
          children: <Widget>[
            SizedBox(
              width: 44,
              child: FittedBox(
                alignment: Alignment.centerRight,
                fit: BoxFit.scaleDown,
                child: Text(_formatDuration(shownPosition), style: _timeStyle),
              ),
            ),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: videoPlayerAccent,
                  inactiveTrackColor: Colors.white24,
                  thumbColor: videoPlayerAccent,
                  overlayColor: videoPlayerAccent.withValues(alpha: .16),
                  trackHeight: 2.5,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 6,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 12,
                  ),
                ),
                child: Slider(
                  key: const Key('video-player-slider'),
                  value: value,
                  max: max,
                  secondaryTrackValue: buffered < value ? value : buffered,
                  onChangeStart: (_) => widget.onInteractionStart(),
                  onChanged: (double next) => widget.onSeekPreviewChanged(
                    Duration(milliseconds: next.round()),
                  ),
                  onChangeEnd: (double next) {
                    final position = Duration(milliseconds: next.round());
                    widget.onSeekPreviewEnded(position);
                    widget.onInteractionEnd();
                  },
                ),
              ),
            ),
            SizedBox(
              width: 44,
              child: FittedBox(
                alignment: Alignment.centerLeft,
                fit: BoxFit.scaleDown,
                child: Text(_formatDuration(duration), style: _timeStyle),
              ),
            ),
          ],
        );
        final actions = iconsOnly
            ? Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: <Widget>[
                  IconButton(
                    key: const Key('video-player-episodes'),
                    tooltip: '选择 ${_episodeLabel(snapshot)}',
                    onPressed: widget.onEpisodes,
                    style: IconButton.styleFrom(
                      foregroundColor: videoPlayerForeground,
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    icon: const Icon(Icons.video_library_rounded, size: 20),
                  ),
                  IconButton(
                    key: const Key('video-player-previous-episode'),
                    tooltip: '上一集',
                    onPressed:
                        snapshot.hasPreviousEpisode ||
                            snapshot.position >= const Duration(seconds: 5)
                        ? widget.onPreviousEpisode
                        : null,
                    style: IconButton.styleFrom(
                      foregroundColor: videoPlayerForeground,
                      visualDensity: VisualDensity.compact,
                    ),
                    icon: const Icon(Icons.skip_previous_rounded, size: 21),
                  ),
                  IconButton(
                    key: const Key('video-player-next-episode'),
                    tooltip: '下一集',
                    onPressed: snapshot.hasNextEpisode
                        ? widget.onNextEpisode
                        : null,
                    style: IconButton.styleFrom(
                      foregroundColor: videoPlayerForeground,
                      visualDensity: VisualDensity.compact,
                    ),
                    icon: const Icon(Icons.skip_next_rounded, size: 21),
                  ),
                  IconButton(
                    key: const Key('video-player-auto-advance'),
                    tooltip: snapshot.autoAdvance ? '关闭自动连播' : '开启自动连播',
                    onPressed: () =>
                        widget.onAutoAdvance(!snapshot.autoAdvance),
                    style: IconButton.styleFrom(
                      foregroundColor: snapshot.autoAdvance
                          ? videoPlayerAccent
                          : videoPlayerForeground,
                      visualDensity: VisualDensity.compact,
                    ),
                    icon: const Icon(Icons.repeat_rounded, size: 20),
                  ),
                  PopupMenuButton<double>(
                    key: const Key('video-player-rate'),
                    tooltip: '播放速度',
                    initialValue: snapshot.rate,
                    onSelected: widget.onRate,
                    itemBuilder: _rateItems,
                    iconSize: 20,
                    icon: const Icon(
                      Icons.speed_rounded,
                      color: videoPlayerForeground,
                    ),
                  ),
                  IconButton(
                    key: const Key('video-player-fit'),
                    tooltip: '画面比例：${_fitLabel(snapshot.fitMode)}',
                    onPressed: widget.onFit,
                    style: IconButton.styleFrom(
                      foregroundColor: videoPlayerForeground,
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    icon: const Icon(Icons.aspect_ratio_rounded, size: 20),
                  ),
                ],
              )
            : Wrap(
                alignment: compact
                    ? WrapAlignment.spaceBetween
                    : WrapAlignment.end,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 2,
                runSpacing: 0,
                children: <Widget>[
                  TextButton.icon(
                    key: const Key('video-player-episodes'),
                    onPressed: widget.onEpisodes,
                    style: TextButton.styleFrom(
                      foregroundColor: videoPlayerForeground,
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    icon: const Icon(Icons.video_library_rounded, size: 18),
                    label: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 180),
                      child: Text(
                        _episodeLabel(snapshot),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    key: const Key('video-player-previous-episode'),
                    onPressed:
                        snapshot.hasPreviousEpisode ||
                            snapshot.position >= const Duration(seconds: 5)
                        ? widget.onPreviousEpisode
                        : null,
                    style: TextButton.styleFrom(
                      foregroundColor: videoPlayerForeground,
                      visualDensity: VisualDensity.compact,
                    ),
                    icon: const Icon(Icons.skip_previous_rounded, size: 19),
                    label: const Text('上一集'),
                  ),
                  TextButton.icon(
                    key: const Key('video-player-next-episode'),
                    onPressed: snapshot.hasNextEpisode
                        ? widget.onNextEpisode
                        : null,
                    style: TextButton.styleFrom(
                      foregroundColor: videoPlayerForeground,
                      visualDensity: VisualDensity.compact,
                    ),
                    icon: const Icon(Icons.skip_next_rounded, size: 19),
                    label: const Text('下一集'),
                  ),
                  IconButton(
                    key: const Key('video-player-auto-advance'),
                    tooltip: snapshot.autoAdvance ? '自动连播已开启' : '自动连播已关闭',
                    onPressed: () =>
                        widget.onAutoAdvance(!snapshot.autoAdvance),
                    style: IconButton.styleFrom(
                      foregroundColor: snapshot.autoAdvance
                          ? videoPlayerAccent
                          : videoPlayerForeground,
                      visualDensity: VisualDensity.compact,
                    ),
                    icon: const Icon(Icons.repeat_rounded, size: 19),
                  ),
                  PopupMenuButton<double>(
                    key: const Key('video-player-rate'),
                    tooltip: '播放速度',
                    initialValue: snapshot.rate,
                    onSelected: widget.onRate,
                    itemBuilder: _rateItems,
                    child: _CompactAction(
                      icon: Icons.speed_rounded,
                      label: '${_trimRate(snapshot.rate)}×',
                    ),
                  ),
                  TextButton.icon(
                    key: const Key('video-player-fit'),
                    onPressed: widget.onFit,
                    style: TextButton.styleFrom(
                      foregroundColor: videoPlayerForeground,
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    icon: const Icon(Icons.aspect_ratio_rounded, size: 18),
                    label: Text(_fitLabel(snapshot.fitMode)),
                  ),
                ],
              );
        return VideoPlayerGlassPanel(
          key: const Key('video-player-bottom-band'),
          borderRadius: BorderRadius.zero,
          padding: EdgeInsets.fromLTRB(
            8,
            3,
            8,
            4 + MediaQuery.paddingOf(context).bottom,
          ),
          showBorder: false,
          showShadow: false,
          blurSigma: 22,
          child: compact
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[slider, actions],
                )
              : Row(
                  children: <Widget>[
                    Expanded(child: slider),
                    const SizedBox(width: 8),
                    actions,
                  ],
                ),
        );
      },
    );
  }
}

final class _ChromeGradient extends StatelessWidget {
  const _ChromeGradient();

  @override
  Widget build(BuildContext context) => const DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: <Color>[
          Color(0x92000000),
          Color(0x00000000),
          Color(0x92000000),
        ],
        stops: <double>[0, .5, 1],
      ),
    ),
  );
}

final class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.title,
    required this.subtitle,
    required this.fullscreen,
    required this.onExit,
    required this.onFullscreen,
  });

  final String title;
  final String subtitle;
  final bool fullscreen;
  final VoidCallback onExit;
  final ValueChanged<bool> onFullscreen;

  @override
  Widget build(BuildContext context) => Row(
    children: <Widget>[
      IconButton(
        key: const Key('video-player-back'),
        tooltip: '返回',
        onPressed: onExit,
        style: IconButton.styleFrom(
          foregroundColor: videoPlayerForeground,
          visualDensity: VisualDensity.compact,
        ),
        icon: const Icon(Icons.arrow_back_rounded, size: 23),
      ),
      Expanded(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              title,
              key: const Key('video-player-title'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: videoPlayerForeground,
                fontWeight: FontWeight.w600,
                fontSize: 15,
              ),
            ),
            if (subtitle != '选集')
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: videoPlayerSecondary,
                  fontSize: 10,
                ),
              ),
          ],
        ),
      ),
      IconButton(
        key: const Key('video-player-fullscreen'),
        tooltip: fullscreen ? '退出全屏' : '进入全屏',
        onPressed: () => onFullscreen(!fullscreen),
        style: IconButton.styleFrom(
          foregroundColor: videoPlayerForeground,
          visualDensity: VisualDensity.compact,
        ),
        icon: Icon(
          fullscreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
          size: 23,
        ),
      ),
    ],
  );
}

final class _CompactAction extends StatelessWidget {
  const _CompactAction({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(icon, size: 18, color: videoPlayerForeground),
        const SizedBox(width: 5),
        Text(label, style: const TextStyle(color: videoPlayerForeground)),
      ],
    ),
  );
}

const TextStyle _timeStyle = TextStyle(
  color: videoPlayerSecondary,
  fontSize: 11,
  fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
);

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

List<PopupMenuEntry<double>> _rateItems(BuildContext context) =>
    const <PopupMenuEntry<double>>[
      PopupMenuItem<double>(value: .5, child: Text('0.5×')),
      PopupMenuItem<double>(value: .75, child: Text('0.75×')),
      PopupMenuItem<double>(value: 1, child: Text('1.0×')),
      PopupMenuItem<double>(value: 1.25, child: Text('1.25×')),
      PopupMenuItem<double>(value: 1.5, child: Text('1.5×')),
      PopupMenuItem<double>(value: 2, child: Text('2.0×')),
    ];

String _fitLabel(VideoFitMode mode) => switch (mode) {
  VideoFitMode.contain => '适应',
  VideoFitMode.cover => '填充',
  VideoFitMode.stretch => '拉伸',
};

String _trimRate(double rate) => rate == rate.roundToDouble()
    ? rate.toStringAsFixed(0)
    : rate.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '');

String _formatDuration(Duration duration) {
  final int total = duration.inSeconds.clamp(0, 359999);
  final int hours = total ~/ 3600;
  final int minutes = total.remainder(3600) ~/ 60;
  final int seconds = total.remainder(60);
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}
