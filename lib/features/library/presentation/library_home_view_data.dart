import 'package:flutter/foundation.dart';

import 'package:mg_read/features/library/domain/library_overview.dart';

/// Immutable, presentation-only data for the library home screen.
///
/// This type deliberately does not know about a Runtime Facade implementation,
/// Runtime Store, database, source URLs, or reader state. A later application
/// adapter can map a local overview into this shape without making widgets
/// infrastructure-aware.
@immutable
final class LibraryHomeViewData {
  /// Creates one display-ready home projection.
  LibraryHomeViewData({
    required this.isPresentationFixture,
    required this.continueReading,
    required Iterable<LibraryBookUpdateViewData> books,
    this.availableSourceCount,
  }) : books = List<LibraryBookUpdateViewData>.unmodifiable(books);

  /// Maps the currently narrow local overview contract without inventing
  /// reading progress, chapter metadata, source availability, or timestamps.
  factory LibraryHomeViewData.fromLocalOverview(LibraryOverview overview) {
    return LibraryHomeViewData(
      isPresentationFixture: false,
      continueReading: null,
      books: overview.items.asMap().entries.map(
        (entry) => LibraryBookUpdateViewData(
          id: entry.value.id,
          title: entry.value.title,
          coverVariant: LibraryCoverVariant
              .values[entry.key % LibraryCoverVariant.values.length],
          status: LibraryBookStatus.local,
        ),
      ),
    );
  }

  /// Whether the projection is an explicit UI fixture rather than user data.
  final bool isPresentationFixture;

  /// Current reading information, when a future local projection provides it.
  final LibraryContinueReadingViewData? continueReading;

  /// The display-ready book rows for both update and shelf presentation.
  final List<LibraryBookUpdateViewData> books;

  /// Optional source count; a fixture may provide it, a local projection may
  /// leave it unknown until the source-management feature exists.
  final int? availableSourceCount;
}

/// Immutable data for the prominent continue-reading card.
@immutable
final class LibraryContinueReadingViewData {
  /// Creates one continue-reading presentation model.
  const LibraryContinueReadingViewData({
    required this.bookId,
    required this.title,
    required this.chapter,
    required this.progress,
    required this.lastReadLabel,
    required this.coverVariant,
  }) : assert(bookId != ''),
       assert(title != ''),
       assert(chapter != ''),
       assert(progress >= 0 && progress <= 1),
       assert(lastReadLabel != '');

  final String bookId;
  final String title;
  final String chapter;
  final double progress;
  final String lastReadLabel;
  final LibraryCoverVariant coverVariant;
}

/// Immutable presentation model for one update or shelf row.
@immutable
final class LibraryBookUpdateViewData {
  /// Creates one display-ready book row.
  LibraryBookUpdateViewData({
    required this.id,
    required this.title,
    required this.coverVariant,
    required this.status,
    this.chapter,
    this.updatedLabel,
    this.hasUnreadUpdate = false,
    Iterable<LibraryMetadataTagViewData> tags =
        const <LibraryMetadataTagViewData>[],
  }) : assert(id != ''),
       assert(title != ''),
       tags = List<LibraryMetadataTagViewData>.unmodifiable(tags);

  final String id;
  final String title;
  final String? chapter;
  final String? updatedLabel;
  final LibraryCoverVariant coverVariant;
  final LibraryBookStatus status;
  final bool hasUnreadUpdate;
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

/// The display category used by the local filter controls.
enum LibraryBookStatus { ongoing, completed, local }

/// The currently active non-persistent update-list filter.
enum LibraryStatusFilter { all, ongoing, completed, local }

/// Color treatment for a metadata tag, resolved by the active theme.
enum LibraryMetadataTone { neutral, accent, success }

/// The two content sections available at the library landing page.
enum LibraryHomeSection { recentUpdates, shelf }

/// The local presentation selection for the bottom navigation bar.
enum LibraryNavigationDestination { home, search, discover, profile }

/// Explicit, replaceable callbacks for presentation-only user intentions.
@immutable
final class LibraryHomeCallbacks {
  /// Creates callbacks for visible home actions.
  const LibraryHomeCallbacks({
    this.onSearch,
    this.onReadingHistory,
    this.onContinueReading,
    this.onOpenBook,
    this.onBookMore,
    this.onManageSources,
    this.onNavigationSelected,
  });

  final VoidCallback? onSearch;
  final VoidCallback? onReadingHistory;
  final VoidCallback? onContinueReading;
  final ValueChanged<LibraryBookUpdateViewData>? onOpenBook;
  final ValueChanged<LibraryBookUpdateViewData>? onBookMore;
  final VoidCallback? onManageSources;
  final ValueChanged<LibraryNavigationDestination>? onNavigationSelected;
}

/// Clearly disclosed fixture data used before a Runtime Facade projection exists.
abstract final class LibraryHomeFixtures {
  static final LibraryHomeViewData preview = LibraryHomeViewData(
    isPresentationFixture: true,
    availableSourceCount: 12,
    continueReading: const LibraryContinueReadingViewData(
      bookId: 'fixture-moonlit-library',
      title: '月影书塔',
      chapter: '第 1268 章 月下的回信',
      progress: 0.72,
      lastReadLabel: '上次阅读 · 1 小时 10 分钟前',
      coverVariant: LibraryCoverVariant.dusk,
    ),
    books: <LibraryBookUpdateViewData>[
      LibraryBookUpdateViewData(
        id: 'fixture-moonlit-library',
        title: '月影书塔',
        chapter: '第 1268 章 月下的回信',
        updatedLabel: '1 小时前',
        coverVariant: LibraryCoverVariant.dusk,
        status: LibraryBookStatus.ongoing,
        hasUnreadUpdate: true,
        tags: const <LibraryMetadataTagViewData>[
          LibraryMetadataTagViewData(
            label: '示例书源',
            tone: LibraryMetadataTone.accent,
          ),
          LibraryMetadataTagViewData(
            label: '稳定',
            tone: LibraryMetadataTone.success,
          ),
        ],
      ),
      LibraryBookUpdateViewData(
        id: 'fixture-starlit-letter',
        title: '星海来信',
        chapter: '第 980 章 风停之前',
        updatedLabel: '3 小时前',
        coverVariant: LibraryCoverVariant.dawn,
        status: LibraryBookStatus.ongoing,
        hasUnreadUpdate: true,
        tags: const <LibraryMetadataTagViewData>[
          LibraryMetadataTagViewData(
            label: '本地样例',
            tone: LibraryMetadataTone.accent,
          ),
        ],
      ),
      LibraryBookUpdateViewData(
        id: 'fixture-rainy-observatory',
        title: '雨夜观测站',
        chapter: '第 465 章 远方的光',
        updatedLabel: '昨天更新',
        coverVariant: LibraryCoverVariant.indigo,
        status: LibraryBookStatus.completed,
        hasUnreadUpdate: true,
        tags: const <LibraryMetadataTagViewData>[
          LibraryMetadataTagViewData(
            label: '完结',
            tone: LibraryMetadataTone.success,
          ),
        ],
      ),
      LibraryBookUpdateViewData(
        id: 'fixture-deep-blue',
        title: '深蓝轨迹',
        chapter: '第 1723 章 启航',
        updatedLabel: '2 天前更新',
        coverVariant: LibraryCoverVariant.ocean,
        status: LibraryBookStatus.local,
        tags: const <LibraryMetadataTagViewData>[
          LibraryMetadataTagViewData(
            label: '已缓存',
            tone: LibraryMetadataTone.neutral,
          ),
        ],
      ),
      LibraryBookUpdateViewData(
        id: 'fixture-ember-ring',
        title: '炉火之环',
        chapter: '第 312 章 新的契约',
        updatedLabel: '3 天前更新',
        coverVariant: LibraryCoverVariant.ember,
        status: LibraryBookStatus.completed,
        tags: const <LibraryMetadataTagViewData>[
          LibraryMetadataTagViewData(
            label: '完结',
            tone: LibraryMetadataTone.success,
          ),
        ],
      ),
    ],
  );
}
