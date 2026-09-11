/// Cover, ambient backdrop and artwork motion for the audio player.
///
/// Responsibilities:
/// - Render one thin-framed foreground cover without performing artwork I/O.
/// - Fill and crop host artwork beneath a sampled, tinted glass layer.
/// - Cross-fade chapter artwork and ease playback-state depth changes.
///
/// Notes:
/// - The host artwork builder may be invoked for both foreground and backdrop.
/// - Reduced-motion preferences collapse every decorative transition to zero.
library;

import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../api/audio_artwork.dart';
import '../api/audio_models.dart';
import 'audio_player_glass.dart';
import 'audio_player_theme.dart';

final class AudioPlayerAmbientBackground extends StatelessWidget {
  const AudioPlayerAmbientBackground({super.key});

  @override
  Widget build(BuildContext context) {
    return const Stack(
      fit: StackFit.expand,
      children: <Widget>[
        DecoratedBox(
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
          top: -130,
          right: -115,
          child: _AmbientGlow(
            size: 360,
            colors: <Color>[Color(0x8A39A8EA), Color(0x0039A8EA)],
          ),
        ),
        Positioned(
          left: -170,
          bottom: 40,
          child: _AmbientGlow(
            size: 390,
            colors: <Color>[Color(0x66347DB6), Color(0x00347DB6)],
          ),
        ),
      ],
    );
  }
}

final class _AmbientGlow extends StatelessWidget {
  const _AmbientGlow({required this.size, required this.colors});

  final double size;
  final List<Color> colors;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(colors: colors),
      ),
    ),
  );
}

final class AudioPlayerArtworkBackdrop extends StatefulWidget {
  const AudioPlayerArtworkBackdrop({
    required this.track,
    required this.artworkBuilder,
    required this.playing,
    required this.disableAnimations,
    super.key,
  });

  final AudioTrack track;
  final AudioArtworkBuilder? artworkBuilder;
  final bool playing;
  final bool disableAnimations;

  @override
  State<AudioPlayerArtworkBackdrop> createState() =>
      _AudioPlayerArtworkBackdropState();
}

class _AudioPlayerArtworkBackdropState extends State<AudioPlayerArtworkBackdrop>
    with SingleTickerProviderStateMixin {
  late final AnimationController _motionController = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 16),
  );

  bool get _motionActive => widget.playing && !widget.disableAnimations;

  @override
  void initState() {
    super.initState();
    _syncMotion();
  }

  @override
  void didUpdateWidget(AudioPlayerArtworkBackdrop oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playing != widget.playing ||
        oldWidget.disableAnimations != widget.disableAnimations) {
      _syncMotion();
    }
  }

  void _syncMotion() {
    if (_motionActive) {
      _motionController.repeat(reverse: true);
    } else {
      _motionController.stop();
      _motionController.value = 0.5;
    }
  }

  @override
  void dispose() {
    _motionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final depthDuration = widget.disableAnimations
        ? Duration.zero
        : const Duration(milliseconds: 760);
    final switchDuration = widget.disableAnimations
        ? Duration.zero
        : const Duration(milliseconds: 620);
    final artwork = widget.artworkBuilder?.call(context, widget.track);
    final glassTint = widget.playing
        ? const Color(0x83051120)
        : const Color(0xA1081526);
    return IgnorePointer(
      child: Stack(
        key: const Key('audio-artwork-backdrop'),
        fit: StackFit.expand,
        children: <Widget>[
          const AudioPlayerAmbientBackground(),
          ClipRect(
            child: AnimatedBuilder(
              animation: _motionController,
              builder: (context, child) {
                final phase = _motionController.value;
                final breathe = math.sin(phase * math.pi);
                return Transform.translate(
                  key: const Key('audio-artwork-backdrop-motion'),
                  offset: Offset(-8 + phase * 16, 6 - phase * 12),
                  child: Transform.scale(
                    scale: 1.08 + breathe * 0.025,
                    child: child,
                  ),
                );
              },
              child: AnimatedSwitcher(
                duration: switchDuration,
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, animation) {
                  final curved = CurvedAnimation(
                    parent: animation,
                    curve: Curves.easeOutCubic,
                  );
                  return FadeTransition(
                    opacity: curved,
                    child: ScaleTransition(
                      scale: Tween<double>(begin: 0.96, end: 1).animate(curved),
                      child: child,
                    ),
                  );
                },
                child: RepaintBoundary(
                  key: ValueKey<String>(widget.track.id),
                  child: SizedBox.expand(
                    key: const Key('audio-artwork-backdrop-cover'),
                    child: artwork ?? const AudioPlayerCoverPlaceholder(),
                  ),
                ),
              ),
            ),
          ),
          ClipRect(
            child: BackdropFilter(
              key: const Key('audio-artwork-backdrop-glass'),
              filter: ImageFilter.blur(
                sigmaX: 50,
                sigmaY: 50,
                tileMode: TileMode.clamp,
              ),
              child: AnimatedContainer(
                key: const Key('audio-artwork-backdrop-tint'),
                duration: depthDuration,
                curve: Curves.easeOutCubic,
                color: glassTint,
              ),
            ),
          ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: <Color>[
                  Color(0x5C2C6F9A),
                  Color(0x8F102D49),
                  Color(0xD6020914),
                ],
                stops: <double>[0, 0.48, 1],
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(0, -0.32),
                radius: 0.78,
                colors: <Color>[
                  AudioPlayerColors.accent.withValues(alpha: 0.16),
                  Color(0xFF2B83BD).withValues(alpha: 0.08),
                  Colors.transparent,
                ],
              ),
            ),
          ),
          const Positioned(
            top: 72,
            left: -150,
            child: _BackdropGlow(
              width: 320,
              height: 430,
              colors: <Color>[Color(0x7037B5F2), Color(0x0037B5F2)],
            ),
          ),
          const Positioned(
            top: 315,
            right: -190,
            child: _BackdropGlow(
              width: 390,
              height: 470,
              colors: <Color>[Color(0x66306EA8), Color(0x00306EA8)],
            ),
          ),
          const Positioned(
            left: 35,
            bottom: -180,
            child: _BackdropGlow(
              width: 330,
              height: 330,
              colors: <Color>[Color(0x55398DCC), Color(0x00398DCC)],
            ),
          ),
        ],
      ),
    );
  }
}

final class _BackdropGlow extends StatelessWidget {
  const _BackdropGlow({
    required this.width,
    required this.height,
    required this.colors,
  });

  final double width;
  final double height;
  final List<Color> colors;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    height: height,
    child: DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(colors: colors),
      ),
    ),
  );
}

final class AudioPlayerCover extends StatefulWidget {
  const AudioPlayerCover({
    required this.track,
    required this.artworkBuilder,
    required this.size,
    required this.currentIndex,
    required this.playing,
    required this.buffering,
    required this.disableAnimations,
    super.key,
  });

  final AudioTrack track;
  final AudioArtworkBuilder? artworkBuilder;
  final double size;
  final int currentIndex;
  final bool playing;
  final bool buffering;
  final bool disableAnimations;

  @override
  State<AudioPlayerCover> createState() => _AudioPlayerCoverState();
}

class _AudioPlayerCoverState extends State<AudioPlayerCover>
    with SingleTickerProviderStateMixin {
  late final AnimationController _atmosphereController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 6800),
  );
  int _switchDirection = 1;

  bool get _atmosphereActive =>
      widget.playing && !widget.buffering && !widget.disableAnimations;

  @override
  void initState() {
    super.initState();
    _syncAtmosphere();
  }

  @override
  void didUpdateWidget(AudioPlayerCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentIndex != widget.currentIndex) {
      _switchDirection = widget.currentIndex > oldWidget.currentIndex ? 1 : -1;
    }
    if (oldWidget.playing != widget.playing ||
        oldWidget.buffering != widget.buffering ||
        oldWidget.disableAnimations != widget.disableAnimations) {
      _syncAtmosphere();
    }
  }

  void _syncAtmosphere() {
    if (_atmosphereActive) {
      _atmosphereController.repeat();
    } else {
      _atmosphereController.stop();
      _atmosphereController.value = 0;
    }
  }

  @override
  void dispose() {
    _atmosphereController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final switchDuration = widget.disableAnimations
        ? Duration.zero
        : const Duration(milliseconds: 620);
    return AnimatedBuilder(
      animation: _atmosphereController,
      builder: (context, child) {
        final breath = _atmosphereActive
            ? (1 - math.cos(_atmosphereController.value * math.pi * 2)) / 2
            : 0.0;
        return Transform.translate(
          key: const Key('audio-cover-motion'),
          offset: Offset(0, -2 * breath),
          child: Transform.scale(scale: 1 + 0.012 * breath, child: child),
        );
      },
      child: AnimatedScale(
        key: const Key('audio-cover'),
        scale: widget.playing && !widget.buffering ? 1 : 0.985,
        duration: widget.disableAnimations
            ? Duration.zero
            : const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
        child: SizedBox(
          width: widget.size,
          height: widget.size,
          child: AudioGlassPanel(
            key: const Key('audio-cover-glass'),
            padding: const EdgeInsets.all(3),
            borderRadius: BorderRadius.circular(32),
            tone: AudioGlassTone.strong,
            blur: 14,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(29),
              child: AnimatedSwitcher(
                key: Key(
                  _switchDirection > 0
                      ? 'audio-cover-switch-forward'
                      : 'audio-cover-switch-backward',
                ),
                duration: switchDuration,
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, animation) {
                  final incoming =
                      child.key == ValueKey<String>(widget.track.id);
                  final direction = incoming
                      ? _switchDirection.toDouble()
                      : -_switchDirection.toDouble();
                  final curved = CurvedAnimation(
                    parent: animation,
                    curve: Curves.easeOutCubic,
                  );
                  return FadeTransition(
                    opacity: curved,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: Offset(direction * 0.12, 0),
                        end: Offset.zero,
                      ).animate(curved),
                      child: ScaleTransition(
                        scale: Tween<double>(
                          begin: 0.97,
                          end: 1,
                        ).animate(curved),
                        child: child,
                      ),
                    ),
                  );
                },
                child: Stack(
                  key: ValueKey<String>(widget.track.id),
                  fit: StackFit.expand,
                  children: <Widget>[
                    widget.artworkBuilder?.call(context, widget.track) ??
                        const AudioPlayerCoverPlaceholder(),
                    IgnorePointer(
                      child: AnimatedBuilder(
                        animation: _atmosphereController,
                        builder: (context, child) => CustomPaint(
                          key: const Key('audio-cover-atmosphere'),
                          painter: _AudioCoverAtmospherePainter(
                            phase: _atmosphereController.value,
                            active: _atmosphereActive,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _AudioCoverAtmospherePainter extends CustomPainter {
  const _AudioCoverAtmospherePainter({
    required this.phase,
    required this.active,
  });

  final double phase;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    if (!active) return;
    _paintSheen(canvas, size);
    _paintParticles(canvas, size);
  }

  void _paintSheen(Canvas canvas, Size size) {
    const sheenStart = 0.72;
    const sheenEnd = 0.90;
    if (phase < sheenStart || phase > sheenEnd) return;
    final amount = (phase - sheenStart) / (sheenEnd - sheenStart);
    final opacity = math.sin(amount * math.pi) * 0.18;
    final centerX = (-0.25 + amount * 1.5) * size.width;
    final path = Path()
      ..moveTo(centerX - size.width * 0.18, 0)
      ..lineTo(centerX + size.width * 0.02, 0)
      ..lineTo(centerX + size.width * 0.30, size.height)
      ..lineTo(centerX + size.width * 0.10, size.height)
      ..close();
    canvas.drawPath(
      path,
      Paint()
        ..shader = LinearGradient(
          colors: <Color>[
            Colors.transparent,
            AudioPlayerColors.accentPressed.withValues(alpha: opacity),
            Colors.transparent,
          ],
        ).createShader(Offset.zero & size),
    );
  }

  void _paintParticles(Canvas canvas, Size size) {
    const origins = <Offset>[
      Offset(0.18, 0.77),
      Offset(0.78, 0.68),
      Offset(0.64, 0.28),
    ];
    const offsets = <double>[0.18, 0.61, 0.84];
    for (var index = 0; index < origins.length; index += 1) {
      final amount = (phase + offsets[index]) % 1;
      final opacity = math.sin(amount * math.pi) * 0.42;
      final origin = origins[index];
      final center = Offset(
        (origin.dx + amount * 0.035) * size.width,
        (origin.dy - amount * 0.11) * size.height,
      );
      canvas.drawCircle(
        center,
        1.6 + amount * 0.8,
        Paint()
          ..color = AudioPlayerColors.accentSoft.withValues(alpha: opacity)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.2),
      );
    }
  }

  @override
  bool shouldRepaint(_AudioCoverAtmospherePainter oldDelegate) =>
      oldDelegate.phase != phase || oldDelegate.active != active;
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
          LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.biggest.shortestSide < 150;
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(
                      Icons.headphones_rounded,
                      size: compact ? 40 : 64,
                      color: AudioPlayerColors.ink,
                    ),
                    SizedBox(height: compact ? 7 : 14),
                    Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: compact ? 8 : 16,
                      ),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          'MGREAD AUDIO',
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(
                                color: Colors.white.withValues(alpha: 0.86),
                                fontWeight: FontWeight.w800,
                                letterSpacing: compact ? 1.2 : 2.2,
                              ),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
