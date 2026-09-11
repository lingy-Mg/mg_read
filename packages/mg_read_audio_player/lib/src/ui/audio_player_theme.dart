/// Internal visual language for the dark-blue spoken-audio player surface.
///
/// Responsibilities:
/// - Centralize the player's color, radius and spacing decisions.
/// - Keep formatting helpers independent from the host application theme.
///
/// Notes:
/// - This file is package-private and performs no host or media I/O.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

abstract final class AudioPlayerColors {
  static const backgroundTop = Color(0xFF0C2037);
  static const backgroundBottom = Color(0xFF020711);
  static const surface = Color(0x74162B43);
  static const surfaceStrong = Color(0xA91A334F);
  static const ink = Color(0xFFF4F9FF);
  static const muted = Color(0xFFB5C9DC);
  static const subtle = Color(0xFF7892AA);
  static const accent = Color(0xFF79C8FF);
  static const accentPressed = Color(0xFFA9DDFF);
  static const accentSoft = Color(0x522A86C4);
  static const warning = Color(0xFFFFA88F);
  static const warningSoft = Color(0x522E1720);
  static const track = Color(0xFF38536D);
  static const divider = Color(0x3DADDFFF);
  static const control = Color(0x70203852);
  static const disabled = Color(0xFF587086);
  static const coverStart = Color(0xFF307EB4);
  static const coverEnd = Color(0xFF071A31);
  static const shadow = Color(0x99000612);
  static const blueGlow = Color(0x4D2C9DDF);
  static const scrim = Color(0x66020710);

  static const glass = Color(0x5011263D);
  static const glassHighlight = Color(0x703D6482);
  static const glassStrong = Color(0x78101E31);
  static const glassStrongHighlight = Color(0x903B607C);
  static const glassBorder = Color(0x8A9CD8F7);
  static const accentGlass = Color(0x62184869);
  static const accentGlassHighlight = Color(0x803D91BD);
  static const accentBorder = Color(0xB87BCBFF);
  static const warningGlass = Color(0x86261720);
  static const warningGlassHighlight = Color(0xA6472932);
  static const warningBorder = Color(0x99FF9C82);
}

abstract final class AudioPlayerMetrics {
  static const pageMaxWidth = 520.0;
  static const sheetRadius = 30.0;
  static const cardRadius = 28.0;
  static const controlRadius = 20.0;
  static const minimumTapTarget = 44.0;
}

ThemeData audioPlayerTheme(ThemeData base) {
  final scheme =
      ColorScheme.fromSeed(
        seedColor: AudioPlayerColors.accent,
        brightness: Brightness.dark,
        surface: AudioPlayerColors.surfaceStrong,
      ).copyWith(
        primary: AudioPlayerColors.accent,
        onPrimary: AudioPlayerColors.backgroundBottom,
        secondary: AudioPlayerColors.accentPressed,
        onSecondary: AudioPlayerColors.backgroundBottom,
        surface: AudioPlayerColors.surfaceStrong,
        onSurface: AudioPlayerColors.ink,
        error: AudioPlayerColors.warning,
        onError: AudioPlayerColors.backgroundBottom,
        outline: AudioPlayerColors.glassBorder,
      );
  return base.copyWith(
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: AudioPlayerColors.backgroundBottom,
    canvasColor: Colors.transparent,
    dividerColor: AudioPlayerColors.divider,
    textTheme: base.textTheme.apply(
      bodyColor: AudioPlayerColors.ink,
      displayColor: AudioPlayerColors.ink,
    ),
    iconTheme: const IconThemeData(color: AudioPlayerColors.ink),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Colors.transparent,
      modalBackgroundColor: Colors.transparent,
      modalBarrierColor: AudioPlayerColors.scrim,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? AudioPlayerColors.backgroundBottom
            : AudioPlayerColors.muted,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? AudioPlayerColors.accent
            : AudioPlayerColors.track,
      ),
    ),
  );
}

String formatAudioDuration(Duration value) {
  final totalSeconds = math.max(0, value.inSeconds);
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

String formatAudioRate(double rate) {
  final rounded = rate.toStringAsFixed(2);
  if (rounded.endsWith('.00')) {
    return rounded.substring(0, rounded.length - 3);
  }
  if (rounded.endsWith('0')) {
    return rounded.substring(0, rounded.length - 1);
  }
  return rounded;
}

String formatAudioVolume(double volume) =>
    '${(volume.clamp(0, 1) * 100).round()}%';
