import 'package:mg_read/features/library/domain/library_item_summary.dart';

/// Immutable view projection for the local library landing page.
final class LibraryOverview {
  /// Creates an overview while defensively freezing its item list.
  LibraryOverview({required Iterable<LibraryItemSummary> items}) : items = List<LibraryItemSummary>.unmodifiable(items);

  /// Creates an empty local overview.
  const LibraryOverview.empty() : items = const <LibraryItemSummary>[];

  /// Current locally available items.
  final List<LibraryItemSummary> items;

  /// Whether this successful result has no items.
  bool get isEmpty => items.isEmpty;

  /// Most recently saved reading position among the available shelf items.
  LibraryItemSummary? get continueReading {
    LibraryItemSummary? latest;
    for (final item in items) {
      if (item.lastReadAtUtc == null) continue;
      if (latest == null || item.lastReadAtUtc!.isAfter(latest.lastReadAtUtc!)) {
        latest = item;
      }
    }
    return latest;
  }
}
