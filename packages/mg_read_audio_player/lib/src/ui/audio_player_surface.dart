/// Quiet, opaque surfaces for audio sheets and recovery messages.
///
/// The child owns interaction and semantics. Surfaces perform no I/O, keep
/// text contrast independent of artwork, and require no backdrop compositing.
library;

import 'package:flutter/material.dart';

import 'audio_player_theme.dart';

enum AudioSurfaceTone { soft, strong, accent, warning }

final class AudioSurfacePanel extends StatelessWidget {
  const AudioSurfacePanel({
    required this.child,
    this.padding,
    this.borderRadius = const BorderRadius.all(
      Radius.circular(AudioPlayerMetrics.cardRadius),
    ),
    this.tone = AudioSurfaceTone.soft,
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final BorderRadius borderRadius;
  final AudioSurfaceTone tone;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: borderRadius,
    child: ColoredBox(
      color: switch (tone) {
        AudioSurfaceTone.soft => AudioPlayerColors.surface,
        AudioSurfaceTone.strong => AudioPlayerColors.surfaceStrong,
        AudioSurfaceTone.accent => AudioPlayerColors.control,
        AudioSurfaceTone.warning => AudioPlayerColors.warningSoft,
      },
      child: Padding(padding: padding ?? EdgeInsets.zero, child: child),
    ),
  );
}
