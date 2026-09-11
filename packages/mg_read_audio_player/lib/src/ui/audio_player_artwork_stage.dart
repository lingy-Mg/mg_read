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
import 'audio_player_theme.dart';

final class AudioPlayerAmbientBackground extends StatelessWidget {
  const AudioPlayerAmbientBackground({super.key});

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            AudioPlayerColors.backgroundTop,
            AudioPlayerColors.backgroundBottom,
          ],
        ),
      ),
    );
  }
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
        ? const Color(0x48000000)
        : const Color(0x5E000000);
    return IgnorePointer(
      child: Stack(
        key: const Key('audio-artwork-backdrop'),
        fit: StackFit.expand,
        children: <Widget>[
          const AudioPlayerAmbientBackground(),
          ClipRect(
            child: ImageFiltered(
              key: const Key('audio-artwork-backdrop-blur'),
              imageFilter: ImageFilter.blur(
                sigmaX: 32,
                sigmaY: 32,
                tileMode: TileMode.clamp,
              ),
              child: AnimatedBuilder(
                animation: _motionController,
                builder: (context, child) {
                  final phase = _motionController.value;
                  final breathe = math.sin(phase * math.pi);
                  return Transform.translate(
                    key: const Key('audio-artwork-backdrop-motion'),
                    offset: Offset(-8 + phase * 16, 6 - phase * 12),
                    child: Transform.scale(
                      scale: 1.18 + breathe * 0.025,
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
                        scale: Tween<double>(
                          begin: 0.96,
                          end: 1,
                        ).animate(curved),
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
          ),
          AnimatedContainer(
            key: const Key('audio-artwork-backdrop-tint'),
            duration: depthDuration,
            curve: Curves.easeOutCubic,
            color: glassTint,
          ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: <Color>[Color(0x0D000000), Color(0x42000000)],
              ),
            ),
          ),
        ],
      ),
    );
  }
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
          child: DecoratedBox(
            key: const Key('audio-cover-glass'),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(30),
              border: Border.all(color: Colors.white.withValues(alpha: 0.42)),
              boxShadow: const <BoxShadow>[
                BoxShadow(
                  color: Color(0x24000000),
                  blurRadius: 32,
                  offset: Offset(0, 18),
                ),
              ],
            ),
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
