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
import 'audio_player_glass.dart';
import 'audio_player_motion.dart';
import 'audio_player_theme.dart';

final class AudioPlayerTopBar extends StatelessWidget {
  const AudioPlayerTopBar({
    required this.collectionTitle,
    required this.queueCount,
    required this.playing,
    required this.buffering,
    required this.disableAnimations,
    required this.onBack,
    required this.onQueue,
    super.key,
  });

  final String? collectionTitle;
  final int queueCount;
  final bool playing;
  final bool buffering;
  final bool disableAnimations;
  final VoidCallback onBack;
  final VoidCallback onQueue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 44,
      child: Row(
        children: <Widget>[
          _TopBarButton(
            key: const Key('audio-back'),
            tooltip: '返回',
            onPressed: onBack,
            icon: Icons.arrow_back_ios_new_rounded,
          ),
          Expanded(
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  AudioPlayingIndicator(
                    playing: playing,
                    buffering: buffering,
                    disableAnimations: disableAnimations,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    buffering ? '正在缓冲' : '正在播放',
                    maxLines: 1,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: AudioPlayerColors.muted,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1.1,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              _TopBarButton(
                key: const Key('audio-queue'),
                tooltip: '章节列表，共 $queueCount 集',
                onPressed: onQueue,
                icon: Icons.more_horiz_rounded,
              ),
              if (queueCount > 0)
                Positioned(
                  top: 6,
                  right: 5,
                  child: Container(
                    key: const Key('audio-queue-indicator'),
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                      color: AudioPlayerColors.ink,
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
    return AudioGlassPanel(
      borderRadius: BorderRadius.circular(22),
      blur: 16,
      shadow: false,
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        style: IconButton.styleFrom(
          fixedSize: const Size.square(44),
          foregroundColor: AudioPlayerColors.ink,
        ),
        icon: Icon(icon, size: 20),
      ),
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
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 4, 14, 5),
          child: Column(
            children: <Widget>[
              DecoratedBox(
                key: const Key('audio-track-position'),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.07),
                  borderRadius: BorderRadius.circular(99),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.12),
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
                      color: AudioPlayerColors.muted,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 13),
              Text(
                track.collectionTitle ?? snapshot.collectionTitle ?? '音频播放',
                key: const Key('audio-track-title'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontSize: 30,
                  color: AudioPlayerColors.ink,
                  fontWeight: FontWeight.w700,
                  height: 1.1,
                  letterSpacing: -0.4,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                track.title,
                key: const Key('audio-current-title'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: AudioPlayerColors.muted,
                  height: 1.32,
                ),
              ),
              if (creator?.trim().isNotEmpty == true) ...<Widget>[
                const SizedBox(height: 6),
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
      ),
    );
  }
}

final class AudioProgressControl extends StatefulWidget {
  const AudioProgressControl({
    required this.position,
    required this.duration,
    required this.enabled,
    required this.playing,
    required this.buffering,
    required this.dragging,
    required this.disableAnimations,
    required this.onChanged,
    required this.onChangeEnd,
    super.key,
  });

  final Duration position;
  final Duration duration;
  final bool enabled;
  final bool playing;
  final bool buffering;
  final bool dragging;
  final bool disableAnimations;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  @override
  State<AudioProgressControl> createState() => _AudioProgressControlState();
}

class _AudioProgressControlState extends State<AudioProgressControl>
    with SingleTickerProviderStateMixin {
  late final AnimationController _glowController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1700),
  );

  bool get _glowActive =>
      widget.playing && !widget.buffering && !widget.disableAnimations;

  @override
  void initState() {
    super.initState();
    _syncGlow();
  }

  @override
  void didUpdateWidget(AudioProgressControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playing != widget.playing ||
        oldWidget.buffering != widget.buffering ||
        oldWidget.disableAnimations != widget.disableAnimations) {
      _syncGlow();
    }
  }

  void _syncGlow() {
    if (_glowActive) {
      _glowController.repeat(reverse: true);
    } else {
      _glowController.stop();
      _glowController.value = 0;
    }
  }

  @override
  void dispose() {
    _glowController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final durationMs = widget.duration.inMilliseconds
        .clamp(1, 1 << 62)
        .toDouble();
    final currentMs = widget.position.inMilliseconds
        .clamp(0, durationMs.round())
        .toDouble();
    return Column(
      children: <Widget>[
        Semantics(
          label: '播放进度',
          value:
              '${formatAudioDuration(widget.position)} / ${formatAudioDuration(widget.duration)}',
          child: AnimatedBuilder(
            animation: _glowController,
            builder: (context, child) => SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                activeTrackColor: AudioPlayerColors.accent,
                inactiveTrackColor: AudioPlayerColors.track,
                thumbColor: AudioPlayerColors.accent,
                overlayColor: AudioPlayerColors.accentSoft,
                thumbShape: AudioPlayerProgressThumbShape(
                  pulse: _glowController.value,
                  dragging: widget.dragging,
                ),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
              ),
              child: child!,
            ),
            child: Slider(
              key: const Key('audio-progress-slider'),
              min: 0,
              max: durationMs,
              value: currentMs,
              onChanged: widget.enabled ? widget.onChanged : null,
              onChangeEnd: widget.enabled ? widget.onChangeEnd : null,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              Text(
                formatAudioDuration(widget.position),
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: AudioPlayerColors.muted,
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
              Text(
                formatAudioDuration(widget.duration),
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

final class AudioSettingsLauncher extends StatelessWidget {
  const AudioSettingsLauncher({
    required this.snapshot,
    required this.onQueue,
    required this.onPressed,
    this.compact = false,
    super.key,
  });

  final AudioPlayerSnapshot snapshot;
  final VoidCallback onQueue;
  final VoidCallback onPressed;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final timer = snapshot.sleepTimerDuration;
    final radius = BorderRadius.circular(AudioPlayerMetrics.controlRadius);
    return AudioGlassPanel(
      key: const Key('audio-settings-glass'),
      borderRadius: radius,
      blur: 16,
      child: Semantics(
        button: true,
        label: '快捷播放控制',
        child: Material(
          color: Colors.transparent,
          borderRadius: radius,
          child: InkWell(
            borderRadius: radius,
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: compact ? 5 : 8,
                vertical: compact ? 8 : 10,
              ),
              child: Row(
                children: <Widget>[
                  _QuickAction(
                    key: const Key('audio-quick-queue'),
                    icon: Icons.format_list_bulleted_rounded,
                    label: '播放列表',
                    onPressed: onQueue,
                  ),
                  _QuickAction(
                    key: const Key('audio-quick-rate'),
                    icon: Icons.speed_rounded,
                    label: '${formatAudioRate(snapshot.rate)}x',
                    onPressed: onPressed,
                  ),
                  _QuickAction(
                    key: const Key('audio-quick-timer'),
                    icon: Icons.timer_outlined,
                    label: timer == null ? '定时关闭' : '${timer.inMinutes} 分钟',
                    onPressed: onPressed,
                  ),
                  _QuickAction(
                    key: const Key('audio-settings'),
                    icon: Icons.tune_rounded,
                    label: '播放设置',
                    onPressed: onPressed,
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

class _QuickAction extends StatelessWidget {
  const _QuickAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Expanded(
    child: InkResponse(
      onTap: onPressed,
      radius: 30,
      child: SizedBox(
        height: 52,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(icon, size: 20, color: AudioPlayerColors.ink),
            const SizedBox(height: 4),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: AudioPlayerColors.muted),
            ),
          ],
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
    return AudioGlassPanel(
      key: const Key('audio-inline-failure'),
      padding: const EdgeInsets.fromLTRB(14, 11, 8, 11),
      borderRadius: BorderRadius.circular(18),
      tone: AudioGlassTone.warning,
      shadow: false,
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
