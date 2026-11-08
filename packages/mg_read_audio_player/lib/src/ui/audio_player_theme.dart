/// Internal visual language for the minimal, cover-led audio player surface.
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
  static const backgroundTop = Color(0xFF292D32);
  static const backgroundBottom = Color(0xFF111315);
  static const surface = Color(0xFF25282D);
  static const surfaceStrong = Color(0xFF1B1E22);
  static const ink = Color(0xFFF6F7F9);
  static const muted = Color(0xFFB8BDC5);
  static const subtle = Color(0xFF8C939D);
  static const accent = Color(0xFFF6F7F9);
  static const accentPressed = Colors.white;
  static const accentSoft = Color(0x1AFFFFFF);
  static const warning = Color(0xFFFFC5B8);
  static const warningSoft = Color(0xFF372726);
  static const track = Color(0x40FFFFFF);
  static const divider = Color(0xFF34383F);
  static const control = Color(0xFF30343B);
  static const disabled = Color(0xFF676D75);
  static const coverStart = Color(0xFF4C5868);
  static const coverEnd = Color(0xFF222830);
  static const scrim = Color(0x99000000);
  // Upper bound on ambient luminance, including white and saturated covers.
  static const artworkBackdropTint = Color(0xD6000000);
  static const accentBorder = Color(0x406D7785);
}

abstract final class AudioPlayerMetrics {
  static const pageMaxWidth = 480.0;
  static const sheetRadius = 24.0;
  static const cardRadius = 16.0;
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
        outline: AudioPlayerColors.divider,
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
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: AudioPlayerColors.ink,
        disabledForegroundColor: AudioPlayerColors.disabled,
        minimumSize: const Size.square(AudioPlayerMetrics.minimumTapTarget),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: AudioPlayerColors.ink),
    ),
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
