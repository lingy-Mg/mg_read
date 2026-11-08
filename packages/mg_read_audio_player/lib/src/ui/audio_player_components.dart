/// Reusable visual components for the spoken-audio player page.
///
/// Responsibilities:
/// - Render unboxed navigation, track-first metadata and transport controls.
/// - Keep interaction semantics and stable test keys close to their widgets.
///
/// Notes:
/// - Components receive projected state and callbacks; they own no session.
library;

import 'package:flutter/material.dart';

import '../api/audio_models.dart';
import 'audio_player_surface.dart';
import 'audio_player_motion.dart';
import 'audio_player_theme.dart';

final class AudioPlayerTopBar extends StatelessWidget {
  const AudioPlayerTopBar({
    required this.collectionTitle,
    required this.playing,
    required this.buffering,
    required this.disableAnimations,
    required this.onBack,
    required this.onDetails,
    super.key,
  });

  final String? collectionTitle;
  final bool playing;
  final bool buffering;
  final bool disableAnimations;
  final VoidCallback onBack;
  final VoidCallback onDetails;

  @override
  Widget build(BuildContext context) => Row(
    children: <Widget>[
      IconButton(
        key: const Key('audio-back'),
        tooltip: '收起播放器',
        onPressed: onBack,
        icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 30),
      ),
      Expanded(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                AudioPlayingIndicator(
                  playing: playing,
                  buffering: buffering,
                  disableAnimations: disableAnimations,
                ),
                const SizedBox(width: 7),
                Text(
                  buffering
                      ? '正在缓冲'
                      : playing
                      ? '正在播放'
                      : '已暂停',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: AudioPlayerColors.muted,
                    letterSpacing: 1.4,
                  ),
                ),
              ],
            ),
            if (collectionTitle?.trim().isNotEmpty == true) ...<Widget>[
              const SizedBox(height: 4),
              Text(
                collectionTitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: AudioPlayerColors.ink,
                ),
              ),
            ],
          ],
        ),
      ),
      IconButton(
        key: const Key('audio-more'),
        tooltip: '音频详情',
        onPressed: onDetails,
        icon: const Icon(Icons.more_horiz_rounded, size: 26),
      ),
    ],
  );
}

final class AudioPlayerMetadata extends StatelessWidget {
  const AudioPlayerMetadata({
    required this.snapshot,
    required this.track,
    required this.onDetails,
    super.key,
  });

  final AudioPlayerSnapshot snapshot;
  final AudioTrack track;
  final VoidCallback onDetails;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final creator = track.creator ?? snapshot.creator;
    final catalogIndex = snapshot.queueEntries.indexWhere(
      (entry) => entry.id == track.id,
    );
    final displayedIndex = catalogIndex >= 0
        ? catalogIndex
        : snapshot.currentIndex;
    return Semantics(
      button: true,
      label: '查看音频详情',
      child: InkWell(
        key: const Key('audio-details-open'),
        borderRadius: BorderRadius.circular(8),
        onTap: onDetails,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              track.title,
              key: const Key('audio-track-title'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontSize: 25,
                color: AudioPlayerColors.ink,
                fontWeight: FontWeight.w600,
                height: 1.22,
                letterSpacing: -0.6,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    creator?.trim().isNotEmpty == true ? creator! : '音频播放',
                    key: const Key('audio-track-creator'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: AudioPlayerColors.muted,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    '第 ${displayedIndex + 1} 集  ·  共 ${snapshot.queueEntries.length} 集',
                    key: const Key('audio-track-position'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: AudioPlayerColors.muted,
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

final class AudioProgressControl extends StatelessWidget {
  const AudioProgressControl({
    required this.position,
    required this.duration,
    required this.enabled,
    required this.dragging,
    required this.onChanged,
    required this.onChangeEnd,
    super.key,
  });

  final Duration position;
  final Duration duration;
  final bool enabled;
  final bool dragging;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final durationMs = duration.inMilliseconds.clamp(1, 1 << 62).toDouble();
    final currentMs = position.inMilliseconds
        .clamp(0, durationMs.round())
        .toDouble();
    return Column(
      children: <Widget>[
        Semantics(
          label: '播放进度',
          value:
              '${formatAudioDuration(position)} / ${formatAudioDuration(duration)}',
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              activeTrackColor: AudioPlayerColors.accent,
              inactiveTrackColor: AudioPlayerColors.track,
              thumbColor: AudioPlayerColors.accent,
              overlayColor: AudioPlayerColors.accentSoft,
              thumbShape: AudioPlayerProgressThumbShape(
                pulse: 0,
                dragging: dragging,
              ),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            ),
            child: Slider(
              key: const Key('audio-progress-slider'),
              padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 4),
              min: 0,
              max: durationMs,
              value: currentMs,
              onChanged: enabled ? onChanged : null,
              onChangeEnd: enabled ? onChangeEnd : null,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              Text(
                formatAudioDuration(position),
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: AudioPlayerColors.muted,
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
              Text(
                formatAudioDuration(duration),
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: AudioPlayerColors.muted,
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

final class AudioTransportControls extends StatelessWidget {
  const AudioTransportControls({
    required this.snapshot,
    required this.disableAnimations,
    required this.onPrevious,
    required this.onBackFifteen,
    required this.onToggle,
    required this.onForwardFifteen,
    required this.onNext,
    super.key,
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
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        _TransportButton(
          key: const Key('audio-previous'),
          tooltip: '上一集',
          onPressed: snapshot.canGoPrevious ? onPrevious : null,
          icon: const Icon(Icons.skip_previous_rounded, size: 25),
        ),
        AudioAnimatedSeekButton(
          key: const Key('audio-seek-back'),
          tooltip: '后退 15 秒',
          forward: false,
          disableAnimations: disableAnimations,
          onPressed: onBackFifteen,
        ),
        AudioAnimatedPlayPauseButton(
          snapshot: snapshot,
          disableAnimations: disableAnimations,
          onPressed: onToggle,
        ),
        AudioAnimatedSeekButton(
          key: const Key('audio-seek-forward'),
          tooltip: '前进 15 秒',
          forward: true,
          disableAnimations: disableAnimations,
          onPressed: onForwardFifteen,
        ),
        _TransportButton(
          key: const Key('audio-next'),
          tooltip: '下一集',
          onPressed: snapshot.canGoNext ? onNext : null,
          icon: const Icon(Icons.skip_next_rounded, size: 25),
        ),
      ],
    );
  }
}

class _TransportButton extends StatelessWidget {
  const _TransportButton({
    required this.tooltip,
    required this.onPressed,
    required this.icon,
    super.key,
  });

  final String tooltip;
  final VoidCallback? onPressed;
  final Widget icon;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      constraints: const BoxConstraints.tightFor(
        width: AudioPlayerMetrics.minimumTapTarget,
        height: AudioPlayerMetrics.minimumTapTarget,
      ),
      padding: EdgeInsets.zero,
      color: AudioPlayerColors.ink,
      disabledColor: AudioPlayerColors.disabled,
      icon: icon,
    );
  }
}

/// Unboxed shortcuts; speed and timer open their own settings section.
final class AudioSettingsLauncher extends StatelessWidget {
  const AudioSettingsLauncher({
    required this.snapshot,
    required this.onQueue,
    required this.onRate,
    required this.onTimer,
    required this.onPressed,
    super.key,
  });

  final AudioPlayerSnapshot snapshot;
  final VoidCallback onQueue;
  final VoidCallback onRate;
  final VoidCallback onTimer;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final timer = snapshot.sleepTimerDuration;
    return Row(
      key: const Key('audio-shortcuts'),
      children: <Widget>[
        _QuickAction(
          key: const Key('audio-queue'),
          icon: Icons.queue_music_rounded,
          label: '播放列表',
          onPressed: onQueue,
        ),
        _QuickAction(
          key: const Key('audio-quick-rate'),
          icon: Icons.speed_rounded,
          label: '${formatAudioRate(snapshot.rate)}×',
          onPressed: onRate,
        ),
        _QuickAction(
          key: const Key('audio-quick-timer'),
          icon: timer == null ? Icons.bedtime_outlined : Icons.bedtime_rounded,
          label: timer == null ? '定时关闭' : '${timer.inMinutes} 分钟',
          active: timer != null,
          onPressed: onTimer,
        ),
        _QuickAction(
          key: const Key('audio-settings'),
          icon: Icons.tune_rounded,
          label: '播放设置',
          onPressed: onPressed,
        ),
      ],
    );
  }
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.active = false,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool active;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Tooltip(
      message: label,
      child: Semantics(
        button: true,
        label: label,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  icon,
                  size: 22,
                  color: active
                      ? AudioPlayerColors.ink
                      : AudioPlayerColors.muted,
                ),
                const SizedBox(height: 6),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: active
                        ? AudioPlayerColors.ink
                        : AudioPlayerColors.muted,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

final class AudioInlineFailure extends StatelessWidget {
  const AudioInlineFailure({
    required this.failure,
    required this.onRetry,
    super.key,
  });

  final AudioPlayerFailure failure;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return AudioSurfacePanel(
      key: const Key('audio-inline-failure'),
      padding: const EdgeInsets.fromLTRB(14, 11, 8, 11),
      borderRadius: BorderRadius.circular(18),
      tone: AudioSurfaceTone.warning,
      child: Row(
        children: <Widget>[
          const Icon(
            Icons.error_outline_rounded,
            color: AudioPlayerColors.warning,
            size: 20,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  failure.message,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AudioPlayerColors.warning,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '发生位置：${failure.location}  ·  诊断编号：${failure.code}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AudioPlayerColors.warning,
                  ),
                ),
                if (failure.debugDetail case final detail?) ...<Widget>[
                  const SizedBox(height: 3),
                  SelectableText(
                    '技术原因：$detail',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AudioPlayerColors.warning,
                    ),
                  ),
                ],
              ],
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}
