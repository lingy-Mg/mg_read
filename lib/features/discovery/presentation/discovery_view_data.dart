import 'package:flutter/foundation.dart';

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
      title: '诡秘之主',
      category: '玄幻 · 克苏鲁',
      description: '蒸汽与机械的浪潮中，谁能触及非凡？诡秘的序列，命运的齿轮，即将开始转动。',
      metadata: '爱潜水的乌贼 · 1268章',
      coverVariant: DiscoveryCoverVariant.gothic,
    ),
    popularBooks: const <DiscoveryBookViewData>[
      DiscoveryBookViewData(
        title: '大道朝天',
        author: '猫腻',
        coverVariant: DiscoveryCoverVariant.dawn,
      ),
      DiscoveryBookViewData(
        title: '深空彼岸',
        author: '辰东',
        coverVariant: DiscoveryCoverVariant.indigo,
      ),
      DiscoveryBookViewData(
        title: '宿命之环',
        author: '爱潜水的乌贼',
        coverVariant: DiscoveryCoverVariant.ember,
      ),
      DiscoveryBookViewData(
        title: '大奉打更人',
        author: '卖报小郎君',
        coverVariant: DiscoveryCoverVariant.snow,
      ),
      DiscoveryBookViewData(
        title: '我在精神病院学斩神',
        author: '三九音域',
        coverVariant: DiscoveryCoverVariant.abyss,
      ),
    ],
    rankedBooks: const <DiscoveryRankedBookViewData>[
      DiscoveryRankedBookViewData(
        rank: 1,
        title: '诡秘之主',
        author: '爱潜水的乌贼',
        heat: '562.3万',
        coverVariant: DiscoveryCoverVariant.gothic,
      ),
      DiscoveryRankedBookViewData(
        rank: 2,
        title: '大道朝天',
        author: '猫腻',
        heat: '512.1万',
        coverVariant: DiscoveryCoverVariant.dawn,
      ),
      DiscoveryRankedBookViewData(
        rank: 3,
        title: '深空彼岸',
        author: '辰东',
        heat: '420.8万',
        coverVariant: DiscoveryCoverVariant.indigo,
      ),
      DiscoveryRankedBookViewData(
        rank: 4,
        title: '宿命之环',
        author: '爱潜水的乌贼',
        heat: '388.6万',
        coverVariant: DiscoveryCoverVariant.ember,
      ),
      DiscoveryRankedBookViewData(
        rank: 5,
        title: '大奉打更人',
        author: '卖报小郎君',
        heat: '317.4万',
        coverVariant: DiscoveryCoverVariant.snow,
      ),
    ],
    categories: const <DiscoveryCategoryViewData>[
      DiscoveryCategoryViewData(
        title: '玄幻',
        count: '28万本',
        icon: DiscoveryCategoryIcon.fantasy,
      ),
      DiscoveryCategoryViewData(
        title: '奇幻',
        count: '12万本',
        icon: DiscoveryCategoryIcon.adventure,
      ),
      DiscoveryCategoryViewData(
        title: '武侠',
        count: '9.8万本',
        icon: DiscoveryCategoryIcon.martialArts,
      ),
      DiscoveryCategoryViewData(
        title: '仙侠',
        count: '18万本',
        icon: DiscoveryCategoryIcon.xianxia,
      ),
      DiscoveryCategoryViewData(
        title: '都市',
        count: '16万本',
        icon: DiscoveryCategoryIcon.urban,
      ),
      DiscoveryCategoryViewData(
        title: '历史',
        count: '7.6万本',
        icon: DiscoveryCategoryIcon.history,
      ),
      DiscoveryCategoryViewData(
        title: '游戏',
        count: '11万本',
        icon: DiscoveryCategoryIcon.game,
      ),
      DiscoveryCategoryViewData(
        title: '科幻',
        count: '14万本',
        icon: DiscoveryCategoryIcon.sciFi,
      ),
    ],
    editorsChoice: const DiscoveryEditorsChoiceViewData(
      title: '剑来',
      category: '仙侠',
      description: '大千世界，无奇不有。我陈平安，唯有一剑，可搬山、倒海、降妖、镇魔、救神、摘星、断江、摧城、开天！',
      metadata: '烽火戏诸侯 · 1292章',
      coverVariant: DiscoveryCoverVariant.snow,
    ),
  );
}
