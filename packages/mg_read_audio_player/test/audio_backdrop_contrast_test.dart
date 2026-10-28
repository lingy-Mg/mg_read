/// Validate rendered color compositions used by the artwork-led glass UI.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read_audio_player/src/ui/audio_player_theme.dart';

void main() {
  test(
    'foreground text survives bright artwork and the strongest glass tint',
    () {
      for (final artwork in [
        Colors.white,
        Colors.red,
        Colors.yellow,
        Colors.cyan,
        Colors.black,
      ]) {
        final backdrop = Color.alphaBlend(
          AudioPlayerColors.artworkBackdropTint,
          artwork,
        );
        for (final glass in [
          Colors.transparent,
          AudioPlayerColors.glassStrongHighlight,
          AudioPlayerColors.control,
        ]) {
          final background = Color.alphaBlend(glass, backdrop);
          for (final ink in [AudioPlayerColors.ink, AudioPlayerColors.muted]) {
            final foreground = Color.alphaBlend(ink, background);
            final a = foreground.computeLuminance(),
                b = background.computeLuminance();
            final ratio = a > b ? (a + .05) / (b + .05) : (b + .05) / (a + .05);
            expect(ratio, greaterThanOrEqualTo(4.5));
          }
        }
      }
    },
  );
}
