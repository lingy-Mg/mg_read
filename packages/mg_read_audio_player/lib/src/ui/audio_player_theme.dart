/// Internal visual language for the cover-led frosted audio player surface.
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
  static const backgroundTop = Color(0xFF322F2D);
  static const backgroundBottom = Color(0xFF181614);
  static const surface = Color(0x26FFFFFF);
  static const surfaceStrong = Color(0x33FFFFFF);
  static const ink = Color(0xEBFFFFFF);
  static const muted = Color(0xA8FFFFFF);
  static const subtle = Color(0x73FFFFFF);
  static const accent = Color(0xE6FFFFFF);
  static const accentPressed = Color(0xFFFFFFFF);
  static const accentSoft = Color(0x33FFFFFF);
  static const warning = Color(0xFFFFC5B8);
  static const warningSoft = Color(0x24FFB5A5);
  static const track = Color(0x40FFFFFF);
  static const divider = Color(0x33FFFFFF);
  static const control = Color(0x2EFFFFFF);
  static const disabled = Color(0x45FFFFFF);
  static const coverStart = Color(0xFF61534A);
  static const coverEnd = Color(0xFF171413);
  static const shadow = Color(0x24000000);
  static const blueGlow = Color(0x00000000);
  static const scrim = Color(0x8A000000);

  static const glass = Color(0x14FFFFFF);
  static const glassHighlight = Color(0x29FFFFFF);
  static const glassStrong = Color(0x1DFFFFFF);
  static const glassStrongHighlight = Color(0x33FFFFFF);
  static const glassBorder = Color(0x48FFFFFF);
  static const accentGlass = Color(0x24FFFFFF);
  static const accentGlassHighlight = Color(0x38FFFFFF);
  static const accentBorder = Color(0x52FFFFFF);
  static const warningGlass = Color(0x24FFB5A5);
  static const warningGlassHighlight = Color(0x33FFCEC4);
  static const warningBorder = Color(0x55FFCEC4);
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
