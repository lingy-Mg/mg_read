import 'package:flutter/material.dart';

import '../reader_theme.dart';

abstract final class ReaderSettingsTokens {
  static const double sheetHeightFactor = .82;
  static const double maxSheetWidth = 720;
  static const double maxDesktopSheetHeight = 560;
  static const double maxContentWidth = 572;
  static const double compactBreakpoint = 520;
  static const double contentHorizontalPadding = 14;
  static const double contentVerticalPadding = 10;
  static const double labelWidth = 52;
  static const double rowMinHeight = 48;
  static const double controlHeight = 48;
  static const double touchTarget = 48;
  static const double swatchSize = 36;
  static const double backgroundPreviewWidth = 76;
  static const double backgroundPreviewHeight = 40;
  static const double navHeight = 68;
  static const double smallRadius = 9;
  static const double controlRadius = 18;
  static const double sheetRadius = 20;
  static const double selectedBorderWidth = 2;
  static const Duration transitionDuration = Duration(milliseconds: 160);
  static const Duration sheetDuration = Duration(milliseconds: 220);

  static Color mutedControl(ReaderPalette palette) => Color.lerp(
    palette.panel,
    palette.text,
    palette.systemBrightness == Brightness.dark ? .08 : .045,
  )!;

  static Color selectedControl(ReaderPalette palette) => Color.lerp(
    palette.panel,
    palette.systemBrightness == Brightness.dark ? Colors.white : Colors.black,
    palette.systemBrightness == Brightness.dark ? .12 : .02,
  )!;

  static Color sheetBarrier(ReaderPalette palette) =>
      Colors.black.withValues(alpha: .34);
}
