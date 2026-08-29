import 'package:flutter/material.dart';

import '../reader_theme.dart';

abstract final class ReaderSettingsTokens {
  static const double sheetHeightFactor = .76;
  static const double maxSheetWidth = 720;
  static const double maxDesktopSheetHeight = 500;
  static const double maxContentWidth = 560;
  static const double compactBreakpoint = 520;
  static const double contentHorizontalPadding = 12;
  static const double contentVerticalPadding = 8;
  static const double labelWidth = 56;
  static const double sectionLabelFontSize = 13;
  static const double controlTextSize = 11.5;
  static const double subpageLabelFontSize = 12.5;
  static const double subpageTitleFontSize = 16;
  static const double rowMinHeight = 48;
  static const double controlHeight = 36;
  static const double touchTarget = 48;
  static const double swatchSize = 30;
  static const double backgroundPreviewWidth = 68;
  static const double backgroundPreviewHeight = 34;
  static const double navHeight = 58;
  static const double eyeCareControlWidth = 100;
  static const double fontSizeControlWidth = 128;
  static const double autoReadingSpeedControlWidth = 176;
  static const double fontCatalogPreviewSize = 52;
  static const double fontCatalogCardRadius = 11;
  static const double smallRadius = 8;
  static const double controlRadius = 14;
  static const double sheetRadius = 18;
  static const double selectedBorderWidth = 1.5;
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
