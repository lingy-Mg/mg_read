/// Cover, ambient backdrop and artwork motion for the audio player.
///
/// Responsibilities:
/// - Render one thin-framed foreground cover without performing artwork I/O.
/// - Reuse the host artwork renderer as a blurred, tinted background layer.
/// - Cross-fade chapter artwork and ease playback-state depth changes.
///
/// Notes:
/// - The host artwork builder may be invoked for both foreground and backdrop.
/// - Reduced-motion preferences collapse every decorative transition to zero.
library;

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
          stops: <double>[0, 0.78],
        ),
      ),
    );
  }
}

final class AudioPlayerArtworkBackdrop extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final depthDuration = disableAnimations
        ? Duration.zero
        : const Duration(milliseconds: 760);
    final switchDuration = disableAnimations
        ? Duration.zero
        : const Duration(milliseconds: 620);
    final artwork = artworkBuilder?.call(context, track);
    return IgnorePointer(
      child: Stack(
        key: const Key('audio-artwork-backdrop'),
        fit: StackFit.expand,
        children: <Widget>[
          const AudioPlayerAmbientBackground(),
          ClipRect(
            child: AnimatedOpacity(
              duration: depthDuration,
              curve: Curves.easeOutCubic,
              opacity: playing ? 0.30 : 0.23,
              child: AnimatedScale(
                duration: depthDuration,
                curve: Curves.easeOutQuart,
                scale: playing ? 1.48 : 1.42,
                child: ImageFiltered(
                  imageFilter: ImageFilter.blur(
                    sigmaX: 36,
                    sigmaY: 36,
                    tileMode: TileMode.decal,
                  ),
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
                    child: SizedBox.expand(
                      key: ValueKey<String>(track.id),
                      child: artwork ?? const AudioPlayerCoverPlaceholder(),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: <Color>[
                  Color(0xB8FFFAF3),
                  Color(0xC9FFF8EE),
                  Color(0xEAF7EDDF),
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
                  Colors.white.withValues(alpha: 0.08),
                  AudioPlayerColors.accent.withValues(alpha: 0.035),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ],
      ),
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
      scale: playing ? 1 : 0.985,
      duration: disableAnimations
          ? Duration.zero
          : const Duration(milliseconds: 420),
      curve: Curves.easeOutCubic,
      child: Container(
        width: size,
        height: size,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(32),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.76),
            width: 0.8,
          ),
          boxShadow: const <BoxShadow>[
            BoxShadow(
              color: AudioPlayerColors.shadow,
              blurRadius: 30,
              offset: Offset(0, 15),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(29.5),
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
