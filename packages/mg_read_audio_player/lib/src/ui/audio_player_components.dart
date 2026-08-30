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

import '../api/audio_artwork.dart';
import '../api/audio_models.dart';
import 'audio_player_theme.dart';

final class AudioPlayerAmbientBackground extends StatelessWidget {
  const AudioPlayerAmbientBackground({super.key});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: <Color>[
                  AudioPlayerColors.backgroundTop,
                  AudioPlayerColors.backgroundBottom,
                ],
                stops: <double>[0, 0.78],
              ),
            ),
          ),
          Positioned(
            top: -110,
            left: -95,
            child: _AmbientOrb(
              size: 290,
              color: AudioPlayerColors.accent.withValues(alpha: 0.13),
            ),
          ),
          Positioned(
            top: 210,
            right: -125,
            child: _AmbientOrb(
              size: 320,
              color: const Color(0xFF9F6B52).withValues(alpha: 0.09),
            ),
          ),
        ],
      ),
    );
  }
}

class _AmbientOrb extends StatelessWidget {
  const _AmbientOrb({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: <Color>[color, color.withValues(alpha: 0)],
        ),
      ),
    );
  }
}

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
          Badge.count(
            count: queueCount,
            isLabelVisible: queueCount > 0,
            backgroundColor: AudioPlayerColors.accent,
            textColor: Colors.white,
            offset: const Offset(-1, 1),
            child: _TopBarButton(
              key: const Key('audio-queue'),
              tooltip: '章节列表',
              onPressed: onQueue,
              icon: Icons.format_list_bulleted_rounded,
            ),
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

final class AudioPlayerCover extends StatelessWidget {
  const AudioPlayerCover({
    required this.track,
    required this.artworkBuilder,
    required this.size,
    required this.playing,
    required this.disableAnimations,
    super.key,
  });

  final AudioTrack track;
  final AudioArtworkBuilder? artworkBuilder;
  final double size;
  final bool playing;
  final bool disableAnimations;

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      key: const Key('audio-cover'),
      scale: playing ? 1 : 0.975,
      duration: disableAnimations
          ? Duration.zero
          : const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      child: Container(
        width: size,
        height: size,
        padding: const EdgeInsets.all(5),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.82),
          borderRadius: BorderRadius.circular(34),
          border: Border.all(color: Colors.white.withValues(alpha: 0.9)),
          boxShadow: const <BoxShadow>[
            BoxShadow(
              color: AudioPlayerColors.shadow,
              blurRadius: 36,
              spreadRadius: 2,
              offset: Offset(0, 18),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(29),
          child:
              artworkBuilder?.call(context, track) ??
              const AudioPlayerCoverPlaceholder(),
        ),
      ),
    );
  }
}

final class AudioPlayerCoverPlaceholder extends StatelessWidget {
  const AudioPlayerCoverPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            AudioPlayerColors.coverStart,
            AudioPlayerColors.coverEnd,
          ],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          Positioned(
            top: -38,
            right: -34,
            child: Container(
              width: 150,
              height: 150,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: 0.10),
              ),
            ),
          ),
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Icon(
                  Icons.headphones_rounded,
                  size: 64,
                  color: Color(0xFFFFF7EB),
                ),
                const SizedBox(height: 14),
                Text(
                  'MGREAD AUDIO',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Colors.white.withValues(alpha: 0.86),
                    fontWeight: FontWeight.w800,
                    letterSpacing: 2.2,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

final class AudioPlayerMetadata extends StatelessWidget {
  const AudioPlayerMetadata({
    required this.snapshot,
    required this.track,
    super.key,
  });

  final AudioPlayerSnapshot snapshot;
  final AudioTrack track;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final creator = track.creator ?? snapshot.creator;
    return Column(
      children: <Widget>[
        Text(
          '第 ${snapshot.currentIndex + 1} 集  ·  共 ${snapshot.queueEntries.length} 集',
          style: theme.textTheme.labelMedium?.copyWith(
            color: AudioPlayerColors.accent,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 7),
        Text(
          track.title,
          key: const Key('audio-track-title'),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: theme.textTheme.titleLarge?.copyWith(
            color: AudioPlayerColors.ink,
            fontWeight: FontWeight.w800,
            height: 1.22,
            letterSpacing: -0.2,
          ),
        ),
        if (creator?.trim().isNotEmpty == true) ...<Widget>[
          const SizedBox(height: 7),
          Text(
            creator!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: AudioPlayerColors.muted,
            ),
          ),
        ],
      ],
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
    super.key,
  });

  final AudioPlayerSnapshot snapshot;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final timer = snapshot.sleepTimerDuration;
    final summary = <String>[
      '${formatAudioRate(snapshot.rate)}x',
      formatAudioVolume(snapshot.volume),
      if (timer != null) '${timer.inMinutes} 分钟',
    ].join('  ·  ');
    return Semantics(
      button: true,
      label: '播放设置，$summary',
      child: Material(
        color: AudioPlayerColors.control,
        borderRadius: BorderRadius.circular(AudioPlayerMetrics.controlRadius),
        child: InkWell(
          key: const Key('audio-settings'),
          onTap: onPressed,
          borderRadius: BorderRadius.circular(AudioPlayerMetrics.controlRadius),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: <Widget>[
                const DecoratedBox(
                  decoration: BoxDecoration(
                    color: AudioPlayerColors.surfaceStrong,
                    shape: BoxShape.circle,
                  ),
                  child: SizedBox.square(
                    dimension: 34,
                    child: Icon(
                      Icons.tune_rounded,
                      size: 19,
                      color: AudioPlayerColors.accent,
                    ),
                  ),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        '播放设置',
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: AudioPlayerColors.ink,
                          fontWeight: FontWeight.w700,
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
                    ],
                  ),
                ),
                const Icon(
                  Icons.chevron_right_rounded,
                  color: AudioPlayerColors.subtle,
                ),
              ],
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
