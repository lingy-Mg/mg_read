import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

/// Captured from the public Alice Book House detail projection on 2026-08-21.
///
/// Golden tests consume these values directly and never start a source plugin
/// or request the source website.
abstract final class AliceBookHouseDetailFixture {
  static const String pluginId = 'org.mgread.aisishuwu';
  static const String bookId = 'novel:52801';

  static final Uri sourceUrl = Uri.parse(
    'https://www.alicesw.com/novel/52801.html',
  );
  static final Uri catalogUrl = Uri.parse(
    'https://www.alicesw.com/other/chapters/id/52801.html',
  );
  static final Uri latestUrl = Uri.parse(
    'https://www.alicesw.com/book/54221/34f357289cc15.html',
  );

  static final PluginContentDetail detail = PluginContentDetail(
    pluginId: pluginId,
    sourceName: '爱丽丝书屋',
    summary: PluginContentSummary(
      id: bookId,
      title: '变身绝色女神（ai加料）',
      contentKind: PluginContentKind.novel,
      author: '喜欢老虎',
      url: sourceUrl,
      // Golden tests stay offline. The source contract test separately
      // verifies that the real public cover URL is retained.
      coverUrl: null,
      description: '来源页面已验证的作品简介。',
      language: 'zh-CN',
      status: PluginContentStatus.ongoing,
      access: PluginAccessKind.unknown,
      wordCount: 1859600,
      chapterCount: 733,
      publishedAt: null,
      updatedAt: DateTime.utc(2026, 8, 10, 4, 31),
      latestChapter: PluginLatestChapter(
        id: 'chapter:latest',
        title: '第七百三十二章 浩瀚星海（大结局）',
        url: latestUrl,
        updatedAt: DateTime.utc(2026, 8, 10, 4, 31),
      ),
      categories: const <String>['科幻'],
      tags: const <String>['变身', '性转', '百合', '百破', 'ai加料'],
      attributes: const <PluginContentAttribute>[
        PluginContentAttribute(key: 'heat', label: '热度', value: '12210'),
        PluginContentAttribute(key: 'favorites', label: '收藏', value: '49'),
      ],
    ),
    aliases: const <String>[],
    catalogUrl: catalogUrl,
  );

  static final PluginChaptersResult firstCatalogPage = PluginChaptersResult(
    pluginId: pluginId,
    sourceName: '爱丽丝书屋',
    items: <PluginChapterSummary>[
      _chapter('chapter:1', '第一章 重生', 0),
      _chapter('chapter:2', '第二章 苏醒', 1),
      _chapter('chapter:3', '第三章 风华绝代', 2),
      _chapter('chapter:4', '第四章 应聘', 3),
    ],
  );

  static final List<PluginContentSummary> recommendations =
      <PluginContentSummary>[
        _recommendation('great-dawn', '大道朝天', '猫腻'),
        _recommendation('deep-shore', '深空彼岸', '辰东'),
        _recommendation('fate-ring', '宿命之环', '爱潜水的乌贼'),
        _recommendation('great-hitter', '大奉打更人', '卖报小郎君'),
        _recommendation('myth-emperor', '我在精神病院学斩神', '林七夜'),
      ];

  static const String referencePluginId = 'org.mgread.reference';
  static const String referenceBookId = 'mystery-lord';
  static final PluginContentDetail referenceDetail = PluginContentDetail(
    pluginId: referencePluginId,
    sourceName: '起点中文网',
    summary: PluginContentSummary(
      id: referenceBookId,
      title: '诡秘之主',
      contentKind: PluginContentKind.novel,
      author: '爱潜水的乌贼',
      url: Uri.parse('https://www.qidian.com/book/1010868264'),
      coverUrl: null,
      description:
          '蒸汽与机械的浪潮中，谁能触及非凡？诡秘的序列，命运的齿轮，'
          '即将开始转动。戴上隐秘的面具，潜入黑暗的深渊，探寻真正的诡秘。',
      language: 'zh-CN',
      status: PluginContentStatus.completed,
      access: PluginAccessKind.unknown,
      wordCount: 4470000,
      chapterCount: 1268,
      publishedAt: null,
      updatedAt: DateTime.utc(2026, 8, 21, 9),
      latestChapter: PluginLatestChapter(
        id: '1268',
        title: '第1268章 不可名状的低语（大结局）',
        url: Uri.parse('https://www.qidian.com/chapter/1010868264/811552318/'),
        updatedAt: DateTime.utc(2026, 8, 21, 9),
      ),
      categories: const <String>['玄幻'],
      tags: const <String>['克苏鲁', '西幻'],
      attributes: const <PluginContentAttribute>[
        PluginContentAttribute(key: 'rating', label: '评分', value: '9.7'),
        PluginContentAttribute(
          key: 'ratingCount',
          label: '评分人数',
          value: '42.3万',
        ),
        PluginContentAttribute(key: 'theme', label: '主题', value: '克苏鲁'),
        PluginContentAttribute(key: 'genre', label: '题材', value: '蒸汽朋克'),
        PluginContentAttribute(key: 'ability', label: '要素', value: '异能'),
        PluginContentAttribute(key: 'tone', label: '风格', value: '悬疑'),
        PluginContentAttribute(
          key: 'discoveryUpdatedLabel',
          label: '更新时间',
          value: '1小时前更新',
        ),
      ],
    ),
    aliases: const <String>[],
    catalogUrl: Uri.parse('https://www.qidian.com/book/1010868264#Catalog'),
  );

  static final PluginChaptersResult referenceCatalog = PluginChaptersResult(
    pluginId: referencePluginId,
    sourceName: '起点中文网',
    items: <PluginChapterSummary>[
      PluginChapterSummary(
        id: '1268',
        title: '第1268章 不可名状的低语（大结局）',
        order: 1268,
        url: Uri.parse('https://www.qidian.com/chapter/1010868264/811552318/'),
        volumeTitle: null,
        wordCount: null,
        updatedAt: DateTime.utc(2026, 8, 21, 9),
        isLocked: false,
        attributes: const <PluginContentAttribute>[],
      ),
    ],
  );

  static final List<PluginContentSummary> referenceRecommendations =
      <PluginContentSummary>[
        _recommendation('great-dawn', '大道朝天', '猫腻'),
        _recommendation('deep-shore', '深空彼岸', '辰东'),
        _recommendation('fate-ring', '宿命之环', '爱潜水的乌贼'),
        _recommendation('great-hitter', '大奉打更人', '卖报小郎君'),
        _recommendation('myth-emperor', '我在精神病院学斩神', '林七夜'),
      ];

  static PluginContentSummary _recommendation(
    String id,
    String title,
    String author,
  ) => PluginContentSummary(
    id: id,
    title: title,
    contentKind: PluginContentKind.novel,
    author: author,
    url: null,
    coverUrl: null,
    description: null,
    language: 'zh-CN',
    status: PluginContentStatus.ongoing,
    access: PluginAccessKind.unknown,
    wordCount: null,
    chapterCount: null,
    publishedAt: null,
    updatedAt: null,
    latestChapter: null,
    categories: const <String>[],
    tags: const <String>[],
    attributes: const <PluginContentAttribute>[],
  );

  static PluginChapterSummary _chapter(String id, String title, int order) =>
      PluginChapterSummary(
        id: id,
        title: title,
        order: order,
        url: latestUrl,
        volumeTitle: null,
        wordCount: null,
        updatedAt: null,
        isLocked: false,
        attributes: const <PluginContentAttribute>[],
      );
}
