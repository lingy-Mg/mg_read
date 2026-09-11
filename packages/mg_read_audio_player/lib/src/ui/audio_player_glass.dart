/// Shared frosted-glass surfaces for the audio player presentation layer.
///
/// Responsibilities:
/// - Apply one bounded blur, neutral translucent tint and quiet depth treatment.
/// - Keep page cards, interactive launchers and modal sheets visually aligned.
///
/// Notes:
/// - The child owns interaction and semantics; this widget is presentation-only.
/// - Blur is clipped to the requested radius to avoid repainting outside panels.
library;

import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import 'audio_player_theme.dart';

enum AudioGlassTone { soft, strong, accent, warning }

final class AudioGlassPanel extends StatelessWidget {
  const AudioGlassPanel({
    required this.child,
    this.padding,
    this.borderRadius = const BorderRadius.all(
      Radius.circular(AudioPlayerMetrics.cardRadius),
    ),
    this.tone = AudioGlassTone.soft,
    this.blur = 20,
    this.shadow = true,
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final BorderRadius borderRadius;
  final AudioGlassTone tone;
  final double blur;
  final bool shadow;

  @override
  Widget build(BuildContext context) {
    final colors = switch (tone) {
      AudioGlassTone.soft => const <Color>[
        AudioPlayerColors.glassHighlight,
        AudioPlayerColors.glass,
      ],
      AudioGlassTone.strong => const <Color>[
        AudioPlayerColors.glassStrongHighlight,
        AudioPlayerColors.glassStrong,
      ],
      AudioGlassTone.accent => const <Color>[
        AudioPlayerColors.accentGlassHighlight,
        AudioPlayerColors.accentGlass,
      ],
      AudioGlassTone.warning => const <Color>[
        AudioPlayerColors.warningGlassHighlight,
        AudioPlayerColors.warningGlass,
      ],
    };
    final borderColor = switch (tone) {
      AudioGlassTone.accent => AudioPlayerColors.accentBorder,
      AudioGlassTone.warning => AudioPlayerColors.warningBorder,
      _ => AudioPlayerColors.glassBorder,
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: shadow
            ? const <BoxShadow>[
                BoxShadow(
                  color: AudioPlayerColors.shadow,
                  blurRadius: 36,
                  offset: Offset(0, 18),
                ),
              ]
            : null,
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: blur,
            sigmaY: blur,
            tileMode: TileMode.clamp,
          ),
          child: Stack(
            fit: StackFit.passthrough,
            children: <Widget>[
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: colors,
                    ),
                    borderRadius: borderRadius,
                    border: Border.all(color: borderColor, width: 1),
                  ),
                ),
              ),
              Positioned(
                top: 1,
                left: 18,
                right: 18,
                child: IgnorePointer(
                  child: Container(
                    height: 1,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: <Color>[
                          Colors.transparent,
                          Colors.white.withValues(alpha: 0.42),
                          Colors.white.withValues(alpha: 0.12),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Padding(padding: padding ?? EdgeInsets.zero, child: child),
            ],
          ),
        ),
      ),
    );
  }
}
