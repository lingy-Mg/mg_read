/// MgRead 应用主题与全局视觉语义。
///
/// 职责：
/// - 提供颜色、排版、尺寸、圆角和动效 token。
/// - 集中解析系统“减少动态效果”偏好与可打断时长。
///
/// 注意：
/// - 页面不得建立平行的视觉或动效规格。
/// - 动效 token 不表示网络或持久化任务的真实进度。
///
/// - 无。
library;

import 'package:flutter/material.dart';

/// Preset accent palettes for host application surfaces.
///
/// These values intentionally do not flow into the novel, comic, audio, or
/// video readers. Those packages own their own appearance and reading
/// controls.
enum AppThemeColor {
  warm('warm', '暖光橙', Color(0xFFCC8836)),
  blue('blue', '海盐蓝', Color(0xFF4F7CAC)),
  green('green', '竹青绿', Color(0xFF4F8A65)),
  purple('purple', '雾紫', Color(0xFF7C6DB0)),
  rose('rose', '樱桃红', Color(0xFFB85C78));

  const AppThemeColor(this.id, this.label, this.accent);

  final String id;
  final String label;
  final Color accent;

  static AppThemeColor fromId(String id) {
    return values.firstWhere((color) => color.id == id, orElse: () => AppThemeColor.warm);
  }
}

/// Preset dark palettes for host application surfaces.
///
/// Every palette keeps its large surfaces near black so the setting remains
/// comfortable for night use while still offering different accent moods.
enum AppDarkThemeColor {
  seaSaltBlue(
    'blue',
    '海盐蓝',
    Color(0xFF8AB4F8),
    Color(0xFF000000),
    Color(0xFF0B0E12),
    Color(0xFF131820),
    Color(0xFF11151A),
    Color(0xFF252B33),
    Color(0xFFA6AFBB),
    Color(0xFF17263A),
    Color(0xFFB5D1FF),
  ),
  coolBlack(
    'coolBlack',
    '酷黑',
    Color(0xFFD7DCE5),
    Color(0xFF000000),
    Color(0xFF08090B),
    Color(0xFF101216),
    Color(0xFF0D0E11),
    Color(0xFF25272C),
    Color(0xFFA9AFB9),
    Color(0xFF1B1D22),
    Color(0xFFF0F2F5),
  ),
  forestBlack(
    'forestBlack',
    '墨绿黑',
    Color(0xFF8FD3A6),
    Color(0xFF020806),
    Color(0xFF08130D),
    Color(0xFF0F1D14),
    Color(0xFF0C1911),
    Color(0xFF203128),
    Color(0xFFA1B9AA),
    Color(0xFF14291D),
    Color(0xFFB6E8C5),
  ),
  purpleBlack(
    'purpleBlack',
    '黛紫黑',
    Color(0xFFD0A6FF),
    Color(0xFF08050C),
    Color(0xFF140A1B),
    Color(0xFF21102A),
    Color(0xFF1A0D22),
    Color(0xFF382342),
    Color(0xFFB9A9C8),
    Color(0xFF29163A),
    Color(0xFFE4CFFF),
  ),
  amberBlack(
    'amberBlack',
    '暖炭黑',
    Color(0xFFFFC18A),
    Color(0xFF0A0806),
    Color(0xFF15100C),
    Color(0xFF211811),
    Color(0xFF1A120C),
    Color(0xFF3A2A1D),
    Color(0xFFC0AA96),
    Color(0xFF332015),
    Color(0xFFFFD4AF),
  );

  const AppDarkThemeColor(
    this.id,
    this.label,
    this.accent,
    this.pageBackground,
    this.surface,
    this.featureSurface,
    this.mutedSurface,
    this.divider,
    this.mutedText,
    this.accentSoft,
    this.focusRing,
  );

  final String id;
  final String label;
  final Color accent;
  final Color pageBackground;
  final Color surface;
  final Color featureSurface;
  final Color mutedSurface;
  final Color divider;
  final Color mutedText;
  final Color accentSoft;
  final Color focusRing;

  static AppDarkThemeColor fromId(String id) {
    return values.firstWhere((color) => color.id == id, orElse: () => AppDarkThemeColor.seaSaltBlue);
  }
}

/// Defines the application-wide visual defaults and semantic UI tokens.
abstract final class AppTheme {
  /// Temporary product switch while the source-picker visual baseline is light-only.
  static const bool darkModeEnabled = false;
  static final ThemeData _novelReaderTheme = _light(color: AppThemeColor.warm, connectMaterialSurfaces: false);

  /// Stable host baseline for novel and comic reading surfaces.
  ///
  /// Reading surfaces have their own visual language and preferences, so the
  /// selected application accent and dark-mode setting must not flow into
  /// their entry, detail, or catalog UI.
  static ThemeData novelReader() => _novelReaderTheme;

  static ThemeData light({AppThemeColor color = AppThemeColor.warm}) => _light(color: color, connectMaterialSurfaces: true);

  static ThemeData _light({required AppThemeColor color, required bool connectMaterialSurfaces}) {
    const pageBackground = Color(0xFFFDFBFA);
    const surface = Color(0xFFFEFDFB);
    final Color featureSurface = color == AppThemeColor.warm
        ? const Color(0xFFF9EBDC)
        : Color.alphaBlend(color.accent.withValues(alpha: 0.08), surface);
    final Color accentSoft = color == AppThemeColor.warm
        ? const Color(0xFFF9EFE2)
        : Color.alphaBlend(color.accent.withValues(alpha: 0.11), pageBackground);
    final Color focusRing = color == AppThemeColor.warm ? const Color(0xFF9C5B16) : color.accent;
    final AppThemeTokens tokens = AppThemeTokens(
      pageBackground: pageBackground,
      surface: surface,
      featureSurface: featureSurface,
      mutedSurface: const Color(0xFFF7F4EF),
      divider: const Color(0xFFF1ECE5),
      mutedText: const Color(0xFF827D77),
      accent: color.accent,
      dataSourceAccent: const Color(0xFFE96A0A),
      dataSourceCat: const Color(0xFFFFC300),
      dataSourceCommunity: const Color(0xFF509B30),
      accentSoft: accentSoft,
      notification: const Color(0xFFE34835),
      success: const Color(0xFF3D8A63),
      warning: const Color(0xFFB56D24),
      focusRing: focusRing,
      shadow: const Color(0x33261C12),
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
    final ColorScheme seededScheme = ColorScheme.fromSeed(seedColor: tokens.accent, brightness: Brightness.light);
    final ColorScheme baseColorScheme = seededScheme.copyWith(
      primary: tokens.accent,
      onPrimary: Colors.white,
      primaryContainer: tokens.accentSoft,
      onPrimaryContainer: color == AppThemeColor.warm ? const Color(0xFF472706) : seededScheme.onPrimaryContainer,
      surface: tokens.surface,
      onSurface: const Color(0xFF201C18),
      outlineVariant: tokens.divider,
    );
    final ColorScheme colorScheme = connectMaterialSurfaces ? _connectMaterialSurfaces(baseColorScheme, tokens) : baseColorScheme;
    return _theme(colorScheme, tokens);
  }

  static ThemeData dark({AppDarkThemeColor color = AppDarkThemeColor.seaSaltBlue}) {
    final AppThemeTokens tokens = AppThemeTokens(
      pageBackground: color.pageBackground,
      surface: color.surface,
      featureSurface: color.featureSurface,
      mutedSurface: color.mutedSurface,
      divider: color.divider,
      mutedText: color.mutedText,
      accent: color.accent,
      dataSourceAccent: Color(0xFFFF9A62),
      dataSourceCat: Color(0xFFFFC857),
      dataSourceCommunity: Color(0xFF81C995),
      accentSoft: color.accentSoft,
      notification: Color(0xFFFF8B8B),
      success: Color(0xFF7DDBA5),
      warning: Color(0xFFFFC266),
      focusRing: color.focusRing,
      shadow: Color(0x99000000),
      coverDuskStart: Color(0xFF182433),
      coverDuskEnd: Color(0xFF455B73),
      coverDawnStart: Color(0xFF304B68),
      coverDawnEnd: Color(0xFF657F9B),
      coverOceanStart: Color(0xFF163252),
      coverOceanEnd: Color(0xFF4E7BA8),
      coverIndigoStart: Color(0xFF22243A),
      coverIndigoEnd: Color(0xFF5C6197),
      coverEmberStart: Color(0xFF3C2735),
      coverEmberEnd: Color(0xFF8A5167),
    );
    final ColorScheme baseColorScheme = ColorScheme.fromSeed(seedColor: tokens.accent, brightness: Brightness.dark).copyWith(
      primary: tokens.accent,
      onPrimary: color == AppDarkThemeColor.seaSaltBlue ? const Color(0xFF07111F) : const Color(0xFF111111),
      primaryContainer: tokens.accentSoft,
      onPrimaryContainer: color == AppDarkThemeColor.seaSaltBlue ? const Color(0xFFD7E7FF) : const Color(0xFFE8EDF3),
      surface: tokens.surface,
      onSurface: const Color(0xFFE8EDF3),
      outlineVariant: tokens.divider,
    );
    final ColorScheme colorScheme = _connectMaterialSurfaces(baseColorScheme, tokens);
    return _theme(colorScheme, tokens);
  }

  /// Connects Material 3's component-level roles to the host token system.
  ///
  /// Cards, dialogs, menus, navigation surfaces, chips and filled inputs read
  /// these roles directly instead of [ColorScheme.surface]. Keeping the map at
  /// this boundary prevents those widgets from falling back to an unrelated
  /// seed-generated neutral palette. Reader-owned themes deliberately skip it.
  static ColorScheme _connectMaterialSurfaces(ColorScheme scheme, AppThemeTokens tokens) {
    final bool isDark = scheme.brightness == Brightness.dark;
    return scheme.copyWith(
      secondary: tokens.accent,
      onSecondary: scheme.onPrimary,
      secondaryContainer: tokens.accentSoft,
      onSecondaryContainer: scheme.onPrimaryContainer,
      error: tokens.notification,
      surfaceDim: isDark ? tokens.pageBackground : tokens.mutedSurface,
      surfaceBright: isDark ? tokens.featureSurface : tokens.surface,
      surfaceContainerLowest: isDark ? tokens.pageBackground : tokens.surface,
      surfaceContainerLow: tokens.surface,
      surfaceContainer: tokens.mutedSurface,
      surfaceContainerHigh: tokens.featureSurface,
      surfaceContainerHighest: tokens.featureSurface,
      onSurfaceVariant: tokens.mutedText,
      outline: tokens.mutedText,
      outlineVariant: tokens.divider,
      inverseSurface: scheme.onSurface,
      onInverseSurface: tokens.pageBackground,
      inversePrimary: tokens.accent,
      surfaceTint: Colors.transparent,
    );
  }

  static ThemeData _theme(ColorScheme colorScheme, AppThemeTokens tokens) {
    final ThemeData base = ThemeData(colorScheme: colorScheme, fontFamily: 'packages/novel_reader_ui/MiSans', useMaterial3: true);
    final TextTheme textTheme = base.textTheme.copyWith(
      displaySmall: base.textTheme.displaySmall?.copyWith(
        fontSize: AppTypography.display,
        fontWeight: FontWeight.w700,
        height: 1.18,
        letterSpacing: -0.6,
      ),
      titleLarge: base.textTheme.titleLarge?.copyWith(fontSize: AppTypography.sectionTitle, fontWeight: FontWeight.w600, height: 1.25),
      titleMedium: base.textTheme.titleMedium?.copyWith(fontSize: AppTypography.itemTitle, fontWeight: FontWeight.w600, height: 1.3),
      bodyLarge: base.textTheme.bodyLarge?.copyWith(fontSize: AppTypography.body, height: 1.5),
      bodyMedium: base.textTheme.bodyMedium?.copyWith(fontSize: AppTypography.secondary, height: 1.45),
      bodySmall: base.textTheme.bodySmall?.copyWith(fontSize: AppTypography.caption, height: 1.4),
      labelLarge: base.textTheme.labelLarge?.copyWith(fontSize: AppTypography.action, fontWeight: FontWeight.w600),
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
        contentTextStyle: textTheme.bodyMedium?.copyWith(color: colorScheme.onInverseSurface),
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
  static const double discoveryListTag = 10;
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
  AppThemeTokens lerp(covariant ThemeExtension<AppThemeTokens>? other, double t) {
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
      dataSourceAccent: Color.lerp(dataSourceAccent, other.dataSourceAccent, t)!,
      dataSourceCat: Color.lerp(dataSourceCat, other.dataSourceCat, t)!,
      dataSourceCommunity: Color.lerp(dataSourceCommunity, other.dataSourceCommunity, t)!,
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
      coverIndigoStart: Color.lerp(coverIndigoStart, other.coverIndigoStart, t)!,
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

  /// Non-Android breathing room between the system safe area and page chrome.
  static const double pageHeaderTopPadding = compact;
  static const double pageHeaderHeight = unit * 10;

  /// Keeps Android page chrome flush with the status-bar safe area.
  ///
  /// Other platforms retain the existing eight-dp page rhythm.
  static double pageHeaderTopPaddingFor(BuildContext context) =>
      Theme.of(context).platform == TargetPlatform.android ? 0 : pageHeaderTopPadding;

  /// Backwards-compatible alias for the shared primary-page title scale.
  static const double pageTitleSize = AppTypography.pageTitle;
  static const double minimumTouchTarget = 48;
  static const double sectionControlHeight = unit * 8;
  static const double statusFilterHeight = unit * 6;
  static const double mobileViewportWidth = 390;
  static const double mobileContentMaxWidth = mobileViewportWidth;

  /// Shared maximum width for constrained destinations and secondary pages.
  ///
  /// The library home intentionally stays full-width so its shelf can use all
  /// available space on large displays.
  static const double contentMaxWidth = 1184;
  static const double compactLayoutBreakpoint = 720;
  static const double continueReadingCoverWidth = unit * 28;
  static const double continueReadingCoverHeight = unit * 40;
  static const double continueReadingCardHeight = unit * 30;
  static const double continueReadingCardTopInset = unit * 5;
  static const double continueReadingCardCoverOverlap = unit * 7;
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
  static const double bottomNavigationMaxWidth = 560;
  static const double bottomNavigationContentBottomPadding = bottomNavigationHeight + page;
  static const double bottomNavigationItemHeight = unit * 13;
  static const double topBarActionSize = unit * 10;
  static const double topBarActionIconSize = unit * 5 + 2;
  static const double bottomNavigationIconSize = unit * 6;
  static const double bottomNavigationLabelSize = 11;
  static const double bottomNavigationIndicatorWidth = unit * 14;
  static const double bottomNavigationIndicatorHeight = unit * 10;
  static const double unreadDotSize = unit + unit / 2;
  static const double profileCardHeight = 196;
  static const double profileSummaryHeight = 153;
  static const double profileSyncRowHeight = 43;
  static const double profileCardHorizontalPadding = comfortable;
  static const double profileAvatarSize = unit * 14;
  static const double profileNameTop = unit * 6;
  static const double profileMottoTop = unit * 14;
  static const double profileStatsTop = unit * 22;
  static const double profileEditHeight = unit * 8;
  static const double profileEditReservedWidth = unit * 20;
  static const double profileSettingsRowHeight = unit * 12;
  static const double profileSettingsListGap = unit * 2;
  static const double profileSettingsIconSlot = unit * 6;
  static const double profileSettingsIconSize = unit * 5;
  static const double profileSettingsIconTextGap = compact;
  static const double profileSettingsDividerStart = unit * 12;
  static const double profileSettingsTrailingRight = comfortable;
  static const double profileChevronSize = unit * 4 + 2;
  static const double profileStatsDividerHeight = section;
  static const double profileStatsDividerThickness = unit / 8;
  static const double profileSyncIconSize = unit * 5;
  static const double profileContentBottomSafeDistance = bottomNavigationHeight + comfortable;
  static const double compactCardStackBreakpoint = 280;
  static const double discoveryPagePadding = unit * 4;
  static const double discoverySectionSpacing = page;
  static const double discoverySectionContentGap = regular;
  static const double discoveryComponentGap = regular;
  static const double discoveryPanelPadding = regular;
  static const double discoveryCompactRowMinHeight = unit * 13;
  static const double discoveryChipVisualHeight = unit * 9;
  static const double discoveryShelfItemWidth = unit * 26;
  static const double discoveryShelfHeight = unit * 47;
  static const double discoveryCoverAspectRatio = 1.38;
  static const double discoveryLandscapeCoverAspectRatio = 9 / 16;
  static const double discoveryCoverMetadataExtent = unit * 13;
  static const double discoveryGroupCardWidth = unit * 80;
  static const double discoveryLoadMoreHeight = unit * 10;
  static const double discoveryListMaxWidth = 692;
  static const double discoveryListCoverMinWidth = unit * 23;
  static const double discoveryListCoverMaxWidth = unit * 28;
  static const double discoveryListCoverAspectRatio = 1.3;
  static const double discoveryListTagHeight = 18;
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
  static const double dataSourceRowHeight = unit * 17;
  static const double dataSourceMarkExtent = unit * 9;
  static const double dataSourceManagementMarkExtent = unit * 12;
  static const double dataSourceNameSize = 18;
  static const double dataSourceMetadataSize = 14;
  static const double dataSourceAddIconSize = 27;
  static const double dataSourceAddButtonHeight = unit * 12;
  static const double dataSourceNavigationHeight = unit * 15;
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
  static const double bottomNavigationContentBottomPadding = bottomNavigationHeight + AppSpacing.page;

  static const double aboutIconTopGap = 29;
  static const double aboutIconExtent = 106;
  // Preserves the measured about-page card baseline after compact typography.
  static const double aboutCardTopGap = 49;
  static const double aboutCardHeight = 256;
  static const double aboutRowHeight = 64;

  static const double feedbackBannerHeight = 108;
  static const double feedbackCardTopGap = 15;
}

/// Shared semantic corner radii for MgRead surfaces.
abstract final class AppRadii {
  static const BorderRadius card = BorderRadius.all(Radius.circular(20));
  static const BorderRadius surface = BorderRadius.all(Radius.circular(12));
  static const BorderRadius control = BorderRadius.all(Radius.circular(12));
  static const BorderRadius continueReadingAction = BorderRadius.all(Radius.circular(10));
  static const BorderRadius bookCover = BorderRadius.all(Radius.circular(6));
  static const BorderRadius profileList = BorderRadius.all(Radius.circular(16));
  static const BorderRadius discoveryHero = BorderRadius.all(Radius.circular(16));
  static const BorderRadius discoveryPanel = BorderRadius.all(Radius.circular(12));
  static const BorderRadius discoveryCover = BorderRadius.all(Radius.circular(6));
  static const BorderRadius discoveryTile = BorderRadius.all(Radius.circular(8));
  static const BorderRadius discoveryButton = BorderRadius.all(Radius.circular(9));
  static const BorderRadius detailCard = BorderRadius.all(Radius.circular(14));
  static const BorderRadius detailControl = BorderRadius.all(Radius.circular(10));
  static const BorderRadius detailAppIcon = BorderRadius.all(Radius.circular(22));
  static const BorderRadius pill = BorderRadius.all(Radius.circular(999));
}

/// 全局、克制且可打断的动效语义。
///
/// 时长只描述视觉过渡，异步请求必须独立维持 loading/错误/内容状态。
abstract final class AppMotion {
  static const Duration micro = Duration(milliseconds: 120);
  static const Duration navigationSelection = Duration(milliseconds: 140);
  static const Duration short = Duration(milliseconds: 180);
  static const Duration shortReverse = Duration(milliseconds: 140);
  static const Duration loadingSettle = Duration(milliseconds: 120);
  static const Duration loadingShimmer = Duration(milliseconds: 980);
  static const Duration bottomNavigationIconResponse = Duration(milliseconds: 220);
  static const Duration bottomNavigationLabelResponse = Duration(milliseconds: 190);
  static const Duration bottomNavigationPillMinimumTravel = Duration(milliseconds: 180);
  static const Duration bottomNavigationPillTravel = Duration(milliseconds: 300);
  static const Duration privacyModeReveal = Duration(milliseconds: 520);
  static const Duration destinationTransition = short;
  static const Duration destinationReverseTransition = shortReverse;
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
  static const Curve standardCurve = Curves.easeInOutCubic;

  /// Returns whether the platform asks the app to avoid non-essential motion.
  static bool disablesAnimations(BuildContext context) {
    return MediaQuery.maybeOf(context)?.disableAnimations ?? false;
  }

  /// Resolves an implicit or route transition duration for the current policy.
  static Duration effectiveDuration(BuildContext context, Duration duration) {
    return disablesAnimations(context) ? Duration.zero : duration;
  }

  /// Keeps a retargeted controller's remaining travel proportional to distance.
  ///
  /// A zero result is deliberately synchronous for reduced-motion users.
  static Duration interruptedDuration({
    required Duration fullDuration,
    required double from,
    required double to,
    required bool disableAnimations,
    Duration minimumDuration = Duration.zero,
  }) {
    if (disableAnimations) return Duration.zero;
    final double distance = (to - from).abs().clamp(0, 1);
    final int scaledMicroseconds = (fullDuration.inMicroseconds * distance).round();
    return Duration(
      microseconds: scaledMicroseconds < minimumDuration.inMicroseconds ? minimumDuration.inMicroseconds : scaledMicroseconds,
    );
  }
}
