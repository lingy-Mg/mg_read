import 'package:flutter/foundation.dart';

/// Immutable, display-ready data shared by update, shelf, and history lists.
///
/// This model deliberately contains only presentation data. Feature adapters
/// remain responsible for mapping Runtime-facing book, update, or history
/// records into this compact visual contract.
@immutable
final class LibraryBookListItemViewData {
  /// Creates one display-ready book-list row.
  LibraryBookListItemViewData({
    required this.id,
    required this.title,
    required this.coverVariant,
    required this.status,
    this.subtitle,
    this.activityLabel,
    this.hasAttentionIndicator = false,
    Iterable<LibraryMetadataTagViewData> tags =
        const <LibraryMetadataTagViewData>[],
  }) : assert(id != ''),
       assert(title != ''),
       tags = List<LibraryMetadataTagViewData>.unmodifiable(tags);

  /// Stable host-owned identifier. It is never source content or a URL.
  final String id;

  /// Primary title shown at the top of the row.
  final String title;

  /// Context-specific secondary text, such as the latest or last-read chapter.
  final String? subtitle;

  /// Compact activity text aligned before the row's overflow affordance.
  ///
  /// Update, shelf, and history adapters can respectively map an update time,
  /// a shelf timestamp, or a last-read time here without changing the layout.
  final String? activityLabel;

  final LibraryCoverVariant coverVariant;
  final LibraryBookStatus status;

  /// Whether an enabled presentation should render the small attention dot.
  final bool hasAttentionIndicator;

  final List<LibraryMetadataTagViewData> tags;
}

/// A small source or availability tag attached to a book row.
@immutable
final class LibraryMetadataTagViewData {
  /// Creates one immutable source or availability tag.
  const LibraryMetadataTagViewData({required this.label, required this.tone})
    : assert(label != '');

  final String label;
  final LibraryMetadataTone tone;
}

/// Neutral visual variants for locally drawn cover placeholders.
enum LibraryCoverVariant { dusk, dawn, ocean, indigo, ember }

/// The display category used by library list controls.
enum LibraryBookStatus { ongoing, completed, local }

/// Color treatment for a metadata tag, resolved by the active theme.
enum LibraryMetadataTone { neutral, accent, success }
