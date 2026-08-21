/// Immutable, host-owned projection used by the library page.
///
/// M2.1 only uses this for state and test fixtures. It does not fetch, persist,
/// or resolve any real source content.
final class LibraryItemSummary {
  /// Creates one stable library-item projection.
  const LibraryItemSummary({
    required this.id,
    required this.title,
    this.readingProgress,
    this.readingChapterIndex,
    this.lastReadAtUtc,
  })
    : assert(id != ''),
      assert(title != ''),
      assert(readingProgress == null ||
          (readingProgress >= 0 && readingProgress <= 1));

  /// Stable identifier generated and owned by the host application.
  final String id;

  /// User-visible title from the current local projection.
  final String title;

  /// Displayable full-book fraction last reported by the reader.
  final double? readingProgress;

  /// Zero-based chapter order of the saved semantic position.
  final int? readingChapterIndex;

  /// Time of the durable semantic position, in UTC.
  final DateTime? lastReadAtUtc;
}
