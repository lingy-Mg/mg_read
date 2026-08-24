/// Immutable, host-owned projection used by the library page.
///
/// The feature receives a local display projection; cover bytes are loaded by
/// the data adapter from the app-owned cover object store.
final class LibraryItemSummary {
  /// Creates one stable library-item projection.
  const LibraryItemSummary({
    required this.id,
    required this.title,
    this.author,
    this.coverUrl,
    this.coverBytes,
    this.sourceName,
    this.readingProgress,
    this.readingChapterIndex,
    this.lastReadAtUtc,
  }) : assert(id != ''),
       assert(title != ''),
       assert(
         readingProgress == null ||
             (readingProgress >= 0 && readingProgress <= 1),
       );

  /// Stable identifier generated and owned by the host application.
  final String id;

  /// User-visible title from the current local projection.
  final String title;
  final String? author;
  final Uri? coverUrl;

  /// Cover bytes loaded from the app-owned file object, when available.
  final List<int>? coverBytes;
  final String? sourceName;

  /// Displayable full-book fraction last reported by the reader.
  final double? readingProgress;

  /// Zero-based chapter order of the saved semantic position.
  final int? readingChapterIndex;

  /// Time of the durable semantic position, in UTC.
  final DateTime? lastReadAtUtc;
}
