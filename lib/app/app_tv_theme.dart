/// TV adjustments to the existing application theme, not a separate palette.
/// Large labels and persistent focus contrast also apply to shared dialogs.
library;

import 'package:flutter/material.dart';

ThemeData appTvTheme(ThemeData base) {
  final focus = base.colorScheme.primary;
  final side = WidgetStateProperty.resolveWith<BorderSide?>(
    (states) => states.contains(WidgetState.focused) ? BorderSide(color: focus, width: 3) : null,
  );
  final style = ButtonStyle(side: side, minimumSize: const WidgetStatePropertyAll(Size(56, 52)));
  final text = base.textTheme;
  TextStyle enlarge(TextStyle? value, double fallback) =>
      (value ?? const TextStyle()).copyWith(fontSize: (value?.fontSize ?? fallback) * 1.15);
  return base.copyWith(
    splashFactory: NoSplash.splashFactory,
    textTheme: text.copyWith(
      headlineLarge: enlarge(text.headlineLarge, 32),
      headlineMedium: enlarge(text.headlineMedium, 28),
      headlineSmall: enlarge(text.headlineSmall, 24),
      titleLarge: enlarge(text.titleLarge, 22),
      titleMedium: enlarge(text.titleMedium, 16),
      titleSmall: enlarge(text.titleSmall, 14),
      bodyLarge: enlarge(text.bodyLarge, 16),
      bodyMedium: enlarge(text.bodyMedium, 14),
      bodySmall: enlarge(text.bodySmall, 12),
      labelLarge: enlarge(text.labelLarge, 14),
    ),
    focusColor: focus.withValues(alpha: .4),
    textButtonTheme: TextButtonThemeData(style: base.textButtonTheme.style?.merge(style) ?? style),
    filledButtonTheme: FilledButtonThemeData(style: base.filledButtonTheme.style?.merge(style) ?? style),
    outlinedButtonTheme: OutlinedButtonThemeData(style: base.outlinedButtonTheme.style?.merge(style) ?? style),
    iconButtonTheme: IconButtonThemeData(style: base.iconButtonTheme.style?.merge(style) ?? style),
  );
}
