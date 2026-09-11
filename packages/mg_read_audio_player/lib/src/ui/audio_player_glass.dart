/// Shared frosted-glass surfaces for the audio player presentation layer.
///
/// Responsibilities:
/// - Apply one bounded blur, blue tint, highlight border and depth treatment.
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
        Color(0x665E89A7),
        AudioPlayerColors.glassHighlight,
        AudioPlayerColors.glass,
      ],
      AudioGlassTone.strong => const <Color>[
        Color(0x7551738E),
        AudioPlayerColors.glassStrongHighlight,
        AudioPlayerColors.glassStrong,
      ],
      AudioGlassTone.accent => const <Color>[
        Color(0x7059A5CD),
        AudioPlayerColors.accentGlassHighlight,
        AudioPlayerColors.accentGlass,
      ],
      AudioGlassTone.warning => const <Color>[
        Color(0x665F3B46),
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
                  blurRadius: 30,
                  offset: Offset(0, 16),
                ),
                BoxShadow(
                  color: AudioPlayerColors.blueGlow,
                  blurRadius: 26,
                  spreadRadius: -12,
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
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: colors,
                      stops: const <double>[0, 0.34, 1],
                    ),
                    borderRadius: borderRadius,
                    border: Border.all(color: borderColor, width: 0.8),
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
                          Colors.white.withValues(alpha: 0.50),
                          AudioPlayerColors.accent.withValues(alpha: 0.34),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _AudioGlassFrostPainter(borderRadius),
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

final class _AudioGlassFrostPainter extends CustomPainter {
  const _AudioGlassFrostPainter(this.borderRadius);

  final BorderRadius borderRadius;

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    final shape = borderRadius.toRRect(bounds).deflate(1);
    canvas.save();
    canvas.clipRRect(shape);
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment(-1.2, -1),
          end: Alignment(0.35, 0.7),
          colors: <Color>[
            Color(0x00FFFFFF),
            Color(0x24DDF4FF),
            Color(0x08FFFFFF),
            Color(0x00FFFFFF),
          ],
          stops: <double>[0.1, 0.38, 0.55, 0.78],
        ).createShader(bounds),
    );
    final grain = Paint()..strokeWidth = 0.8;
    for (var index = 0; index < 72; index += 1) {
      final x = ((index * 47 + 19) % 101) / 101 * size.width;
      final y = ((index * 83 + 11) % 103) / 103 * size.height;
      final alpha = 8 + (index % 4) * 3;
      grain.color = Color.fromARGB(alpha, 225, 245, 255);
      canvas.drawCircle(Offset(x, y), index.isEven ? 0.55 : 0.35, grain);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_AudioGlassFrostPainter oldDelegate) =>
      oldDelegate.borderRadius != borderRadius;
}
