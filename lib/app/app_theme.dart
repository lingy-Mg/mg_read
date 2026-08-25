import 'package:flutter/material.dart';

/// Defines the application-wide visual defaults and semantic UI tokens.
abstract final class AppTheme {
  /// Temporary product switch while the source-picker visual baseline is light-only.
  static const bool darkModeEnabled = false;

  static ThemeData light() {
    const AppThemeTokens tokens = AppThemeTokens(
      pageBackground: Color(0xFFFDFBFA),
      surface: Color(0xFFFEFDFB),
      featureSurface: Color(0xFFF9EBDC),
      mutedSurface: Color(0xFFF7F4EF),
      divider: Color(0xFFF1ECE5),
      mutedText: Color(0xFF827D77),
      accent: Color(0xFFCC8836),
      dataSourceAccent: Color(0xFFE96A0A),
      dataSourceCat: Color(0xFFFFC300),
      dataSourceCommunity: Color(0xFF509B30),
      accentSoft: Color(0xFFF9EFE2),
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
      dataSourceAccent: Color(0xFFE1A657),
      dataSourceCat: Color(0xFFE1A657),
      dataSourceCommunity: Color(0xFF81C99E),
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
        fontSize: AppTypography.display,
        fontWeight: FontWeight.w700,
        height: 1.18,
        letterSpacing: -0.6,
      ),
      titleLarge: base.textTheme.titleLarge?.copyWith(
        fontSize: AppTypography.sectionTitle,
        fontWeight: FontWeight.w600,
        height: 1.25,
      ),
      titleMedium: base.textTheme.titleMedium?.copyWith(
        fontSize: AppTypography.itemTitle,
        fontWeight: FontWeight.w600,
        height: 1.3,
      ),
      bodyLarge: base.textTheme.bodyLarge?.copyWith(
        fontSize: AppTypography.body,
        height: 1.5,
      ),
      bodyMedium: base.textTheme.bodyMedium?.copyWith(
        fontSize: AppTypography.secondary,
        height: 1.45,
      ),
      bodySmall: base.textTheme.bodySmall?.copyWith(
        fontSize: AppTypography.caption,
        height: 1.4,
      ),
      labelLarge: base.textTheme.labelLarge?.copyWith(
        fontSize: AppTypography.action,
        fontWeight: FontWeight.w600,
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

/// Semantic typography scale shared by every app surface.
///
/// Components should select a [TextTheme] role instead of introducing a
/// feature-local font size. The page title is intentionally separate because
/// it is shared by the four primary destinations but is not a Material role.
abstract final class AppTypography {
  static const double display = 30;
  static const double pageTitle = 24;
  static const double sectionTitle = 18;
  static const double itemTitle = 16;
  static const double continueReadingTitleMinimum = 12;
  static const double body = 14;
  static const double secondary = 13;
  static const double caption = 11;
  static const double action = 14;
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
    required this.dataSourceAccent,
    required this.dataSourceCat,
    required this.dataSourceCommunity,
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
  final Color dataSourceAccent;
  final Color dataSourceCat;
  final Color dataSourceCommunity;
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
    Color? dataSourceAccent,
    Color? dataSourceCat,
    Color? dataSourceCommunity,
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
      dataSourceAccent: dataSourceAccent ?? this.dataSourceAccent,
      dataSourceCat: dataSourceCat ?? this.dataSourceCat,
      dataSourceCommunity: dataSourceCommunity ?? this.dataSourceCommunity,
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
      dataSourceAccent: Color.lerp(
        dataSourceAccent,
        other.dataSourceAccent,
        t,
      )!,
      dataSourceCat: Color.lerp(dataSourceCat, other.dataSourceCat, t)!,
      dataSourceCommunity: Color.lerp(
        dataSourceCommunity,
        other.dataSourceCommunity,
        t,
      )!,
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
  static const double pageHeaderTopPadding = compact;
  static const double pageHeaderHeight = unit * 10;

  /// Backwards-compatible alias for the shared primary-page title scale.
  static const double pageTitleSize = AppTypography.pageTitle;
  static const double minimumTouchTarget = 48;
  static const double sectionControlHeight = unit * 8;
  static const double statusFilterHeight = unit * 6;
  static const double mobileViewportWidth = 390;
  static const double mobileContentMaxWidth = mobileViewportWidth;
  static const double contentMaxWidth = 1184;
  static const double compactLayoutBreakpoint = 720;
  static const double continueReadingCoverWidth = unit * 26;
  static const double continueReadingCoverHeight = unit * 38;
  static const double continueReadingCardHeight = unit * 30;
  static const double continueReadingCardVerticalInset = unit * 4;
  static const double continueReadingCardCoverOverlap = unit * 8;
  static const double continueReadingVerticalPadding = 17;
  static const double continueReadingActionWidth = unit * 32;
  static const double continueReadingActionHeight = unit * 8;
  static const double continueReadingProgressWidth = 146;
  static const double continueReadingProgressValueGap = 14;
  static const double readingProgressHeight = unit;
  static const double listCoverWidth = unit * 13;
  static const double listCoverHeight = unit * 17;
  static const double bookListVerticalPadding = unit + unit / 4;
  static const double metadataTagHeight = unit * 4;
  static const double bookListTrailingWidth = unit * 22;
  static const double sourceManagerHeight = unit * 10;
  static const double sourceManagerGap = unit + unit / 2;
  static const double bottomNavigationHeight = unit * 18;
  static const double bottomNavigationItemHeight = unit * 13;
  static const double topBarActionSize = unit * 8;
  static const double topBarActionIconSize = unit * 6;
  static const double bottomNavigationIconSize = unit * 6;
  static const double bottomNavigationLabelSize = 11;
  static const double bottomNavigationIndicatorWidth = unit * 14;
  static const double bottomNavigationIndicatorHeight = unit * 10;
  static const double unreadDotSize = unit + unit / 2;
  static const double profileCardHeight = 196;
  static const double profileSummaryHeight = 153;
  static const double profileSyncRowHeight = 43;
  static const double profileAvatarSize = unit * 15;
  static const double profileNameTop = unit * 6;
  static const double profileMottoTop = unit * 13;
  static const double profileStatsTop = unit * 22;
  static const double profileEditWidth = unit * 15;
  static const double profileSettingsRowHeight = unit * 13 - 1;
  static const double profileSettingsIconSize = unit * 6;
  static const double profileSettingsLeadingWidth = unit * 9;
  static const double compactCardStackBreakpoint = 280;
  static const double discoveryPagePadding = unit * 4;
  static const double discoveryListMaxWidth = 692;
  static const double discoveryListCoverMinWidth = unit * 21;
  static const double discoveryListCoverMaxWidth = unit * 27;
  static const double discoveryListCoverAspectRatio = 1.3;
  static const double discoveryListTagHeight = unit * 5;
  static const double discoveryHeaderInset = unit;
  static const double discoveryHeaderHeight = pageHeaderHeight;
  static const double discoveryTabsHeight = unit * 8;
  static const double discoveryHeroHeight = unit * 46;
  static const double discoveryHeroCoverWidth = unit * 27;
  static const double discoveryHeroCoverHeight = unit * 41;
  static const double discoveryReadButtonWidth = unit * 21;
  static const double discoveryReadButtonHeight = 30;
  static const double discoveryPopularCoverWidth = unit * 15;
  static const double discoveryPopularCoverHeight = unit * 21;
  static const double discoveryPopularItemWidth = unit * 15;
  static const double discoveryBoardHeight = unit * 54;
  static const double discoveryBoardGap = unit * 2;
  static const double discoveryCategoryTileGap = 5;
  static const double discoveryCategoryTileMinWidth = 120;
  static const double discoveryRankCoverWidth = unit * 5;
  static const double discoveryRankCoverHeight = unit * 7;
  static const double discoveryCategoryTileHeight = 35;
  static const double discoveryEditorCardHeight = 86;
  static const double discoveryEditorCoverWidth = unit * 21;
  static const double discoveryEditorCoverHeight = 86;
  static const double dataSourceTopBarHeight = unit * 19;
  static const double dataSourcePageTitleSize = 24;
  static const double dataSourceHeaderIconSize = 24;
  static const double dataSourceSectionTitleSize = 22;
  static const double dataSourceRowHeight = unit * 15;
  static const double dataSourceMarkExtent = unit * 9;
  static const double dataSourceNameSize = 18;
  static const double dataSourceMetadataSize = 14;
  static const double dataSourceAddIconSize = 27;
  static const double dataSourceAddButtonHeight = unit * 12;
  static const double dataSourceNavigationHeight = unit * 15;
  static const double searchPageContentMaxWidth = 640;
  static const double searchPageHorizontalPadding = unit * 5;
  static const double searchTopBarHeight = unit * 10;
  static const double searchQueryHeight = unit * 10;
  static const double searchHistoryChipHeight = unit * 9;
  static const double searchResultCoverWidth = unit * 21;
  static const double searchResultCoverHeight = unit * 30;
  static const double searchResultVerticalPadding = unit * 3;
  static const double searchResultMetadataGap = unit + 2;
}

/// Measured dimensions shared by the profile detail pages.
///
/// The values are mapped from the 390 x 900 mobile reference viewport and are
/// kept separate from the broader home/profile rhythm so the detail pages do
/// not fall back to Material component defaults.
abstract final class AppDetailMetrics {
  static const double viewportWidth = 390;
  static const double horizontalPadding = 20;
  static const double minimumTopInset = 24;
  static const double topBarHeight = 64;
  static const double backButtonExtent = 48;
  static const double backButtonLeft = 8;
  static const double bottomNavigationHeight = 76;

  static const double aboutIconTopGap = 29;
  static const double aboutIconExtent = 106;
  // Preserves the measured about-page card baseline after compact typography.
  static const double aboutCardTopGap = 49;
  static const double aboutCardHeight = 320;
  static const double aboutRowHeight = 64;

  static const double feedbackBannerHeight = 108;
  static const double feedbackCardTopGap = 15;
  static const double feedbackCardHeight = 602;
  static const double feedbackCardPadding = 14;
  static const double feedbackTypeHeight = 31;
  static const double feedbackEditorHeight = 141;
  static const double feedbackUploadTileExtent = 96;
  static const double feedbackContactHeight = 34;
  static const double feedbackSubmitHeight = 39;
}

/// Shared semantic corner radii for MgRead surfaces.
abstract final class AppRadii {
  static const BorderRadius card = BorderRadius.all(Radius.circular(20));
  static const BorderRadius surface = BorderRadius.all(Radius.circular(12));
  static const BorderRadius control = BorderRadius.all(Radius.circular(12));
  static const BorderRadius continueReadingAction = BorderRadius.all(
    Radius.circular(10),
  );
  static const BorderRadius bookCover = BorderRadius.all(Radius.circular(6));
  static const BorderRadius profileList = BorderRadius.all(Radius.circular(16));
  static const BorderRadius discoveryHero = BorderRadius.all(
    Radius.circular(16),
  );
  static const BorderRadius discoveryPanel = BorderRadius.all(
    Radius.circular(12),
  );
  static const BorderRadius discoveryCover = BorderRadius.all(
    Radius.circular(6),
  );
  static const BorderRadius discoveryTile = BorderRadius.all(
    Radius.circular(8),
  );
  static const BorderRadius discoveryButton = BorderRadius.all(
    Radius.circular(9),
  );
  static const BorderRadius detailCard = BorderRadius.all(Radius.circular(14));
  static const BorderRadius detailControl = BorderRadius.all(
    Radius.circular(10),
  );
  static const BorderRadius detailAppIcon = BorderRadius.all(
    Radius.circular(22),
  );
  static const BorderRadius pill = BorderRadius.all(Radius.circular(999));
}

/// Shared motion timings for short, non-disruptive application feedback.
abstract final class AppMotion {
  static const Duration navigationSelection = Duration(milliseconds: 180);
  static const Duration bottomNavigationIconResponse = Duration(
    milliseconds: 300,
  );
  static const Duration bottomNavigationLabelResponse = Duration(
    milliseconds: 260,
  );
  static const Duration bottomNavigationPillTravel = Duration(
    milliseconds: 420,
  );
  static const Duration bottomNavigationTextureDrift = Duration(seconds: 8);
  static const Duration destinationTransition = Duration(milliseconds: 220);
  static const double bottomNavigationPillOvershoot = 0.045;
  static const double bottomNavigationPillTravelWidthScale = 0.72;
  static const double bottomNavigationPillTravelHeightScale = 0.8;
  static const double bottomNavigationPillArrivalWidthScale = 1.08;
  static const double bottomNavigationPillArrivalHeightScale = 1.06;
  static const double bottomNavigationSelectionHandoff = 0.64;
  static const double bottomNavigationSelectedIconScale = 1.12;
  static const double bottomNavigationUnselectedIconAlignmentY = -0.38;
  static const double bottomNavigationLabelAlignmentY = 0.58;
  static const Curve navigationCurve = Curves.easeOutCubic;
  static const Curve navigationReverseCurve = Curves.easeInCubic;
  static const Curve bottomNavigationTextureCurve = Curves.easeInOutSine;
}
