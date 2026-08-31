/// Shared visual tokens and glass surfaces for the package-owned video UI.
///
/// Responsibilities:
/// - Keep chrome, sheets and session states legible independently of host theme.
/// - Provide the translucent visual treatment used above the video surface.
///
/// Notes:
/// - These tokens affect presentation only; playback state remains in the view.
/// - The sheet is shown from a host-level context, so it applies this theme again.
library;

// Cross-file UI helpers are intentionally package-private despite Dart's
// library-level public naming rules.
// ignore_for_file: public_member_api_docs

import 'dart:ui';

import 'package:flutter/material.dart';

const Color videoPlayerBackground = Color(0xFF050607);
const Color videoPlayerForeground = Color(0xFFF7F7F8);
const Color videoPlayerSecondary = Color(0xFFBEC1C7);
const Color videoPlayerAccent = Color(0xFFFFA43A);
const Color videoPlayerGlass = Color(0xBE17191C);
const Color videoPlayerGlassBorder = Color(0x33FFFFFF);
const Color videoPlayerSelectedSurface = Color(0x38FFA43A);

/// Applies the fixed video color system without inheriting host brightness.
ThemeData videoPlayerTheme() {
  final base = ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    colorSchemeSeed: videoPlayerAccent,
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
      color: Color(0xF226292E),
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

/// A clipped, blurred translucent panel for controls placed over video.
final class VideoPlayerGlassPanel extends StatelessWidget {
  const VideoPlayerGlassPanel({
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(20)),
    this.padding,
    super.key,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: borderRadius,
    child: BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: videoPlayerGlass,
          borderRadius: borderRadius,
          border: Border.all(color: videoPlayerGlassBorder),
          boxShadow: const <BoxShadow>[
            BoxShadow(
              color: Color(0x52000000),
              blurRadius: 24,
              offset: Offset(0, 10),
            ),
          ],
        ),
        child: padding == null
            ? child
            : Padding(padding: padding!, child: child),
      ),
    ),
  );
}
