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

const Color _panel = Color(0xE617191C);
const Color _foreground = Color(0xFFF7F7F8);
const Color _secondary = Color(0xFFBEC1C7);
const Color _accent = Color(0xFFFFA43A);

/// Package-private overlay for one video session.
final class VideoPlayerChrome extends StatefulWidget {
  const VideoPlayerChrome({
    required this.snapshot,
    required this.reduceMotion,
    required this.onExit,
    required this.onPlayOrPause,
    required this.onSeek,
    required this.onSkip,
    required this.onRate,
    required this.onFit,
    required this.onEpisodes,
    required this.onFullscreen,
    super.key,
  });

  final VideoPlayerSnapshot snapshot;
  final bool reduceMotion;
  final VoidCallback onExit;
  final VoidCallback onPlayOrPause;
  final ValueChanged<Duration> onSeek;
  final ValueChanged<Duration> onSkip;
  final ValueChanged<double> onRate;
  final VoidCallback onFit;
  final VoidCallback onEpisodes;
  final ValueChanged<bool> onFullscreen;

  @override
  State<VideoPlayerChrome> createState() => _VideoPlayerChromeState();
}

final class _VideoPlayerChromeState extends State<VideoPlayerChrome> {
  Duration? _scrubPosition;

  @override
  void didUpdateWidget(covariant VideoPlayerChrome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.snapshot.activeEpisodeId != widget.snapshot.activeEpisodeId) {
      _scrubPosition = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = widget.snapshot;
    return IgnorePointer(
      ignoring: !snapshot.controlsVisible,
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
            SafeArea(
              minimum: const EdgeInsets.all(8),
              child: Column(
                children: <Widget>[
                  _TopBar(
                    title: snapshot.title,
                    fullscreen: snapshot.fullscreenRequested,
                    onExit: widget.onExit,
                    onFullscreen: widget.onFullscreen,
                  ),
                  Expanded(
                    child: Center(
                      child: _TransportControls(
                        playing: snapshot.playing,
                        onPlayOrPause: widget.onPlayOrPause,
                        onSkip: widget.onSkip,
                      ),
                    ),
                  ),
                  _buildBottomControls(context),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomControls(BuildContext context) {
    final snapshot = widget.snapshot;
    final Duration duration = snapshot.duration;
    final Duration shownPosition = _scrubPosition ?? snapshot.position;
    final double max = duration.inMilliseconds <= 0
        ? 1
        : duration.inMilliseconds.toDouble();
    final double value = shownPosition.inMilliseconds
        .clamp(0, max.toInt())
        .toDouble();
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool compact = constraints.maxWidth < 520;
        final slider = Row(
          children: <Widget>[
            SizedBox(
              width: 48,
              child: Text(
                _formatDuration(shownPosition),
                textAlign: TextAlign.end,
                style: _timeStyle,
              ),
            ),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: _accent,
                  inactiveTrackColor: Colors.white24,
                  thumbColor: _accent,
                  overlayColor: _accent.withValues(alpha: .16),
                  trackHeight: 3,
                ),
                child: Slider(
                  key: const Key('video-player-slider'),
                  value: value,
                  max: max,
                  onChanged: (double next) => setState(
                    () => _scrubPosition = Duration(milliseconds: next.round()),
                  ),
                  onChangeEnd: (double next) {
                    final position = Duration(milliseconds: next.round());
                    setState(() => _scrubPosition = null);
                    widget.onSeek(position);
                  },
                ),
              ),
            ),
            SizedBox(
              width: 48,
              child: Text(_formatDuration(duration), style: _timeStyle),
            ),
          ],
        );
        final actions = Wrap(
          alignment: compact ? WrapAlignment.spaceBetween : WrapAlignment.end,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 4,
          runSpacing: 2,
          children: <Widget>[
            TextButton.icon(
              key: const Key('video-player-episodes'),
              onPressed: widget.onEpisodes,
              icon: const Icon(Icons.video_library_rounded, size: 19),
              label: Text(_episodeLabel(snapshot)),
            ),
            PopupMenuButton<double>(
              key: const Key('video-player-rate'),
              tooltip: '播放速度',
              initialValue: snapshot.rate,
              onSelected: widget.onRate,
              itemBuilder: (_) => const <PopupMenuEntry<double>>[
                PopupMenuItem<double>(value: .5, child: Text('0.5×')),
                PopupMenuItem<double>(value: .75, child: Text('0.75×')),
                PopupMenuItem<double>(value: 1, child: Text('1.0×')),
                PopupMenuItem<double>(value: 1.25, child: Text('1.25×')),
                PopupMenuItem<double>(value: 1.5, child: Text('1.5×')),
                PopupMenuItem<double>(value: 2, child: Text('2.0×')),
              ],
              child: _CompactAction(
                icon: Icons.speed_rounded,
                label: '${_trimRate(snapshot.rate)}×',
              ),
            ),
            TextButton.icon(
              key: const Key('video-player-fit'),
              onPressed: widget.onFit,
              icon: const Icon(Icons.aspect_ratio_rounded, size: 19),
              label: Text(_fitLabel(snapshot.fitMode)),
            ),
          ],
        );
        return Material(
          color: _panel,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
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
          Color(0xC9000000),
          Color(0x00000000),
          Color(0xB8000000),
        ],
        stops: <double>[0, .5, 1],
      ),
    ),
  );
}

final class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.title,
    required this.fullscreen,
    required this.onExit,
    required this.onFullscreen,
  });

  final String title;
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
        icon: const Icon(Icons.arrow_back_rounded),
      ),
      const SizedBox(width: 4),
      Expanded(
        child: Text(
          title,
          key: const Key('video-player-title'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            color: _foreground,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      IconButton(
        key: const Key('video-player-fullscreen'),
        tooltip: fullscreen ? '退出全屏' : '进入全屏',
        onPressed: () => onFullscreen(!fullscreen),
        icon: Icon(
          fullscreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
        ),
      ),
    ],
  );
}

final class _TransportControls extends StatelessWidget {
  const _TransportControls({
    required this.playing,
    required this.onPlayOrPause,
    required this.onSkip,
  });

  final bool playing;
  final VoidCallback onPlayOrPause;
  final ValueChanged<Duration> onSkip;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.black45,
    borderRadius: BorderRadius.circular(999),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        IconButton(
          key: const Key('video-player-rewind'),
          tooltip: '后退 10 秒',
          onPressed: () => onSkip(const Duration(seconds: -10)),
          icon: const Icon(Icons.replay_10_rounded),
        ),
        IconButton.filled(
          key: const Key('video-player-play-toggle'),
          tooltip: playing ? '暂停' : '播放',
          onPressed: onPlayOrPause,
          iconSize: 32,
          style: IconButton.styleFrom(
            backgroundColor: _foreground,
            foregroundColor: const Color(0xFF111214),
          ),
          icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
        ),
        IconButton(
          key: const Key('video-player-forward'),
          tooltip: '前进 10 秒',
          onPressed: () => onSkip(const Duration(seconds: 10)),
          icon: const Icon(Icons.forward_10_rounded),
        ),
      ],
    ),
  );
}

final class _CompactAction extends StatelessWidget {
  const _CompactAction({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(icon, size: 19),
        const SizedBox(width: 6),
        Text(label),
      ],
    ),
  );
}

/// Shows the package-owned episode selector and returns a stable episode ID.
Future<String?> showVideoEpisodeSheet({
  required BuildContext context,
  required List<VideoEpisode> episodes,
  required String? activeEpisodeId,
}) => showModalBottomSheet<String>(
  context: context,
  backgroundColor: const Color(0xFF17191C),
  useSafeArea: true,
  showDragHandle: true,
  builder: (BuildContext context) => ConstrainedBox(
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height * .72,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
          child: Text(
            '选集',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(color: _foreground),
          ),
        ),
        Expanded(
          child: ListView.separated(
            itemCount: episodes.length,
            separatorBuilder: (_, _) =>
                const Divider(height: 1, color: Colors.white10),
            itemBuilder: (BuildContext context, int index) {
              final episode = episodes[index];
              final selected = episode.id == activeEpisodeId;
              return ListTile(
                key: Key('video-player-episode-${episode.id}'),
                selected: selected,
                selectedColor: _accent,
                textColor: _foreground,
                iconColor: _secondary,
                leading: Icon(
                  selected
                      ? Icons.play_circle_fill_rounded
                      : Icons.play_circle_outline_rounded,
                ),
                title: Text(
                  episode.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => Navigator.of(context).pop(episode.id),
              );
            },
          ),
        ),
      ],
    ),
  ),
);

const TextStyle _timeStyle = TextStyle(
  color: _secondary,
  fontSize: 11,
  fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
);

String _episodeLabel(VideoPlayerSnapshot snapshot) {
  for (final episode in snapshot.episodes) {
    if (episode.id == snapshot.activeEpisodeId) return episode.title;
  }
  return '选集';
}

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
