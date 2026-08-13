import 'package:flutter/material.dart';

/// Defines the application-wide visual defaults and semantic UI tokens.
abstract final class AppTheme {
  static ThemeData light() {
    const AppThemeTokens tokens = AppThemeTokens(
      pageBackground: Color(0xFFFFFCF8),
      surface: Color(0xFFFFFFFF),
      featureSurface: Color(0xFFFFF4E4),
      mutedSurface: Color(0xFFF8F3ED),
      divider: Color(0xFFE9E1D8),
      mutedText: Color(0xFF7D766E),
      accent: Color(0xFFC98333),
      accentSoft: Color(0xFFFFE7C5),
      notification: Color(0xFFE34835),
      success: Color(0xFF3D8A63),
      warning: Color(0xFFB56D24),
      focusRing: Color(0xFF9C5B16),
      shadow: Color(0x33261C12),
      coverDuskStart: Color(0xFF293746),
      coverDuskEnd: Color(0xFF725536),
      coverDawnStart: Color(0xFFE1A15B),
      coverDawnEnd: Color(0xFF516C80),
      coverOceanStart: Color(0xFF1D3C6A),
      coverOceanEnd: Color(0xFF557FAD),
      coverIndigoStart: Color(0xFF252542),
      coverIndigoEnd: Color(0xFF8A6D96),
      coverEmberStart: Color(0xFF5E3527),
      coverEmberEnd: Color(0xFFCA8B40),
    );
    final ColorScheme colorScheme =
        ColorScheme.fromSeed(
          seedColor: tokens.accent,
          brightness: Brightness.light,
        ).copyWith(
          primary: tokens.accent,
          onPrimary: Colors.white,
          primaryContainer: tokens.accentSoft,
          onPrimaryContainer: const Color(0xFF472706),
          surface: tokens.surface,
          onSurface: const Color(0xFF201C18),
          outlineVariant: tokens.divider,
        );
    return _theme(colorScheme, tokens);
  }

  static ThemeData dark() {
    const AppThemeTokens tokens = AppThemeTokens(
      pageBackground: Color(0xFF17130F),
      surface: Color(0xFF211B16),
      featureSurface: Color(0xFF30251C),
      mutedSurface: Color(0xFF2A231D),
      divider: Color(0xFF4A4037),
      mutedText: Color(0xFFC8BEB2),
      accent: Color(0xFFE1A657),
      accentSoft: Color(0xFF5D421C),
      notification: Color(0xFFFF7666),
      success: Color(0xFF81C99E),
      warning: Color(0xFFE3A45B),
      focusRing: Color(0xFFFFC878),
      shadow: Color(0x66000000),
      coverDuskStart: Color(0xFF485B68),
      coverDuskEnd: Color(0xFF9D7445),
      coverDawnStart: Color(0xFFB66C35),
      coverDawnEnd: Color(0xFF5E879C),
      coverOceanStart: Color(0xFF315D91),
      coverOceanEnd: Color(0xFF789FC8),
      coverIndigoStart: Color(0xFF45415F),
      coverIndigoEnd: Color(0xFFAF8FBC),
      coverEmberStart: Color(0xFF8A4B36),
      coverEmberEnd: Color(0xFFEBAD56),
    );
    final ColorScheme colorScheme =
        ColorScheme.fromSeed(
          seedColor: tokens.accent,
          brightness: Brightness.dark,
        ).copyWith(
          primary: tokens.accent,
          onPrimary: const Color(0xFF352108),
          primaryContainer: tokens.accentSoft,
          onPrimaryContainer: const Color(0xFFFFDCB0),
          surface: tokens.surface,
          onSurface: const Color(0xFFF5EDE4),
          outlineVariant: tokens.divider,
        );
    return _theme(colorScheme, tokens);
  }

  static ThemeData _theme(ColorScheme colorScheme, AppThemeTokens tokens) {
    final ThemeData base = ThemeData(
      colorScheme: colorScheme,
      fontFamily: 'packages/novel_reader_ui/MiSans',
      useMaterial3: true,
    );
    final TextTheme textTheme = base.textTheme.copyWith(
      displaySmall: base.textTheme.displaySmall?.copyWith(
        fontSize: 34,
        fontWeight: FontWeight.w700,
        height: 1.18,
        letterSpacing: -0.6,
      ),
      titleLarge: base.textTheme.titleLarge?.copyWith(
        fontSize: 24,
        fontWeight: FontWeight.w700,
        height: 1.25,
      ),
      titleMedium: base.textTheme.titleMedium?.copyWith(
        fontSize: 18,
        fontWeight: FontWeight.w700,
        height: 1.3,
      ),
      bodyLarge: base.textTheme.bodyLarge?.copyWith(fontSize: 16, height: 1.5),
      bodyMedium: base.textTheme.bodyMedium?.copyWith(
        fontSize: 14,
        height: 1.45,
      ),
      bodySmall: base.textTheme.bodySmall?.copyWith(fontSize: 12, height: 1.4),
      labelLarge: base.textTheme.labelLarge?.copyWith(
        fontSize: 15,
        fontWeight: FontWeight.w700,
      ),
    );

    return base.copyWith(
      scaffoldBackgroundColor: tokens.pageBackground,
      focusColor: tokens.focusRing.withValues(alpha: 0.24),
      hoverColor: tokens.accentSoft.withValues(alpha: 0.42),
      highlightColor: tokens.accentSoft.withValues(alpha: 0.56),
      textTheme: textTheme,
      dividerTheme: DividerThemeData(color: tokens.divider, space: 1),
      appBarTheme: AppBarTheme(
        backgroundColor: tokens.pageBackground,
        foregroundColor: colorScheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: colorScheme.inverseSurface,
        contentTextStyle: textTheme.bodyMedium?.copyWith(
          color: colorScheme.onInverseSurface,
        ),
      ),
      extensions: <ThemeExtension<dynamic>>[tokens],
    );
  }
}

/// Semantic colors for MgRead surfaces and neutral cover placeholders.
@immutable
class AppThemeTokens extends ThemeExtension<AppThemeTokens> {
  /// Creates one complete semantic token collection.
  const AppThemeTokens({
    required this.pageBackground,
    required this.surface,
    required this.featureSurface,
    required this.mutedSurface,
    required this.divider,
    required this.mutedText,
    required this.accent,
    required this.accentSoft,
    required this.notification,
    required this.success,
    required this.warning,
    required this.focusRing,
    required this.shadow,
    required this.coverDuskStart,
    required this.coverDuskEnd,
    required this.coverDawnStart,
    required this.coverDawnEnd,
    required this.coverOceanStart,
    required this.coverOceanEnd,
    required this.coverIndigoStart,
    required this.coverIndigoEnd,
    required this.coverEmberStart,
    required this.coverEmberEnd,
  });

  /// Reads the active token collection from [context].
  static AppThemeTokens of(BuildContext context) {
    return Theme.of(context).extension<AppThemeTokens>()!;
  }

  final Color pageBackground;
  final Color surface;
  final Color featureSurface;
  final Color mutedSurface;
  final Color divider;
  final Color mutedText;
  final Color accent;
  final Color accentSoft;
  final Color notification;
  final Color success;
  final Color warning;
  final Color focusRing;
  final Color shadow;
  final Color coverDuskStart;
  final Color coverDuskEnd;
  final Color coverDawnStart;
  final Color coverDawnEnd;
  final Color coverOceanStart;
  final Color coverOceanEnd;
  final Color coverIndigoStart;
  final Color coverIndigoEnd;
  final Color coverEmberStart;
  final Color coverEmberEnd;

  @override
  AppThemeTokens copyWith({
    Color? pageBackground,
    Color? surface,
    Color? featureSurface,
    Color? mutedSurface,
    Color? divider,
    Color? mutedText,
    Color? accent,
    Color? accentSoft,
    Color? notification,
    Color? success,
    Color? warning,
    Color? focusRing,
    Color? shadow,
    Color? coverDuskStart,
    Color? coverDuskEnd,
    Color? coverDawnStart,
    Color? coverDawnEnd,
    Color? coverOceanStart,
    Color? coverOceanEnd,
    Color? coverIndigoStart,
    Color? coverIndigoEnd,
    Color? coverEmberStart,
    Color? coverEmberEnd,
  }) {
    return AppThemeTokens(
      pageBackground: pageBackground ?? this.pageBackground,
      surface: surface ?? this.surface,
      featureSurface: featureSurface ?? this.featureSurface,
      mutedSurface: mutedSurface ?? this.mutedSurface,
      divider: divider ?? this.divider,
      mutedText: mutedText ?? this.mutedText,
      accent: accent ?? this.accent,
      accentSoft: accentSoft ?? this.accentSoft,
      notification: notification ?? this.notification,
      success: success ?? this.success,
      warning: warning ?? this.warning,
      focusRing: focusRing ?? this.focusRing,
      shadow: shadow ?? this.shadow,
      coverDuskStart: coverDuskStart ?? this.coverDuskStart,
      coverDuskEnd: coverDuskEnd ?? this.coverDuskEnd,
      coverDawnStart: coverDawnStart ?? this.coverDawnStart,
      coverDawnEnd: coverDawnEnd ?? this.coverDawnEnd,
      coverOceanStart: coverOceanStart ?? this.coverOceanStart,
      coverOceanEnd: coverOceanEnd ?? this.coverOceanEnd,
      coverIndigoStart: coverIndigoStart ?? this.coverIndigoStart,
      coverIndigoEnd: coverIndigoEnd ?? this.coverIndigoEnd,
      coverEmberStart: coverEmberStart ?? this.coverEmberStart,
      coverEmberEnd: coverEmberEnd ?? this.coverEmberEnd,
    );
  }

  @override
  AppThemeTokens lerp(
    covariant ThemeExtension<AppThemeTokens>? other,
    double t,
  ) {
    if (other is! AppThemeTokens) {
      return this;
    }
    return AppThemeTokens(
      pageBackground: Color.lerp(pageBackground, other.pageBackground, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      featureSurface: Color.lerp(featureSurface, other.featureSurface, t)!,
      mutedSurface: Color.lerp(mutedSurface, other.mutedSurface, t)!,
      divider: Color.lerp(divider, other.divider, t)!,
      mutedText: Color.lerp(mutedText, other.mutedText, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentSoft: Color.lerp(accentSoft, other.accentSoft, t)!,
      notification: Color.lerp(notification, other.notification, t)!,
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      focusRing: Color.lerp(focusRing, other.focusRing, t)!,
      shadow: Color.lerp(shadow, other.shadow, t)!,
      coverDuskStart: Color.lerp(coverDuskStart, other.coverDuskStart, t)!,
      coverDuskEnd: Color.lerp(coverDuskEnd, other.coverDuskEnd, t)!,
      coverDawnStart: Color.lerp(coverDawnStart, other.coverDawnStart, t)!,
      coverDawnEnd: Color.lerp(coverDawnEnd, other.coverDawnEnd, t)!,
      coverOceanStart: Color.lerp(coverOceanStart, other.coverOceanStart, t)!,
      coverOceanEnd: Color.lerp(coverOceanEnd, other.coverOceanEnd, t)!,
      coverIndigoStart: Color.lerp(
        coverIndigoStart,
        other.coverIndigoStart,
        t,
      )!,
      coverIndigoEnd: Color.lerp(coverIndigoEnd, other.coverIndigoEnd, t)!,
      coverEmberStart: Color.lerp(coverEmberStart, other.coverEmberStart, t)!,
      coverEmberEnd: Color.lerp(coverEmberEnd, other.coverEmberEnd, t)!,
    );
  }
}

/// Shared semantic dimensions for responsive product UI.
abstract final class AppSpacing {
  static const double unit = 4;
  static const double compact = unit * 2;
  static const double regular = unit * 3;
  static const double comfortable = unit * 4;
  static const double section = unit * 6;
  static const double page = unit * 8;
  static const double compactPagePadding = unit * 5;
  static const double widePagePadding = unit * 8;
  static const double minimumTouchTarget = 48;
  static const double contentMaxWidth = 1184;
  static const double mediumBreakpoint = 720;
  static const double wideBreakpoint = 980;
  static const double continueReadingCoverWidth = 116;
  static const double continueReadingCoverHeight = 160;
  static const double listCoverWidth = 80;
  static const double listCoverHeight = 112;
  static const double bottomNavigationHeight = 76;
  static const double compactCardStackBreakpoint = 360;
}

/// Shared semantic corner radii for MgRead surfaces.
abstract final class AppRadii {
  static const BorderRadius card = BorderRadius.all(Radius.circular(24));
  static const BorderRadius surface = BorderRadius.all(Radius.circular(16));
  static const BorderRadius control = BorderRadius.all(Radius.circular(12));
  static const BorderRadius pill = BorderRadius.all(Radius.circular(999));
}
