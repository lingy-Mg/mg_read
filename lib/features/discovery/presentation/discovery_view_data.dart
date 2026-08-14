import 'package:flutter/foundation.dart';

import 'package:mg_read/app/app_strings.dart';

/// Immutable, display-ready data for the discovery presentation.
///
/// The current fixture is intentionally local and does not represent a
/// Runtime Facade result, a real source, persisted content, or network data.
@immutable
final class DiscoveryPageViewData {
  DiscoveryPageViewData({
    required this.isPresentationFixture,
    required this.hero,
    required Iterable<DiscoveryBookViewData> popularBooks,
    required Iterable<DiscoveryRankedBookViewData> rankedBooks,
    required Iterable<DiscoveryCategoryViewData> categories,
    required this.editorsChoice,
  }) : popularBooks = List<DiscoveryBookViewData>.unmodifiable(popularBooks),
       rankedBooks = List<DiscoveryRankedBookViewData>.unmodifiable(
         rankedBooks,
       ),
       categories = List<DiscoveryCategoryViewData>.unmodifiable(categories);

  final bool isPresentationFixture;
  final DiscoveryHeroViewData hero;
  final List<DiscoveryBookViewData> popularBooks;
  final List<DiscoveryRankedBookViewData> rankedBooks;
  final List<DiscoveryCategoryViewData> categories;
  final DiscoveryEditorsChoiceViewData editorsChoice;
}

@immutable
final class DiscoveryHeroViewData {
  const DiscoveryHeroViewData({
    required this.title,
    required this.category,
    required this.description,
    required this.metadata,
    required this.coverVariant,
  });

  final String title;
  final String category;
  final String description;
  final String metadata;
  final DiscoveryCoverVariant coverVariant;
}

@immutable
final class DiscoveryBookViewData {
  const DiscoveryBookViewData({
    required this.title,
    required this.author,
    required this.coverVariant,
  });

  final String title;
  final String author;
  final DiscoveryCoverVariant coverVariant;
}

@immutable
final class DiscoveryRankedBookViewData {
  const DiscoveryRankedBookViewData({
    required this.rank,
    required this.title,
    required this.author,
    required this.heat,
    required this.coverVariant,
  });

  final int rank;
  final String title;
  final String author;
  final String heat;
  final DiscoveryCoverVariant coverVariant;
}

@immutable
final class DiscoveryCategoryViewData {
  const DiscoveryCategoryViewData({
    required this.title,
    required this.count,
    required this.icon,
  });

  final String title;
  final String count;
  final DiscoveryCategoryIcon icon;
}

@immutable
final class DiscoveryEditorsChoiceViewData {
  const DiscoveryEditorsChoiceViewData({
    required this.title,
    required this.category,
    required this.description,
    required this.metadata,
    required this.coverVariant,
  });

  final String title;
  final String category;
  final String description;
  final String metadata;
  final DiscoveryCoverVariant coverVariant;
}

enum DiscoveryCoverVariant { gothic, dawn, indigo, ember, snow, abyss }

enum DiscoveryCategoryIcon {
  fantasy,
  adventure,
  martialArts,
  xianxia,
  urban,
  history,
  game,
  sciFi,
}

/// Explicit preview content used only while the discovery Facade projection is
/// unavailable.
abstract final class DiscoveryFixtures {
  static final DiscoveryPageViewData preview = DiscoveryPageViewData(
    isPresentationFixture: true,
    hero: const DiscoveryHeroViewData(
      title: AppStrings.discoveryHeroTitle,
      category: AppStrings.discoveryHeroCategory,
      description: AppStrings.discoveryHeroDescription,
      metadata: AppStrings.discoveryHeroMetadata,
      coverVariant: DiscoveryCoverVariant.gothic,
    ),
    popularBooks: const <DiscoveryBookViewData>[
      DiscoveryBookViewData(
        title: AppStrings.discoveryBookHeavenlyPath,
        author: AppStrings.discoveryAuthorMaoNi,
        coverVariant: DiscoveryCoverVariant.dawn,
      ),
      DiscoveryBookViewData(
        title: AppStrings.discoveryBookDeepSpace,
        author: AppStrings.discoveryAuthorChenDong,
        coverVariant: DiscoveryCoverVariant.indigo,
      ),
      DiscoveryBookViewData(
        title: AppStrings.discoveryBookCircle,
        author: AppStrings.discoveryAuthorCuttlefish,
        coverVariant: DiscoveryCoverVariant.ember,
      ),
      DiscoveryBookViewData(
        title: AppStrings.discoveryBookDrummer,
        author: AppStrings.discoveryAuthorNewsboy,
        coverVariant: DiscoveryCoverVariant.snow,
      ),
      DiscoveryBookViewData(
        title: AppStrings.discoveryBookMentalHospital,
        author: AppStrings.discoveryAuthorSanJiu,
        coverVariant: DiscoveryCoverVariant.abyss,
      ),
    ],
    rankedBooks: const <DiscoveryRankedBookViewData>[
      DiscoveryRankedBookViewData(
        rank: 1,
        title: AppStrings.discoveryHeroTitle,
        author: AppStrings.discoveryAuthorCuttlefish,
        heat: AppStrings.discoveryHeatFirst,
        coverVariant: DiscoveryCoverVariant.gothic,
      ),
      DiscoveryRankedBookViewData(
        rank: 2,
        title: AppStrings.discoveryBookHeavenlyPath,
        author: AppStrings.discoveryAuthorMaoNi,
        heat: AppStrings.discoveryHeatSecond,
        coverVariant: DiscoveryCoverVariant.dawn,
      ),
      DiscoveryRankedBookViewData(
        rank: 3,
        title: AppStrings.discoveryBookDeepSpace,
        author: AppStrings.discoveryAuthorChenDong,
        heat: AppStrings.discoveryHeatThird,
        coverVariant: DiscoveryCoverVariant.indigo,
      ),
      DiscoveryRankedBookViewData(
        rank: 4,
        title: AppStrings.discoveryBookCircle,
        author: AppStrings.discoveryAuthorCuttlefish,
        heat: AppStrings.discoveryHeatFourth,
        coverVariant: DiscoveryCoverVariant.ember,
      ),
      DiscoveryRankedBookViewData(
        rank: 5,
        title: AppStrings.discoveryBookDrummer,
        author: AppStrings.discoveryAuthorNewsboy,
        heat: AppStrings.discoveryHeatFifth,
        coverVariant: DiscoveryCoverVariant.snow,
      ),
    ],
    categories: const <DiscoveryCategoryViewData>[
      DiscoveryCategoryViewData(
        title: AppStrings.discoveryCategoryFantasy,
        count: AppStrings.discoveryCategoryFantasyCount,
        icon: DiscoveryCategoryIcon.fantasy,
      ),
      DiscoveryCategoryViewData(
        title: AppStrings.discoveryCategoryAdventure,
        count: AppStrings.discoveryCategoryAdventureCount,
        icon: DiscoveryCategoryIcon.adventure,
      ),
      DiscoveryCategoryViewData(
        title: AppStrings.discoveryCategoryMartialArts,
        count: AppStrings.discoveryCategoryMartialArtsCount,
        icon: DiscoveryCategoryIcon.martialArts,
      ),
      DiscoveryCategoryViewData(
        title: AppStrings.discoveryCategoryXianxia,
        count: AppStrings.discoveryCategoryXianxiaCount,
        icon: DiscoveryCategoryIcon.xianxia,
      ),
      DiscoveryCategoryViewData(
        title: AppStrings.discoveryCategoryUrban,
        count: AppStrings.discoveryCategoryUrbanCount,
        icon: DiscoveryCategoryIcon.urban,
      ),
      DiscoveryCategoryViewData(
        title: AppStrings.discoveryCategoryHistory,
        count: AppStrings.discoveryCategoryHistoryCount,
        icon: DiscoveryCategoryIcon.history,
      ),
      DiscoveryCategoryViewData(
        title: AppStrings.discoveryCategoryGame,
        count: AppStrings.discoveryCategoryGameCount,
        icon: DiscoveryCategoryIcon.game,
      ),
      DiscoveryCategoryViewData(
        title: AppStrings.discoveryCategorySciFi,
        count: AppStrings.discoveryCategorySciFiCount,
        icon: DiscoveryCategoryIcon.sciFi,
      ),
    ],
    editorsChoice: const DiscoveryEditorsChoiceViewData(
      title: AppStrings.discoveryEditorsChoiceBook,
      category: AppStrings.discoveryEditorsChoiceCategory,
      description: AppStrings.discoveryEditorsChoiceDescription,
      metadata: AppStrings.discoveryEditorsChoiceMetadata,
      coverVariant: DiscoveryCoverVariant.snow,
    ),
  );
}
