/// Immutable, host-owned projection used by the library page.
///
/// M2.1 only uses this for state and test fixtures. It does not fetch, persist,
/// or resolve any real source content.
final class LibraryItemSummary {
  /// Creates one stable library-item projection.
  const LibraryItemSummary({required this.id, required this.title})
    : assert(id != ''),
      assert(title != '');

  /// Stable identifier generated and owned by the host application.
  final String id;

  /// User-visible title from the current local projection.
  final String title;
}
