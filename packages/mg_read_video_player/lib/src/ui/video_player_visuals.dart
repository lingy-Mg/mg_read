/// Shared cinema palette and matte surfaces for the package-owned video UI.
///
/// Responsibilities:
/// - Keep chrome, sheets and session states legible independently of host theme.
/// - Keep red highlights, neutral gray surfaces and white type consistent.
///
/// Notes:
/// - These tokens affect presentation only; playback state remains in the view.
/// - The sheet is shown from a host-level context, so it applies this theme again.
library;

// Cross-file UI helpers are intentionally package-private despite Dart's
// library-level public naming rules.
// ignore_for_file: public_member_api_docs

import 'package:flutter/foundation.dart';

import 'package:flutter/material.dart';

const Color videoPlayerBackground = Color(0xFF080808);
const Color videoPlayerForeground = Color(0xFFF5F5F5);
const Color videoPlayerSecondary = Color(0xFFB3B3B3);
const Color videoPlayerAccent = Color(0xFFE50914);
const Color videoPlayerGlass = Color(0xFA181818);
const Color videoPlayerGlassBorder = Color(0x24FFFFFF);
const Color videoPlayerSelectedSurface = Color(0x26E50914);

/// Applies the fixed video color system without inheriting host brightness.
ThemeData videoPlayerTheme() {
  final base = ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    colorScheme: const ColorScheme.dark(
      primary: videoPlayerAccent,
      onPrimary: Colors.white,
      secondary: Colors.white,
      onSecondary: Colors.black,
      surface: Color(0xFF181818),
      onSurface: videoPlayerForeground,
    ),
  );
  return base.copyWith(
    scaffoldBackgroundColor: videoPlayerBackground,
    textTheme: base.textTheme.apply(
      bodyColor: videoPlayerForeground,
      displayColor: videoPlayerForeground,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Colors.transparent,
      modalBackgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      dragHandleColor: Color(0x8CFFFFFF),
      dragHandleSize: Size(36, 4),
    ),
    dividerTheme: const DividerThemeData(color: Color(0x24FFFFFF)),
    popupMenuTheme: const PopupMenuThemeData(
      color: Color(0xFF262626),
      surfaceTintColor: Colors.transparent,
      textStyle: TextStyle(color: videoPlayerForeground),
    ),
    sliderTheme: base.sliderTheme.copyWith(
      activeTrackColor: videoPlayerAccent,
      inactiveTrackColor: const Color(0x52FFFFFF),
      thumbColor: videoPlayerAccent,
    ),
  );
}

/// A clipped matte panel; the legacy internal name is kept for callers.
final class VideoPlayerGlassPanel extends StatelessWidget {
  const VideoPlayerGlassPanel({
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(20)),
    this.padding,
    this.showBorder = true,
    this.showShadow = true,

    super.key,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final EdgeInsetsGeometry? padding;
  final bool showBorder;
  final bool showShadow;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: borderRadius,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: videoPlayerGlass,
        borderRadius: borderRadius,
        border: showBorder ? Border.all(color: videoPlayerGlassBorder) : null,
        boxShadow: showShadow
            ? const [
                BoxShadow(
                  color: Color(0x52000000),
                  blurRadius: 24,
                  offset: Offset(0, 10),
                ),
              ]
            : null,
      ),
      child: padding == null ? child : Padding(padding: padding!, child: child),
    ),
  );
}

/// A small, deliberately low-obstruction surface for transient gestures.
///
/// Unlike [VideoPlayerGlassPanel], this uses a lighter translucent treatment so
/// seek and rate feedback leaves the video image clearly visible.
final class VideoPlayerTransientFeedbackPanel extends StatelessWidget {
  const VideoPlayerTransientFeedbackPanel({
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(8)),
    this.padding,
    super.key,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: const Color(0x26030609),
      borderRadius: borderRadius,
      border: Border.all(color: const Color(0x1FFFFFFF)),
    ),
    child: padding == null ? child : Padding(padding: padding!, child: child),
  );
}

/// Desktop layout follows the input platform, never a landscape phone's width.
bool videoPlayerUsesPointerControls(BuildContext context) =>
    switch (defaultTargetPlatform) {
      TargetPlatform.windows ||
      TargetPlatform.macOS ||
      TargetPlatform.linux => true,
      _ => false,
    };

/// Shared readable transport time without a leading zero-hour field.
String videoPlayerTime(Duration duration) {
  final total = duration.inSeconds.clamp(0, 359999);
  final hours = total ~/ 3600;
  final minutes = total.remainder(3600) ~/ 60;
  final seconds = total.remainder(60).toString().padLeft(2, '0');
  return hours > 0
      ? '$hours:${minutes.toString().padLeft(2, '0')}:$seconds'
      : '$minutes:$seconds';
}
