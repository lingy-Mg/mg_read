import 'package:flutter/foundation.dart';

/// Where a host obtains a book's content.
enum ReaderBookSourceKind {
  /// Content is owned locally by the host and does not require a remote fetch.
  local,

  /// Content may require a host-managed remote download or cache lookup.
  remote,

  /// The host has not classified the source.
  unknown,
}

/// Host-reported availability of one reader chapter.
enum ReaderChapterAvailability {
  /// The complete chapter is available in the host cache.
  downloaded,

  /// The chapter is known but is not currently cached.
  notDownloaded,

  /// The host is currently downloading or preparing the chapter.
  downloading,

  /// The most recent host download or preparation attempt failed.
  failed,

  /// The host does not expose availability for this chapter.
  unknown,
}

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
/// Lightweight metadata displayed by the reading surface.
class ReaderBookInfo {
  /// Creates lightweight metadata for one book.
  const ReaderBookInfo({
    required this.id,
    required this.title,
    this.author,
    this.description,
    this.sourceName,
    this.sourceKind = ReaderBookSourceKind.unknown,
  });

  /// Stable identifier supplied by the host.
  final String id;

  /// Display title of the book.
  final String title;

  /// Optional book author.
  final String? author;

  /// Optional book description.
  final String? description;

  /// Display name of the host-managed book source.
  ///
  /// When supplied, it is shown below the reader title bar. The reader never
  /// uses this value to fetch content or select a source.
  final String? sourceName;

  /// Host classification of the book's source.
  ///
  /// The reader never uses this value to perform network or file access.
  final ReaderBookSourceKind sourceKind;
}

@immutable
/// One stable entry in a book's ordered chapter catalog.
class ReaderChapterInfo {
  /// Creates an entry in the book's stable chapter order.
  const ReaderChapterInfo({
    required this.id,
    required this.title,
    required this.index,
    this.availability = ReaderChapterAvailability.unknown,
    this.wordCount,
    this.hasBeenRead = false,
  });

  /// Stable chapter identifier supplied by the host.
  final String id;

  /// Chapter title displayed by the reader.
  final String title;

  /// Zero-based position in the full book catalog.
  final int index;

  /// Current host-reported cache or download state.
  final ReaderChapterAvailability availability;

  /// Optional host-estimated word or character count for display.
  final int? wordCount;

  /// Whether the host considers this chapter read.
  final bool hasBeenRead;
}

@immutable
/// Refreshable host state for one text chapter.
class ReaderChapterState {
  /// Creates an immutable chapter-state response.
  const ReaderChapterState({
    required this.chapterId,
    this.availability = ReaderChapterAvailability.unknown,
    this.wordCount,
    this.hasBeenRead = false,
  });

  /// Stable chapter identifier matching a catalog entry.
  final String chapterId;

  /// Current host-reported cache or download state.
  final ReaderChapterAvailability availability;

  /// Optional host-estimated word or character count.
  final int? wordCount;

  /// Whether the host considers the chapter read.
  final bool hasBeenRead;

  @override
  bool operator ==(Object other) =>
      other is ReaderChapterState &&
      chapterId == other.chapterId &&
      availability == other.availability &&
      wordCount == other.wordCount &&
      hasBeenRead == other.hasBeenRead;

  @override
  int get hashCode =>
      Object.hash(chapterId, availability, wordCount, hasBeenRead);
}

@immutable
/// A cursor-based page of chapter metadata.
class ChapterCatalogPage {
  /// Creates one cursor-based catalog response.
  ///
  /// The reader validates catalog consistency when it consumes this response,
  /// and reports invalid host data as a recoverable data failure.
  ChapterCatalogPage({
    required List<ReaderChapterInfo> items,
    required this.total,
    required this.hasMore,
    this.nextCursor,
  }) : items = List<ReaderChapterInfo>.unmodifiable(items);

  /// Immutable chapter entries in full-book order.
  final List<ReaderChapterInfo> items;

  /// Opaque cursor for the next page, or null when no cursor is available.
  final String? nextCursor;

  /// Total number of chapters in the full catalog.
  final int total;

  /// Whether the host can return another catalog page.
  final bool hasMore;
}

@immutable
/// A stable plain-text paragraph used as a semantic position anchor.
class TextParagraph {
  /// Creates one stable plain-text paragraph.
  const TextParagraph({required this.id, required this.text});

  /// Stable paragraph identifier within its chapter.
  final String id;

  /// Plain text measured and displayed by the reader.
  final String text;
}

@immutable
/// One fully loaded plain-text chapter.
class TextChapterContent {
  /// Creates a fully loaded plain-text chapter.
  ///
  /// The reader validates chapter and paragraph identifiers when it consumes
  /// this value, and reports invalid host data as a recoverable data failure.
  TextChapterContent({
    required this.chapterId,
    required this.title,
    required List<TextParagraph> paragraphs,
    this.contentVersion,
    this.chapterUrl,
  }) : paragraphs = List<TextParagraph>.unmodifiable(paragraphs);

  /// Stable chapter identifier supplied by the host.
  final String chapterId;

  /// Display title of the chapter.
  final String title;

  /// Ordered, stable paragraph content for this chapter.
  final List<TextParagraph> paragraphs;

  /// Optional host content version used for in-memory pagination caching.
  final String? contentVersion;

  /// HTTP or HTTPS URL for this exact chapter at its source.
  ///
  /// If it is valid, the reading surface displays it below the title bar and
  /// opens it in the external browser only after an explicit user tap.
  final String? chapterUrl;
}

@immutable
/// A layout-independent reading position persisted by the host.
class ReaderProgress {
  /// Creates a semantic reading position independent of page or pixel layout.
  const ReaderProgress({
    required this.chapterId,
    required this.paragraphId,
    this.characterOffset = 0,
    this.chapterIndex = 0,
    this.chapterFraction = 0,
    this.bookFraction = 0,
  });

  /// Creates the book information preview position before chapter zero.
  const ReaderProgress.bookPreview()
    : chapterId = '',
      paragraphId = '',
      characterOffset = 0,
      chapterIndex = -1,
      chapterFraction = 0,
      bookFraction = 0;

  /// Stable chapter identifier, or an empty string for the book preview.
  final String chapterId;

  /// Stable paragraph identifier, or an empty string for the book preview.
  final String paragraphId;

  /// UTF-16 character offset within [paragraphId].
  final int characterOffset;

  /// Zero-based chapter order, or `-1` for the book preview.
  final int chapterIndex;

  /// Displayable progress through the current chapter from 0 to 1.
  final double chapterFraction;

  /// Displayable progress through the full book from 0 to 1.
  final double bookFraction;

  /// Whether this position represents the metadata page before chapter zero.
  bool get isBookPreview => chapterIndex < 0;

  /// Returns a copy with the supplied fields replaced.
  ReaderProgress copyWith({
    String? chapterId,
    String? paragraphId,
    int? characterOffset,
    int? chapterIndex,
    double? chapterFraction,
    double? bookFraction,
  }) {
    return ReaderProgress(
      chapterId: chapterId ?? this.chapterId,
      paragraphId: paragraphId ?? this.paragraphId,
      characterOffset: characterOffset ?? this.characterOffset,
      chapterIndex: chapterIndex ?? this.chapterIndex,
      chapterFraction: chapterFraction ?? this.chapterFraction,
      bookFraction: bookFraction ?? this.bookFraction,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ReaderProgress &&
      chapterId == other.chapterId &&
      paragraphId == other.paragraphId &&
      characterOffset == other.characterOffset &&
      chapterIndex == other.chapterIndex &&
      chapterFraction == other.chapterFraction &&
      bookFraction == other.bookFraction;

  @override
  int get hashCode => Object.hash(
    chapterId,
    paragraphId,
    characterOffset,
    chapterIndex,
    chapterFraction,
    bookFraction,
  );
}

@immutable
/// A host-persisted bookmark anchored to chapter and paragraph identities.
class ReaderBookmark {
  /// Creates a bookmark anchored to a semantic reading position.
  const ReaderBookmark({
    required this.id,
    required this.bookId,
    required this.chapterId,
    required this.paragraphId,
    required this.characterOffset,
    required this.chapterTitle,
    required this.excerpt,
    required this.createdAt,
  });

  /// Stable bookmark identifier generated by the reader.
  final String id;

  /// Stable identifier of the bookmarked book.
  final String bookId;

  /// Stable identifier of the bookmarked chapter.
  final String chapterId;

  /// Stable identifier of the bookmarked paragraph.
  final String paragraphId;

  /// UTF-16 character offset within [paragraphId].
  final int characterOffset;

  /// Chapter title captured for display.
  final String chapterTitle;

  /// Short plain-text excerpt captured for display.
  final String excerpt;

  /// Time at which the reader created the bookmark.
  final DateTime createdAt;
}

@immutable
/// Reader-owned presentation settings persisted unchanged by the host.
class TextReaderPreferences {
  /// Creates reader-owned presentation preferences.
  const TextReaderPreferences({
    this.theme = ReaderThemePreset.day,
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
    this.topPadding = 24,
    this.bottomPadding = 32,
    this.brightness = 1,
    this.navigationMode = ReaderNavigationMode.horizontalPages,
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
  /// This is also used as the top inset for vertical scrolling.
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
    bool? keepScreenOn,
    ReaderPageAnimation? pageAnimation,
    bool? immersiveMode,
    bool? showBookComments,
    bool? showChapterComments,
    bool? showParagraphComments,
  }) {
    return TextReaderPreferences(
      theme: theme ?? this.theme,
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
      keepScreenOn == other.keepScreenOn &&
      pageAnimation == other.pageAnimation &&
      immersiveMode == other.immersiveMode &&
      showBookComments == other.showBookComments &&
      showChapterComments == other.showChapterComments &&
      showParagraphComments == other.showParagraphComments;

  @override
  int get hashCode => Object.hashAll(<Object?>[
    theme,
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
    keepScreenOn,
    pageAnimation,
    immersiveMode,
    showBookComments,
    showChapterComments,
    showParagraphComments,
  ]);
}

@immutable
/// A recoverable reader error suitable for host diagnostics.
class ReaderFailure implements Exception {
  /// Creates a recoverable failure with an optional original [cause].
  const ReaderFailure(this.kind, this.message, {this.cause});

  /// Stable category suitable for host diagnostics and filtering.
  final ReaderFailureKind kind;

  /// Concise message suitable for diagnostics or actionable reader UI.
  final String message;

  /// Optional original error retained for diagnostics.
  final Object? cause;

  @override
  String toString() => 'ReaderFailure($kind, $message)';
}

@immutable
/// Stable target for book, chapter, paragraph, or comic-image comments.
class ReaderCommentTarget {
  /// Creates a target for comments about the whole book.
  ///
  /// Hosts must supply a non-empty, non-whitespace identifier; the reader
  /// validates feed targets before invoking a feed in Release builds.
  const ReaderCommentTarget.book(this.bookId)
    : chapterId = null,
      paragraphId = null,
      imageId = null;

  /// Creates a target for comments about one chapter.
  ///
  /// Hosts must supply non-empty, non-whitespace identifiers. The nullable
  /// parameter is retained for source compatibility; invalid targets are
  /// rejected before the reader invokes a feed in Release builds.
  const ReaderCommentTarget.chapter(this.bookId, this.chapterId)
    : paragraphId = null,
      imageId = null;

  /// Creates a target for comments about one stable paragraph.
  ///
  /// Hosts must supply non-empty, non-whitespace identifiers. Nullable
  /// parameters are retained for source compatibility; invalid targets are
  /// rejected before the reader invokes a feed in Release builds.
  const ReaderCommentTarget.paragraph(
    this.bookId,
    this.chapterId,
    this.paragraphId,
  ) : imageId = null;

  /// Creates a target for one stable comic image.
  ///
  /// Hosts must supply non-empty, non-whitespace identifiers. Nullable
  /// parameters are retained for source compatibility; invalid targets are
  /// rejected before the reader invokes a feed in Release builds.
  const ReaderCommentTarget.comicImage(
    this.bookId,
    this.chapterId,
    this.imageId,
  ) : paragraphId = null;

  /// Stable identifier of the target book.
  final String bookId;

  /// Stable chapter identifier, or null for a book-level target.
  final String? chapterId;

  /// Stable paragraph identifier, or null for a broader target.
  final String? paragraphId;

  /// Stable comic image identifier, or null for text and broader targets.
  final String? imageId;

  @override
  bool operator ==(Object other) =>
      other is ReaderCommentTarget &&
      bookId == other.bookId &&
      chapterId == other.chapterId &&
      paragraphId == other.paragraphId &&
      imageId == other.imageId;

  @override
  int get hashCode => Object.hash(bookId, chapterId, paragraphId, imageId);
}

@immutable
/// One immutable, read-only comment supplied by a host comment feed.
class ReaderComment {
  /// Creates a comment suitable for direct display by the reader.
  ///
  /// Identifiers, author names, and content must contain visible text, and
  /// [likeCount] must be non-negative.
  factory ReaderComment({
    required String id,
    required ReaderCommentTarget target,
    required String authorName,
    required String content,
    required DateTime createdAt,
    required int likeCount,
  }) {
    if (likeCount < 0) {
      throw RangeError.value(likeCount, 'likeCount', 'Must not be negative.');
    }
    return ReaderComment._(
      id: _requireIdentifier(id, 'id'),
      target: target,
      authorName: _requireDisplayText(authorName, 'authorName'),
      content: _requireDisplayText(content, 'content'),
      createdAt: createdAt,
      likeCount: likeCount,
    );
  }

  const ReaderComment._({
    required this.id,
    required this.target,
    required this.authorName,
    required this.content,
    required this.createdAt,
    required this.likeCount,
  });

  /// Stable comment identifier supplied by the host.
  final String id;

  /// Book, chapter, paragraph, or comic-image target for this comment.
  final ReaderCommentTarget target;

  /// Display name for the comment author.
  final String authorName;

  /// Plain-text, read-only comment body.
  final String content;

  /// Host-supplied creation time.
  final DateTime createdAt;

  /// Non-negative, read-only number of likes reported by the host.
  final int likeCount;
}

@immutable
/// A compact comment summary used to decorate reader entry points.
class ReaderCommentSummary {
  /// Creates a summary for [target].
  ///
  /// [total] must be non-negative. Preview entries must match [target] and
  /// cannot outnumber [total].
  factory ReaderCommentSummary({
    required ReaderCommentTarget target,
    required int total,
    required List<ReaderComment> topComments,
  }) {
    if (total < 0) {
      throw RangeError.value(total, 'total', 'Must not be negative.');
    }
    if (topComments.length > total) {
      throw ArgumentError.value(
        topComments.length,
        'topComments',
        'Cannot contain more entries than total.',
      );
    }
    if (topComments.any((ReaderComment comment) => comment.target != target)) {
      throw ArgumentError.value(
        topComments,
        'topComments',
        'Every preview comment must match the summary target.',
      );
    }
    return ReaderCommentSummary._(
      target: target,
      total: total,
      topComments: List.unmodifiable(topComments),
    );
  }

  const ReaderCommentSummary._({
    required this.target,
    required this.total,
    required this.topComments,
  });

  /// Target represented by this summary.
  final ReaderCommentTarget target;

  /// Non-negative total number of comments available for [target].
  final int total;

  /// Host-selected preview comments, in display order.
  ///
  /// Every entry has the same [ReaderComment.target] as [target], and the list
  /// cannot contain more entries than [total].
  ///
  /// The feed decides how many items to return, subject to the caller's
  /// requested preview limit.
  final List<ReaderComment> topComments;
}

@immutable
/// One cursor-based page of read-only comments.
class ReaderCommentPage {
  /// Creates a page returned by a comment feed.
  ///
  /// [total] must be non-negative and at least the number of [items]. Comment
  /// identifiers must be unique within the page. [nextCursor] is required and
  /// non-empty exactly when [hasMore] is true.
  factory ReaderCommentPage({
    required List<ReaderComment> items,
    required int total,
    required bool hasMore,
    String? nextCursor,
  }) {
    if (total < 0) {
      throw RangeError.value(total, 'total', 'Must not be negative.');
    }
    if (items.length > total) {
      throw ArgumentError.value(
        items.length,
        'items',
        'Cannot contain more entries than total.',
      );
    }
    final String? normalizedCursor = nextCursor?.trim();
    if (hasMore && (normalizedCursor == null || normalizedCursor.isEmpty)) {
      throw ArgumentError.value(
        nextCursor,
        'nextCursor',
        'A non-empty advancing cursor is required when hasMore is true.',
      );
    }
    if (hasMore && items.isEmpty) {
      throw ArgumentError.value(
        items,
        'items',
        'A page with more data must make item progress.',
      );
    }
    if (!hasMore && nextCursor != null) {
      throw ArgumentError.value(
        nextCursor,
        'nextCursor',
        'Must be null when hasMore is false.',
      );
    }
    final Set<String> ids = <String>{};
    if (items.any((ReaderComment comment) => !ids.add(comment.id))) {
      throw ArgumentError.value(
        items,
        'items',
        'Comment identifiers must be unique within a page.',
      );
    }
    return ReaderCommentPage._(
      items: List.unmodifiable(items),
      nextCursor: nextCursor,
      total: total,
      hasMore: hasMore,
    );
  }

  const ReaderCommentPage._({
    required this.items,
    required this.nextCursor,
    required this.total,
    required this.hasMore,
  });

  /// Comments in the requested host-defined order.
  final List<ReaderComment> items;

  /// Cursor to pass to the next request, or null when none is available.
  ///
  /// This is non-empty when [hasMore] is true and null when it is false.
  final String? nextCursor;

  /// Non-negative total number of comments available for the requested target.
  final int total;

  /// Whether another page can be requested with [nextCursor].
  final bool hasMore;
}

String _requireIdentifier(String value, String name) {
  if (value.trim().isEmpty) {
    throw ArgumentError.value(value, name, 'Must not be empty.');
  }
  return value;
}

String _requireDisplayText(String value, String name) {
  if (value.trim().isEmpty) {
    throw ArgumentError.value(value, name, 'Must contain visible text.');
  }
  return value;
}

@immutable
/// Read-only state published by [TextReaderController].
class TextReaderSnapshot {
  /// Creates a controller snapshot.
  const TextReaderSnapshot({
    required this.isReady,
    required this.isLoading,
    required this.controlsVisible,
    this.isAutoReading = false,
    this.book,
    this.chapter,
    this.progress,
    this.failure,
  });

  /// Creates the loading snapshot used before a reader publishes state.
  const TextReaderSnapshot.initial()
    : isReady = false,
      isLoading = true,
      controlsVisible = false,
      isAutoReading = false,
      book = null,
      chapter = null,
      progress = null,
      failure = null;

  /// Whether the reader has usable content or a usable book preview.
  final bool isReady;

  /// Whether initialization or a reader command is currently loading.
  final bool isLoading;

  /// Whether the reader's toolbar chrome is visible.
  final bool controlsVisible;

  /// Whether session-scoped automatic reading is currently active.
  final bool isAutoReading;

  /// Currently loaded book metadata, when available.
  final ReaderBookInfo? book;

  /// Currently opened chapter metadata, when reading chapter content.
  final ReaderChapterInfo? chapter;

  /// Latest semantic reading position, when available.
  final ReaderProgress? progress;

  /// Latest recoverable reader failure, when present.
  final ReaderFailure? failure;
}
