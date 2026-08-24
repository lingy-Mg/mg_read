import 'package:flutter/foundation.dart';

import 'package:mg_read/features/library/domain/library_overview.dart';
import 'package:mg_read/features/library/domain/library_item_summary.dart';
import 'package:mg_read/features/library/presentation/library_book_list_view_data.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';

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
    required Iterable<LibraryBookListItemViewData> books,
    this.availableSourceCount,
  }) : books = List<LibraryBookListItemViewData>.unmodifiable(books);

  /// Maps the currently narrow local overview contract without inventing
  /// reading progress, chapter metadata, source availability, or timestamps.
  factory LibraryHomeViewData.fromLocalOverview(LibraryOverview overview) {
    final current = overview.continueReading;
    final currentIndex = current == null ? -1 : overview.items.indexOf(current);
    return LibraryHomeViewData(
      isPresentationFixture: false,
      continueReading: current == null
          ? null
          : LibraryContinueReadingViewData(
              bookId: current.id,
              title: current.title,
              chapter: '第${(current.readingChapterIndex ?? 0) + 1}章',
              progress: current.readingProgress!,
              lastReadLabel: '上次阅读',
              coverVariant: LibraryCoverVariant
                  .values[currentIndex % LibraryCoverVariant.values.length],
              coverUrl: current.coverUrl,
              coverBytes: current.coverBytes,
            ),
      books: overview.items.asMap().entries.map(
        (entry) => LibraryBookListItemViewData(
          id: entry.value.id,
          title: entry.value.title,
          subtitle: _librarySubtitle(entry.value),
          coverUrl: entry.value.coverUrl,
          coverBytes: entry.value.coverBytes,
          coverVariant: LibraryCoverVariant
              .values[entry.key % LibraryCoverVariant.values.length],
          status: LibraryBookStatus.local,
        ),
      ),
    );
  }

  /// Creates the first-run state from a successfully read, empty bookshelf.
  factory LibraryHomeViewData.empty() => LibraryHomeViewData(
    isPresentationFixture: false,
    continueReading: null,
    books: const <LibraryBookListItemViewData>[],
  );

  /// Whether the projection is an explicit UI fixture rather than user data.
  final bool isPresentationFixture;

  /// Current reading information, when a future local projection provides it.
  final LibraryContinueReadingViewData? continueReading;

  /// The display-ready book rows for each library-list presentation.
  final List<LibraryBookListItemViewData> books;

  /// Optional source count; a fixture may provide it, a local projection may
  /// leave it unknown until the source-management feature exists.
  final int? availableSourceCount;
}

String? _librarySubtitle(LibraryItemSummary item) {
  final parts = <String>[
    if (item.author != null && item.author!.isNotEmpty) item.author!,
    if (item.sourceName != null && item.sourceName!.isNotEmpty)
      item.sourceName!,
  ];
  return parts.isEmpty ? null : parts.join(' · ');
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
    this.coverUrl,
    this.coverBytes,
    this.coverAssetPath,
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
  final Uri? coverUrl;
  final List<int>? coverBytes;
  final String? coverAssetPath;
}

/// The currently active non-persistent update-list filter.
enum LibraryStatusFilter { all, ongoing, completed, local }

/// The two content sections available at the library landing page.
enum LibraryHomeSection { recentUpdates, shelf }

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
    this.onDeleteBook,
    this.onManageSources,
    this.onDiscover,
    this.onImportLocal,
    this.onNavigationSelected,
    this.onProfileSelected,
  });

  final VoidCallback? onSearch;
  final VoidCallback? onReadingHistory;
  final VoidCallback? onContinueReading;
  final ValueChanged<LibraryBookListItemViewData>? onOpenBook;
  final ValueChanged<LibraryBookListItemViewData>? onBookMore;
  final Future<void> Function(LibraryBookListItemViewData)? onDeleteBook;
  final VoidCallback? onManageSources;
  final VoidCallback? onDiscover;
  final VoidCallback? onImportLocal;
  final ValueChanged<AppNavigationDestination>? onNavigationSelected;

  /// Requests the profile route without making this feature own app routing.
  final VoidCallback? onProfileSelected;

  /// Copies this callback collection while replacing selected intentions.
  LibraryHomeCallbacks copyWith({
    VoidCallback? onSearch,
    VoidCallback? onReadingHistory,
    VoidCallback? onContinueReading,
    ValueChanged<LibraryBookListItemViewData>? onOpenBook,
    ValueChanged<LibraryBookListItemViewData>? onBookMore,
    Future<void> Function(LibraryBookListItemViewData)? onDeleteBook,
    VoidCallback? onManageSources,
    VoidCallback? onDiscover,
    VoidCallback? onImportLocal,
    ValueChanged<AppNavigationDestination>? onNavigationSelected,
    VoidCallback? onProfileSelected,
  }) {
    return LibraryHomeCallbacks(
      onSearch: onSearch ?? this.onSearch,
      onReadingHistory: onReadingHistory ?? this.onReadingHistory,
      onContinueReading: onContinueReading ?? this.onContinueReading,
      onOpenBook: onOpenBook ?? this.onOpenBook,
      onBookMore: onBookMore ?? this.onBookMore,
      onDeleteBook: onDeleteBook ?? this.onDeleteBook,
      onManageSources: onManageSources ?? this.onManageSources,
      onDiscover: onDiscover ?? this.onDiscover,
      onImportLocal: onImportLocal ?? this.onImportLocal,
      onNavigationSelected: onNavigationSelected ?? this.onNavigationSelected,
      onProfileSelected: onProfileSelected ?? this.onProfileSelected,
    );
  }
}

/// Clearly disclosed fixture data used before a Runtime Facade projection exists.
abstract final class LibraryHomeFixtures {
  static final LibraryHomeViewData preview = LibraryHomeViewData(
    isPresentationFixture: true,
    availableSourceCount: 12,
    continueReading: const LibraryContinueReadingViewData(
      bookId: 'fixture-lord-of-mysteries',
      title: '诡秘之主',
      chapter: '第1268章 不可名状的低语',
      progress: 0.72,
      lastReadLabel: '继续阅读 · 1小时10分钟前',
      coverVariant: LibraryCoverVariant.dusk,
      coverAssetPath: 'assets/fixtures/home_covers/lord_of_mysteries.png',
    ),
    books: <LibraryBookListItemViewData>[
      LibraryBookListItemViewData(
        id: 'fixture-lord-of-mysteries',
        title: '诡秘之主',
        subtitle: '第1268章 不可名状的低语',
        activityLabel: '1小时前',
        coverVariant: LibraryCoverVariant.dusk,
        coverAssetPath:
            'assets/fixtures/home_covers/lord_of_mysteries_small.png',
        status: LibraryBookStatus.ongoing,
        hasAttentionIndicator: true,
        tags: const <LibraryMetadataTagViewData>[
          LibraryMetadataTagViewData(
            label: '起点中文网',
            tone: LibraryMetadataTone.accent,
          ),
          LibraryMetadataTagViewData(
            label: '高质量',
            tone: LibraryMetadataTone.neutral,
          ),
          LibraryMetadataTagViewData(
            label: '稳定',
            tone: LibraryMetadataTone.neutral,
          ),
        ],
      ),
      LibraryBookListItemViewData(
        id: 'fixture-heavenly-path',
        title: '大道朝天',
        subtitle: '第980章 天道酬勤',
        activityLabel: '3小时前',
        coverVariant: LibraryCoverVariant.dawn,
        coverAssetPath: 'assets/fixtures/home_covers/heavenly_path.png',
        status: LibraryBookStatus.ongoing,
        hasAttentionIndicator: true,
        tags: const <LibraryMetadataTagViewData>[
          LibraryMetadataTagViewData(
            label: '纵横中文网',
            tone: LibraryMetadataTone.accent,
          ),
          LibraryMetadataTagViewData(
            label: '优质',
            tone: LibraryMetadataTone.neutral,
          ),
        ],
      ),
      LibraryBookListItemViewData(
        id: 'fixture-i-am-in-a-mental-hospital',
        title: '我在精神病院学斩神',
        subtitle: '第465章 神明的丝线',
        activityLabel: '昨天更新',
        coverVariant: LibraryCoverVariant.indigo,
        coverAssetPath: 'assets/fixtures/home_covers/mental_hospital.png',
        status: LibraryBookStatus.completed,
        hasAttentionIndicator: true,
        tags: const <LibraryMetadataTagViewData>[
          LibraryMetadataTagViewData(
            label: '17K小说网',
            tone: LibraryMetadataTone.accent,
          ),
          LibraryMetadataTagViewData(
            label: '稳定',
            tone: LibraryMetadataTone.neutral,
          ),
        ],
      ),
      LibraryBookListItemViewData(
        id: 'fixture-beyond-the-deep-sky',
        title: '深空彼岸',
        subtitle: '第1723章 启航',
        activityLabel: '2天前更新',
        coverVariant: LibraryCoverVariant.ocean,
        coverAssetPath: 'assets/fixtures/home_covers/deep_space.png',
        status: LibraryBookStatus.local,
        tags: const <LibraryMetadataTagViewData>[
          LibraryMetadataTagViewData(
            label: '飞卢小说网',
            tone: LibraryMetadataTone.accent,
          ),
          LibraryMetadataTagViewData(
            label: '优质',
            tone: LibraryMetadataTone.neutral,
          ),
        ],
      ),
      LibraryBookListItemViewData(
        id: 'fixture-circle-of-inevitability',
        title: '宿命之环',
        subtitle: '第312章 新的契约',
        activityLabel: '3天前更新',
        coverVariant: LibraryCoverVariant.ember,
        coverAssetPath:
            'assets/fixtures/home_covers/circle_of_inevitability.png',
        status: LibraryBookStatus.completed,
        tags: const <LibraryMetadataTagViewData>[
          LibraryMetadataTagViewData(
            label: '番茄小说',
            tone: LibraryMetadataTone.accent,
          ),
          LibraryMetadataTagViewData(
            label: '稳定',
            tone: LibraryMetadataTone.neutral,
          ),
        ],
      ),
    ],
  );
}
