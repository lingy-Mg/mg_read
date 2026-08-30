/// Reusable visual components for the spoken-audio player page.
///
/// Responsibilities:
/// - Render the immersive cover stage, metadata and transport controls.
/// - Keep interaction semantics and stable test keys close to their widgets.
///
/// Notes:
/// - Components receive projected state and callbacks; they own no session.
library;

import 'package:flutter/material.dart';

import '../api/audio_models.dart';
import 'audio_player_theme.dart';

final class AudioPlayerTopBar extends StatelessWidget {
  const AudioPlayerTopBar({
    required this.collectionTitle,
    required this.queueCount,
    required this.onBack,
    required this.onQueue,
    super.key,
  });

  final String? collectionTitle;
  final int queueCount;
  final VoidCallback onBack;
  final VoidCallback onQueue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 60,
      child: Row(
        children: <Widget>[
          _TopBarButton(
            key: const Key('audio-back'),
            tooltip: '返回',
            onPressed: onBack,
            icon: Icons.arrow_back_ios_new_rounded,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Text(
                  '正在播放',
                  maxLines: 1,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: AudioPlayerColors.accent,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  collectionTitle?.trim().isNotEmpty == true
                      ? collectionTitle!
                      : '音频播放',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: AudioPlayerColors.ink,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              _TopBarButton(
                key: const Key('audio-queue'),
                tooltip: '章节列表，共 $queueCount 集',
                onPressed: onQueue,
                icon: Icons.format_list_bulleted_rounded,
              ),
              if (queueCount > 0)
                Positioned(
                  top: 5,
                  right: 3,
                  child: Container(
                    key: const Key('audio-queue-indicator'),
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: AudioPlayerColors.accent,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TopBarButton extends StatelessWidget {
  const _TopBarButton({
    required this.tooltip,
    required this.onPressed,
    required this.icon,
    super.key,
  });

  final String tooltip;
  final VoidCallback onPressed;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        fixedSize: const Size.square(44),
        backgroundColor: AudioPlayerColors.surface.withValues(alpha: 0.9),
        foregroundColor: AudioPlayerColors.ink,
        side: const BorderSide(color: AudioPlayerColors.divider),
        shadowColor: AudioPlayerColors.shadow,
        elevation: 2,
      ),
      icon: Icon(icon, size: 20),
    );
  }
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
        onTap: onDetails,
        borderRadius: BorderRadius.circular(18),
        child: Column(
          children: <Widget>[
            DecoratedBox(
              key: const Key('audio-track-position'),
              decoration: BoxDecoration(
                color: AudioPlayerColors.accentSoft.withValues(alpha: 0.64),
                borderRadius: BorderRadius.circular(99),
                border: Border.all(
                  color: AudioPlayerColors.accent.withValues(alpha: 0.22),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 13,
                  vertical: 5,
                ),
                child: Text(
                  '第 ${displayedIndex + 1} 集  ·  共 ${snapshot.queueEntries.length} 集',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: AudioPlayerColors.accentPressed,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              track.title,
              key: const Key('audio-track-title'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                fontSize: 18,
                color: AudioPlayerColors.ink,
                fontWeight: FontWeight.w800,
                height: 1.24,
                letterSpacing: -0.1,
              ),
            ),
            if (creator?.trim().isNotEmpty == true) ...<Widget>[
              const SizedBox(height: 7),
              Text(
                creator!,
                key: const Key('audio-track-creator'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: AudioPlayerColors.muted,
                ),
              ),
            ],
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
    required this.onChanged,
    required this.onChangeEnd,
    super.key,
  });

  final Duration position;
  final Duration duration;
  final bool enabled;
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
              trackHeight: 5,
              activeTrackColor: AudioPlayerColors.accent,
              inactiveTrackColor: AudioPlayerColors.track,
              thumbColor: AudioPlayerColors.accent,
              overlayColor: AudioPlayerColors.accentSoft,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
            ),
            child: Slider(
              key: const Key('audio-progress-slider'),
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
      children: <Widget>[
        _TransportButton(
          key: const Key('audio-previous'),
          tooltip: '上一集',
          onPressed: snapshot.canGoPrevious ? onPrevious : null,
          icon: const Icon(Icons.skip_previous_rounded, size: 25),
        ),
        _TransportButton(
          key: const Key('audio-seek-back'),
          tooltip: '后退 15 秒',
          onPressed: onBackFifteen,
          icon: const _SeekFifteenIcon(),
        ),
        SizedBox.square(
          dimension: 74,
          child: FilledButton(
            key: const Key('audio-play-pause'),
            style: FilledButton.styleFrom(
              shape: const CircleBorder(),
              padding: EdgeInsets.zero,
              backgroundColor: AudioPlayerColors.accent,
              foregroundColor: Colors.white,
              shadowColor: AudioPlayerColors.shadow,
              elevation: 8,
            ),
            onPressed: onToggle,
            child: AnimatedSwitcher(
              duration: disableAnimations
                  ? Duration.zero
                  : const Duration(milliseconds: 160),
              child: snapshot.buffering
                  ? const SizedBox.square(
                      key: Key('audio-buffering'),
                      dimension: 26,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.6,
                        color: Colors.white,
                      ),
                    )
                  : Icon(
                      snapshot.playing
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      key: ValueKey<bool>(snapshot.playing),
                      size: 40,
                    ),
            ),
          ),
        ),
        _TransportButton(
          key: const Key('audio-seek-forward'),
          tooltip: '前进 15 秒',
          onPressed: onForwardFifteen,
          icon: const _SeekFifteenIcon(forward: true),
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
            size: 28,
          ),
          Text(
            '15',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              fontSize: 8.5,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

final class AudioSettingsLauncher extends StatelessWidget {
  const AudioSettingsLauncher({
    required this.snapshot,
    required this.onPressed,
    this.compact = false,
    super.key,
  });

  final AudioPlayerSnapshot snapshot;
  final VoidCallback onPressed;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final timer = snapshot.sleepTimerDuration;
    final summary = <String>[
      '${formatAudioRate(snapshot.rate)}x',
      formatAudioVolume(snapshot.volume),
      if (timer != null) '${timer.inMinutes} 分钟',
    ].join('  ·  ');
    final radius = BorderRadius.circular(AudioPlayerMetrics.controlRadius);
    return Container(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: AudioPlayerColors.shadow,
            blurRadius: 20,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Semantics(
        button: true,
        label: '播放设置，$summary',
        child: Material(
          color: AudioPlayerColors.surface.withValues(alpha: 0.97),
          borderRadius: radius,
          child: InkWell(
            key: const Key('audio-settings'),
            onTap: onPressed,
            borderRadius: radius,
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: compact ? 13 : 15,
                vertical: compact ? 8 : 10,
              ),
              child: Row(
                children: <Widget>[
                  DecoratedBox(
                    decoration: const BoxDecoration(
                      color: AudioPlayerColors.accentSoft,
                      shape: BoxShape.circle,
                    ),
                    child: SizedBox.square(
                      dimension: compact ? 31 : 34,
                      child: const Icon(
                        Icons.tune_rounded,
                        size: 19,
                        color: AudioPlayerColors.accent,
                      ),
                    ),
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Text(
                      '播放设置',
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: AudioPlayerColors.ink,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Text(
                    summary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AudioPlayerColors.muted,
                    ),
                  ),
                  const SizedBox(width: 5),
                  const Icon(
                    Icons.chevron_right_rounded,
                    size: 21,
                    color: AudioPlayerColors.subtle,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
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
    return Container(
      key: const Key('audio-inline-failure'),
      padding: const EdgeInsets.fromLTRB(14, 11, 8, 11),
      decoration: BoxDecoration(
        color: AudioPlayerColors.warningSoft,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: <Widget>[
          const Icon(
            Icons.error_outline_rounded,
            color: AudioPlayerColors.warning,
            size: 20,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              failure.message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: AudioPlayerColors.warning),
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}
