/// 阅读器偏好、平台状态与可恢复失败公共模型。
///
/// 保留既有默认值、归一化规则和兼容构造参数。
part of 'models.dart';

/// Built-in reader color themes. Hosts persist the value but do not style it.
enum ReaderThemePreset {
  /// Warm, light paper colors for daytime reading.
  day,

  /// Low-saturation green colors intended to reduce visual fatigue.
  eyeCare,

  /// Warm parchment colors with stronger sepia contrast.
  parchment,

  /// A restrained dark palette for conventional night reading.
  night,

  /// A cool, pale blue-gray reading palette.
  mistBlue,

  /// A deeper blue-black palette for very dark environments.
  deepNight,

  /// A neutral charcoal palette with subdued contrast.
  charcoal,
}

/// Built-in, reader-owned background treatments.
///
/// Backgrounds are independent from [ReaderThemePreset]. The reader combines
/// the selected treatment with the active theme while preserving text
/// contrast. Hosts persist the enum value but do not provide visual assets.
enum ReaderBackgroundPreset {
  /// A flat background without a decorative treatment.
  plain,

  /// A subtle, softly shaded paper treatment.
  softPaper,

  /// A light rice-paper-inspired texture.
  ricePaper,

  /// A restrained cloud treatment.
  clouds,

  /// A misty mountain treatment.
  mistMountains,

  /// A low-contrast distant landscape treatment.
  distantLandscape,
}

/// Built-in reader font choices.
///
/// The default [system] choice uses the bundled MiSans font so the reader
/// keeps a consistent appearance across Android and Windows.
enum ReaderFontPreset {
  /// The bundled default font and its platform fallback chain.
  system,

  /// The platform sans-serif family and its Chinese fallback chain.
  sansSerif,

  /// The platform serif family and its Chinese fallback chain.
  serif,
}

@immutable
/// Host-provided metadata for an optional downloadable reader font.
class ReaderFontDescriptor {
  /// Creates immutable font metadata returned by [ReaderFontRepository].
  ///
  /// The host owns URL access, licensing checks, downloads, integrity checks,
  /// and persistent caching. The reader treats URLs as opaque metadata and
  /// never fetches them directly.
  factory ReaderFontDescriptor({
    required String id,
    required String displayName,
    required String familyName,
    String? fontUrl,
    String? previewImageUrl,
    String? version,
    String? license,
    int? fileSizeBytes,
    String? sha256,
    List<int> weights = const <int>[],
  }) {
    return ReaderFontDescriptor._(
      id: id,
      displayName: displayName,
      familyName: familyName,
      fontUrl: fontUrl,
      previewImageUrl: previewImageUrl,
      version: version,
      license: license,
      fileSizeBytes: fileSizeBytes,
      sha256: sha256,
      weights: List<int>.unmodifiable(weights),
    );
  }

  const ReaderFontDescriptor._({
    required this.id,
    required this.displayName,
    required this.familyName,
    required this.fontUrl,
    required this.previewImageUrl,
    required this.version,
    required this.license,
    required this.fileSizeBytes,
    required this.sha256,
    required this.weights,
  });

  /// Stable identifier persisted in [TextReaderPreferences.customFontId].
  final String id;

  /// Localized font name displayed by the reader.
  final String displayName;

  /// Font family metadata declared by the host.
  ///
  /// Runtime implementations derive a private engine family from [id] and
  /// [version] so upgrading one descriptor cannot contaminate another.
  final String familyName;

  /// Optional remote font URL interpreted only by the host repository.
  final String? fontUrl;

  /// Optional remote preview-image URL interpreted only by the host repository.
  final String? previewImageUrl;

  /// Optional host-defined version used for cache identity.
  final String? version;

  /// Optional license name or concise license notice.
  final String? license;

  /// Optional expected font file size in bytes.
  final int? fileSizeBytes;

  /// Optional lowercase or uppercase SHA-256 digest supplied for host checks.
  final String? sha256;

  /// Immutable list of available numeric font weights.
  ///
  /// For every declared weight, the repository must be able to return the
  /// matching cached bytes after [ReaderFontRepository.install] completes.
  final List<int> weights;

  @override
  bool operator ==(Object other) =>
      other is ReaderFontDescriptor &&
      id == other.id &&
      displayName == other.displayName &&
      familyName == other.familyName &&
      fontUrl == other.fontUrl &&
      previewImageUrl == other.previewImageUrl &&
      version == other.version &&
      license == other.license &&
      fileSizeBytes == other.fileSizeBytes &&
      sha256 == other.sha256 &&
      listEquals(weights, other.weights);

  @override
  int get hashCode => Object.hash(
    id,
    displayName,
    familyName,
    fontUrl,
    previewImageUrl,
    version,
    license,
    fileSizeBytes,
    sha256,
    Object.hashAll(weights),
  );
}

/// Available text navigation modes.
enum ReaderNavigationMode {
  /// Discrete, horizontally navigated pages.
  horizontalPages,

  /// A vertically scrolling paragraph list.
  verticalScroll,
}

/// Animation used for horizontal page navigation.
enum ReaderPageAnimation {
  /// A standard horizontal slide transition.
  slide,

  /// No transition animation.
  none,

  /// A reader-owned simulated page-curl transition.
  pageCurl,

  /// A page-cover transition where the incoming page overlays the current one.
  cover,
}

/// Sort orders supported by a read-only comment feed.
enum ReaderCommentSort {
  /// Host-defined popularity order.
  hot,

  /// Most recently created comments first.
  newest,
}

/// Platform lifecycle states normalized for reader hosts.
enum ReaderLifecycleState {
  /// The application is visible and interactive.
  foreground,

  /// The application is temporarily inactive but may still be visible.
  inactive,

  /// The application is hidden or paused in the background.
  background,

  /// The Flutter view or engine has detached.
  detached,
}

/// Stable failure categories exposed to reader hosts.
enum ReaderFailureKind {
  /// Book, catalog, chapter, or extension data could not be loaded or validated.
  data,

  /// One independently recoverable comic image could not be loaded or decoded.
  ///
  /// The reader remains usable and keeps the image's fixed placeholder extent
  /// so the user can retry or continue to another image.
  image,

  /// Host-owned reader state could not be read or written.
  persistence,

  /// Text measurement or page layout failed.
  layout,

  /// A native or operating-system capability failed.
  platform,

  /// An error did not match a more specific category.
  unknown,
}

@immutable
/// Reader-owned presentation settings persisted unchanged by the host.
class TextReaderPreferences {
  /// Creates reader-owned presentation preferences.
  const TextReaderPreferences({
    this.theme = ReaderThemePreset.day,
    this.lastNonNightTheme = ReaderThemePreset.day,
    this.background = ReaderBackgroundPreset.plain,
    this.font = ReaderFontPreset.system,
    this.customFontId,
    this.fontSize = 19,
    this.fontWeight = 400,
    this.letterSpacing = .2,
    this.lineHeight = 1.8,
    this.paragraphSpacing = 14,
    this.firstLineIndent = 2,
    this.horizontalPadding = 24,
    this.topPadding = 8,
    this.bottomPadding = 32,
    this.brightness = 1,
    this.navigationMode = ReaderNavigationMode.horizontalPages,
    this.singleHandMode = false,
    this.keepScreenOn = true,
    this.pageAnimation = ReaderPageAnimation.slide,
    this.immersiveMode = false,
    this.showBookComments = true,
    this.showChapterComments = true,
    this.showParagraphComments = true,
  });

  /// Default preferences used when the host has no saved value.
  static const defaults = TextReaderPreferences();

  /// Built-in reading color scheme.
  final ReaderThemePreset theme;

  /// The last non-night color scheme, restored when night mode is closed.
  ///
  /// This is a global reader preference rather than a book-scoped value.
  /// Night presets are invalid here and normalize to [ReaderThemePreset.day].
  final ReaderThemePreset lastNonNightTheme;

  /// Built-in background treatment applied behind the reading surface.
  final ReaderBackgroundPreset background;

  /// Bundled or platform font family selection.
  final ReaderFontPreset font;

  /// Stable host font identifier selected from [ReaderFontRepository].
  ///
  /// Null selects the built-in [font]. Empty or whitespace-only values are
  /// normalized to null.
  final String? customFontId;

  /// Body font size in logical pixels; normalized to supported presets.
  final double fontSize;

  /// Body text weight. Values are normalized to 400, 500, or 600.
  final int fontWeight;

  /// Body text letter spacing in logical pixels.
  final double letterSpacing;

  /// Body line-height multiplier, normalized to supported presets.
  final double lineHeight;

  /// Space after a paragraph in logical pixels.
  final double paragraphSpacing;

  /// Number of full-width ideographic spaces used for a paragraph's first line.
  final int firstLineIndent;

  /// Horizontal page padding in logical pixels.
  final double horizontalPadding;

  /// Space between the top safe area and the first line of page content.
  ///
  /// Defaults to 8 logical pixels and is also used as the top inset for
  /// vertical scrolling. Explicit or persisted larger values remain valid.
  final double topPadding;

  /// Space between the last line of page content and the bottom safe area.
  ///
  /// The horizontal page footer is an overlay rather than part of the text
  /// layout. A smaller value may therefore intentionally allow text to pass
  /// beneath the footer.
  final double bottomPadding;

  /// Reader overlay brightness from 0.25 to 1.0.
  final double brightness;

  /// Horizontal pagination or vertical scrolling.
  final ReaderNavigationMode navigationMode;

  /// Whether both left and right taps advance to the next page.
  ///
  /// This affects horizontal reading tap zones only. Swipe direction and
  /// vertical scrolling retain their normal behavior.
  final bool singleHandMode;

  /// Requests display-awake while an active reader is in the foreground.
  final bool keepScreenOn;

  /// Horizontal page transition preference.
  final ReaderPageAnimation pageAnimation;

  /// Whether supported platforms should hide system bars while reading.
  ///
  /// Defaults to false and is ignored on platforms without immersive support.
  final bool immersiveMode;

  /// Whether the reader may show the book-level comment entry.
  ///
  /// This has no effect when no comment feed is registered.
  final bool showBookComments;

  /// Whether the reader may show the current chapter's comment entry.
  ///
  /// This has no effect when no comment feed is registered.
  final bool showChapterComments;

  /// Whether the reader may show paragraph-level comment entries.
  ///
  /// This has no effect when no comment feed is registered.
  final bool showParagraphComments;

  /// Returns a copy constrained to the reader's supported numeric presets.
  ///
  /// Non-finite persisted values fall back to the matching default instead of
  /// participating in nearest-preset comparisons.
  TextReaderPreferences normalized() {
    const TextReaderPreferences fallback = TextReaderPreferences.defaults;
    return copyWith(
      lastNonNightTheme: _isNightThemePreset(theme)
          ? (_isNightThemePreset(lastNonNightTheme)
                ? fallback.lastNonNightTheme
                : lastNonNightTheme)
          : theme,
      customFontId: customFontId?.trim(),
      clearCustomFontId: customFontId?.trim().isEmpty ?? false,
      fontSize: _nearest(fontSize, const <double>[
        16,
        19,
        22,
        26,
        32,
      ], fallback: fallback.fontSize),
      fontWeight: _nearest(fontWeight.toDouble(), const <double>[
        400,
        500,
        600,
      ], fallback: fallback.fontWeight.toDouble()).round(),
      letterSpacing: _nearest(letterSpacing, const <double>[
        0,
        .2,
        .8,
      ], fallback: fallback.letterSpacing),
      lineHeight: _nearest(lineHeight, const <double>[
        1.5,
        1.8,
        2.1,
      ], fallback: fallback.lineHeight),
      paragraphSpacing: _nearest(paragraphSpacing, const <double>[
        8,
        14,
        22,
      ], fallback: fallback.paragraphSpacing),
      firstLineIndent: _nearest(firstLineIndent.toDouble(), const <double>[
        0,
        1,
        2,
      ], fallback: fallback.firstLineIndent.toDouble()).round(),
      horizontalPadding: _nearest(horizontalPadding, const <double>[
        16,
        24,
        40,
      ], fallback: fallback.horizontalPadding),
      topPadding: _nearest(topPadding, const <double>[
        8,
        24,
        40,
        64,
      ], fallback: fallback.topPadding),
      bottomPadding: _nearest(bottomPadding, const <double>[
        8,
        24,
        40,
        64,
      ], fallback: fallback.bottomPadding),
      brightness: brightness.isFinite
          ? brightness.clamp(0.25, 1).toDouble()
          : fallback.brightness,
    );
  }

  static double _nearest(
    double value,
    List<double> choices, {
    required double fallback,
  }) {
    final double finiteValue = value.isFinite ? value : fallback;
    return choices.reduce(
      (double best, double candidate) =>
          (candidate - finiteValue).abs() < (best - finiteValue).abs()
          ? candidate
          : best,
    );
  }

  /// Returns a copy with the supplied fields replaced.
  TextReaderPreferences copyWith({
    ReaderThemePreset? theme,
    ReaderThemePreset? lastNonNightTheme,
    ReaderBackgroundPreset? background,
    ReaderFontPreset? font,
    String? customFontId,
    bool clearCustomFontId = false,
    double? fontSize,
    int? fontWeight,
    double? letterSpacing,
    double? lineHeight,
    double? paragraphSpacing,
    int? firstLineIndent,
    double? horizontalPadding,
    double? topPadding,
    double? bottomPadding,
    double? brightness,
    ReaderNavigationMode? navigationMode,
    bool? singleHandMode,
    bool? keepScreenOn,
    ReaderPageAnimation? pageAnimation,
    bool? immersiveMode,
    bool? showBookComments,
    bool? showChapterComments,
    bool? showParagraphComments,
  }) {
    return TextReaderPreferences(
      theme: theme ?? this.theme,
      lastNonNightTheme: lastNonNightTheme ?? this.lastNonNightTheme,
      background: background ?? this.background,
      font: font ?? this.font,
      customFontId: clearCustomFontId
          ? null
          : customFontId ?? this.customFontId,
      fontSize: fontSize ?? this.fontSize,
      fontWeight: fontWeight ?? this.fontWeight,
      letterSpacing: letterSpacing ?? this.letterSpacing,
      lineHeight: lineHeight ?? this.lineHeight,
      paragraphSpacing: paragraphSpacing ?? this.paragraphSpacing,
      firstLineIndent: firstLineIndent ?? this.firstLineIndent,
      horizontalPadding: horizontalPadding ?? this.horizontalPadding,
      topPadding: topPadding ?? this.topPadding,
      bottomPadding: bottomPadding ?? this.bottomPadding,
      brightness: brightness ?? this.brightness,
      navigationMode: navigationMode ?? this.navigationMode,
      singleHandMode: singleHandMode ?? this.singleHandMode,
      keepScreenOn: keepScreenOn ?? this.keepScreenOn,
      pageAnimation: pageAnimation ?? this.pageAnimation,
      immersiveMode: immersiveMode ?? this.immersiveMode,
      showBookComments: showBookComments ?? this.showBookComments,
      showChapterComments: showChapterComments ?? this.showChapterComments,
      showParagraphComments:
          showParagraphComments ?? this.showParagraphComments,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TextReaderPreferences &&
      theme == other.theme &&
      lastNonNightTheme == other.lastNonNightTheme &&
      background == other.background &&
      font == other.font &&
      customFontId == other.customFontId &&
      fontSize == other.fontSize &&
      fontWeight == other.fontWeight &&
      letterSpacing == other.letterSpacing &&
      lineHeight == other.lineHeight &&
      paragraphSpacing == other.paragraphSpacing &&
      firstLineIndent == other.firstLineIndent &&
      horizontalPadding == other.horizontalPadding &&
      topPadding == other.topPadding &&
      bottomPadding == other.bottomPadding &&
      brightness == other.brightness &&
      navigationMode == other.navigationMode &&
      singleHandMode == other.singleHandMode &&
      keepScreenOn == other.keepScreenOn &&
      pageAnimation == other.pageAnimation &&
      immersiveMode == other.immersiveMode &&
      showBookComments == other.showBookComments &&
      showChapterComments == other.showChapterComments &&
      showParagraphComments == other.showParagraphComments;

  @override
  int get hashCode => Object.hashAll(<Object?>[
    theme,
    lastNonNightTheme,
    background,
    font,
    customFontId,
    fontSize,
    fontWeight,
    letterSpacing,
    lineHeight,
    paragraphSpacing,
    firstLineIndent,
    horizontalPadding,
    topPadding,
    bottomPadding,
    brightness,
    navigationMode,
    singleHandMode,
    keepScreenOn,
    pageAnimation,
    immersiveMode,
    showBookComments,
    showChapterComments,
    showParagraphComments,
  ]);
}

bool _isNightThemePreset(ReaderThemePreset theme) =>
    theme == ReaderThemePreset.night ||
    theme == ReaderThemePreset.deepNight ||
    theme == ReaderThemePreset.charcoal;

@immutable
/// A recoverable reader error suitable for host diagnostics.
class ReaderFailure implements Exception {
  /// Creates a recoverable failure with optional diagnostics and cause.
  const ReaderFailure(
    this.kind,
    this.message, {
    this.code,
    this.location,
    this.cause,
  });

  /// Stable category suitable for host diagnostics and filtering.
  final ReaderFailureKind kind;

  /// Concise message suitable for diagnostics or actionable reader UI.
  final String message;

  /// Stable diagnostic identifier.
  final String? code;

  /// Safe operation where the failure happened.
  ///
  /// This is a host-facing diagnostic location and message.
  final String? location;

  /// Optional original error retained for diagnostics.
  final Object? cause;

  @override
  String toString() => 'ReaderFailure($kind, $message, $code, $location)';
}
