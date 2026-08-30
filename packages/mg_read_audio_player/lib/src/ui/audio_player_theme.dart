/// Internal visual language for the light, spoken-audio player surface.
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
  static const backgroundTop = Color(0xFFFFFAF3);
  static const backgroundBottom = Color(0xFFF7EDDF);
  static const surface = Color(0xFFFFFDF9);
  static const surfaceStrong = Color(0xFFFFFFFF);
  static const ink = Color(0xFF261D16);
  static const muted = Color(0xFF81746A);
  static const subtle = Color(0xFFA99B8F);
  static const accent = Color(0xFFCC7625);
  static const accentPressed = Color(0xFFAE5E18);
  static const accentSoft = Color(0xFFFFE8CD);
  static const warning = Color(0xFFB65332);
  static const warningSoft = Color(0xFFFFE8DF);
  static const track = Color(0xFFE9DACA);
  static const divider = Color(0xFFF0E5D9);
  static const control = Color(0xFFF7EEE4);
  static const disabled = Color(0xFFC8BBB0);
  static const coverStart = Color(0xFFE79A49);
  static const coverEnd = Color(0xFF754531);
  static const shadow = Color(0x2E3B2614);
  static const scrim = Color(0x520F0A06);
}

abstract final class AudioPlayerMetrics {
  static const pageMaxWidth = 520.0;
  static const sheetRadius = 30.0;
  static const cardRadius = 28.0;
  static const controlRadius = 20.0;
  static const minimumTapTarget = 44.0;
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
