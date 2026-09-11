/// Playback-driven motion primitives for the audio player surface.
///
/// Responsibilities:
/// - Visualize active playback without changing transport state.
/// - Keep repeated tickers local, pausable and reduced-motion aware.
/// - Preserve stable semantics and test keys around transport controls.
///
/// Notes:
/// - Callbacks remain the only path to the owning audio session.
/// - Decorative controllers stop while paused, buffering or motion-disabled.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../api/audio_models.dart';
import 'audio_player_theme.dart';

final class AudioPlayingIndicator extends StatefulWidget {
  const AudioPlayingIndicator({
    required this.playing,
    required this.buffering,
    required this.disableAnimations,
    super.key,
  });

  final bool playing;
  final bool buffering;
  final bool disableAnimations;

  @override
  State<AudioPlayingIndicator> createState() => _AudioPlayingIndicatorState();
}

class _AudioPlayingIndicatorState extends State<AudioPlayingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 820),
  );

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(AudioPlayingIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playing != widget.playing ||
        oldWidget.buffering != widget.buffering ||
        oldWidget.disableAnimations != widget.disableAnimations) {
      _syncTicker();
    }
  }

  void _syncTicker() {
    if (!widget.disableAnimations && (widget.playing || widget.buffering)) {
      _controller.repeat();
    } else {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: SizedBox(
        key: const Key('audio-playing-indicator'),
        width: 12,
        height: 12,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: List<Widget>.generate(3, (index) {
                final phase = widget.buffering
                    ? _controller.value * math.pi * 2 - index * 1.1
                    : _controller.value * math.pi * 2 + index * 1.72;
                final amount = widget.playing || widget.buffering
                    ? 0.5 + 0.5 * math.sin(phase)
                    : 0.0;
                return Container(
                  key: Key('audio-playing-indicator-bar-$index'),
                  width: 2.5,
                  height: 3 + amount * (index == 1 ? 8 : 6),
                  decoration: BoxDecoration(
                    color: AudioPlayerColors.accent,
                    borderRadius: BorderRadius.circular(2),
                  ),
                );
              }),
            );
          },
        ),
      ),
    );
  }
}

final class AudioAnimatedPlayPauseButton extends StatefulWidget {
  const AudioAnimatedPlayPauseButton({
    required this.snapshot,
    required this.disableAnimations,
    required this.onPressed,
    super.key,
  });

  final AudioPlayerSnapshot snapshot;
  final bool disableAnimations;
  final VoidCallback onPressed;

  @override
  State<AudioAnimatedPlayPauseButton> createState() =>
      _AudioAnimatedPlayPauseButtonState();
}

class _AudioAnimatedPlayPauseButtonState
    extends State<AudioAnimatedPlayPauseButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      key: const Key('audio-play-pause-surface'),
      dimension: 94,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: <Widget>[
          Listener(
            onPointerDown: (_) => setState(() => _pressed = true),
            onPointerUp: (_) => setState(() => _pressed = false),
            onPointerCancel: (_) => setState(() => _pressed = false),
            child: AnimatedScale(
              duration: widget.disableAnimations
                  ? Duration.zero
                  : const Duration(milliseconds: 120),
              curve: Curves.easeOutCubic,
              scale: _pressed ? 0.94 : 1,
              child: ClipOval(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.21),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.42),
                      ),
                      boxShadow: const <BoxShadow>[
                        BoxShadow(
                          color: Color(0x24000000),
                          blurRadius: 24,
                          offset: Offset(0, 8),
                        ),
                      ],
                    ),
                    child: IconButton(
                      key: const Key('audio-play-pause'),
                      tooltip: widget.snapshot.playing ? '暂停' : '播放',
                      onPressed: widget.onPressed,
                      iconSize: 42,
                      color: AudioPlayerColors.ink,
                      icon: AnimatedSwitcher(
                        duration: widget.disableAnimations
                            ? Duration.zero
                            : const Duration(milliseconds: 160),
                        child: widget.snapshot.buffering
                            ? const SizedBox.square(
                                key: Key('audio-buffering'),
                                dimension: 30,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.4,
                                  color: AudioPlayerColors.ink,
                                ),
                              )
                            : Icon(
                                widget.snapshot.playing
                                    ? Icons.pause_rounded
                                    : Icons.play_arrow_rounded,
                                key: ValueKey<bool>(widget.snapshot.playing),
                              ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

final class AudioAnimatedSeekButton extends StatefulWidget {
  const AudioAnimatedSeekButton({
    required this.tooltip,
    required this.forward,
    required this.disableAnimations,
    required this.onPressed,
    super.key,
  });

  final String tooltip;
  final bool forward;
  final bool disableAnimations;
  final VoidCallback onPressed;

  @override
  State<AudioAnimatedSeekButton> createState() =>
      _AudioAnimatedSeekButtonState();
}

class _AudioAnimatedSeekButtonState extends State<AudioAnimatedSeekButton> {
  Timer? _returnTimer;
  double _turns = 0;
  bool _compressed = false;

  @override
  void dispose() {
    _returnTimer?.cancel();
    super.dispose();
  }

  void _activate() {
    if (!widget.disableAnimations) {
      _returnTimer?.cancel();
      setState(() {
        _turns = widget.forward ? 0.08 : -0.08;
        _compressed = true;
      });
      _returnTimer = Timer(const Duration(milliseconds: 150), () {
        if (!mounted) return;
        setState(() {
          _turns = 0;
          _compressed = false;
        });
      });
    }
    widget.onPressed();
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: widget.tooltip,
      onPressed: _activate,
      constraints: const BoxConstraints.tightFor(
        width: AudioPlayerMetrics.minimumTapTarget,
        height: AudioPlayerMetrics.minimumTapTarget,
      ),
      padding: EdgeInsets.zero,
      color: AudioPlayerColors.ink,
      icon: AnimatedRotation(
        key: Key(
          widget.forward
              ? 'audio-seek-forward-motion'
              : 'audio-seek-back-motion',
        ),
        turns: _turns,
        duration: const Duration(milliseconds: 130),
        curve: Curves.easeOutCubic,
        child: AnimatedScale(
          scale: _compressed ? 0.92 : 1,
          duration: const Duration(milliseconds: 130),
          curve: Curves.easeOutCubic,
          child: _SeekFifteenIcon(forward: widget.forward),
        ),
      ),
    );
  }
}

class _SeekFifteenIcon extends StatelessWidget {
  const _SeekFifteenIcon({required this.forward});

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

final class AudioPlayerProgressThumbShape extends SliderComponentShape {
  const AudioPlayerProgressThumbShape({
    required this.pulse,
    required this.dragging,
  });

  final double pulse;
  final bool dragging;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) =>
      Size.fromRadius(dragging ? 9 : 7);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final canvas = context.canvas;
    final color = sliderTheme.thumbColor ?? AudioPlayerColors.accent;
    final interaction = math.max(
      activationAnimation.value,
      dragging ? 1.0 : 0.0,
    );
    final glowRadius = 10 + pulse * 3 + interaction * 2;
    canvas.drawCircle(
      center,
      glowRadius,
      Paint()..color = color.withValues(alpha: 0.08 + pulse * 0.10),
    );
    canvas.drawCircle(center, 7 + interaction * 1.5, Paint()..color = color);
  }
}
