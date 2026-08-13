import 'package:flutter/material.dart';

/// Defines the application-wide visual defaults.
abstract final class AppTheme {
  static ThemeData light() {
    final ColorScheme colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFFB7593C),
      brightness: Brightness.light,
    );
    return _theme(colorScheme);
  }

  static ThemeData dark() {
    final ColorScheme colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFFD98564),
      brightness: Brightness.dark,
    );
    return _theme(colorScheme);
  }

  static ThemeData _theme(ColorScheme colorScheme) {
    return ThemeData(
      colorScheme: colorScheme,
      fontFamily: 'packages/novel_reader_ui/MiSans',
      scaffoldBackgroundColor: colorScheme.surface,
      useMaterial3: true,
    );
  }
}
