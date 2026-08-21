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
    ],
    nextCursor: 'catalog-page:1:2',
    totalCount: 733,
  );

  static final PluginChaptersResult secondCatalogPage = PluginChaptersResult(
    pluginId: pluginId,
    sourceName: '爱丽丝书屋',
    items: <PluginChapterSummary>[
      _chapter('chapter:3', '第三章 风华绝代', 2),
      _chapter('chapter:4', '第四章 应聘', 3),
    ],
    nextCursor: null,
    totalCount: 733,
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
