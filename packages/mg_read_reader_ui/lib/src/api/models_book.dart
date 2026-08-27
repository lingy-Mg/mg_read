/// 书籍、章节与正文公共模型。
///
/// 只定义宿主提供的不可变书籍内容，不访问 IO 或持久化。
part of 'models.dart';

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
    this.sourceUrl,
    this.coverUrl,
    this.wordCount,
    this.chapterCount,
    this.statusLabel,
    this.latestChapterTitle,
    this.latestChapterUrl,
    this.labels = const <String>[],
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

  /// HTTP or HTTPS URL for the book at its source, when the host knows it.
  ///
  /// The reader only displays and opens this URL after an explicit user tap.
  final Uri? sourceUrl;

  /// Optional source-provided cover reference used by the host-facing detail
  /// presentation. The reader may fall back to its neutral cover placeholder.
  final Uri? coverUrl;

  /// Optional book word count for the detail statistics row.
  final int? wordCount;

  /// Optional total chapter count for the detail statistics row.
  final int? chapterCount;

  /// Optional host-formatted status label, such as “连载” or “已完结”.
  final String? statusLabel;

  /// Optional latest-chapter title shown in the detail presentation.
  final String? latestChapterTitle;

  /// Optional URL for [latestChapterTitle].
  final Uri? latestChapterUrl;

  /// Categories and tags displayed as compact detail labels.
  ///
  /// Hosts should pass an immutable list. The reader never mutates it.
  final List<String> labels;

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
