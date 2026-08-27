/// Content Library 书架详情启动适配器。
///
/// 职责：
/// - 将持久化书架摘要和有界目录预览映射为共享详情页输入。
/// - 保留热度等结构化属性供本地优先渲染。
///
/// 注意：
/// - 只读取首批目录，避免长按等待完整大目录反序列化。
/// - 远端详情和完整目录刷新由共享详情页异步执行。
library;

import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/features/library/application/library_book_detail_launcher.dart';
import 'package:mg_read/features/library/application/library_book_detail_failure.dart';

/// Adapts app-owned shelf metadata and catalog to the shared detail UI input.
final class ContentLibraryBookDetailLauncher implements LibraryBookDetailLauncher {
  const ContentLibraryBookDetailLauncher(this._library);

  final ContentLibrary _library;

  @override
  Future<LibraryBookDetailLaunchData> load(String bookId) async {
    final item = await _loadItem(bookId);
    if (item == null) {
      throw _failure(LibraryBookDetailFailureReason.itemMissing, AppErrorCode.notFound);
    }
    if (item.source == null) {
      throw _failure(LibraryBookDetailFailureReason.sourceMissing, AppErrorCode.invalidFormat);
    }
    final source = item.source!;
    final catalog = await _loadCatalogPreview(item.id);
    return LibraryBookDetailLaunchData(
      pluginId: source.pluginId,
      remoteContentId: source.remoteContentId,
      sourceName: item.sourceName ?? '书架来源',
      initialContent: PluginContentSummary(
        id: source.remoteContentId,
        title: item.title,
        contentKind: switch (item.kind) {
          ContentKind.novel => PluginContentKind.novel,
          ContentKind.manga => PluginContentKind.manga,
        },
        author: item.author,
        url: item.sourceUrl,
        coverUrl: item.coverUrl,
        description: item.description,
        language: item.language,
        status: _statusFromLabel(item.statusLabel),
        access: _accessFromCode(item.accessCode),
        wordCount: item.wordCount,
        chapterCount: item.chapterCount ?? catalog.length,
        publishedAt: item.publishedAt,
        updatedAt: item.updatedAt,
        latestChapter: item.latestChapterTitle == null
            ? null
            : PluginLatestChapter(
                id: item.latestChapterId,
                title: item.latestChapterTitle!,
                url: item.latestChapterUrl,
                updatedAt: item.latestChapterUpdatedAt,
              ),
        categories: item.categories.isEmpty ? item.labels : item.categories,
        tags: item.tags,
        attributes: <PluginContentAttribute>[
          for (final attribute in item.attributes)
            PluginContentAttribute(key: attribute.key, label: attribute.label, value: attribute.value),
        ],
      ),
      initialCatalog: PluginChaptersResult(
        pluginId: source.pluginId,
        sourceName: item.sourceName ?? '书架来源',
        items: <PluginChapterSummary>[
          for (final entry in catalog)
            PluginChapterSummary(
              id: entry.remoteIdentity,
              title: entry.title,
              order: entry.index,
              url: entry.chapterUrl,
              volumeTitle: null,
              wordCount: entry.wordCount,
              updatedAt: null,
              isLocked: null,
              attributes: const <PluginContentAttribute>[],
            ),
        ],
      ),
    );
  }

  Future<LibraryItem?> _loadItem(String bookId) async {
    try {
      return await _library.getLibraryItem(LibraryItemId(bookId));
    } on Object catch (error) {
      throw LibraryBookDetailFailure(reason: LibraryBookDetailFailureReason.itemRead, error: AppError.fromUnknown(error));
    }
  }

  Future<List<CatalogEntry>> _loadCatalogPreview(LibraryItemId itemId) async {
    try {
      return (await _library.listCatalog(itemId, const CatalogQuery(limit: 100))).items;
    } on Object catch (error) {
      throw LibraryBookDetailFailure(reason: LibraryBookDetailFailureReason.catalogRead, error: AppError.fromUnknown(error));
    }
  }

  PluginContentStatus _statusFromLabel(String? label) => switch (label) {
    '连载' => PluginContentStatus.ongoing,
    '已完结' => PluginContentStatus.completed,
    '暂停更新' => PluginContentStatus.hiatus,
    _ => PluginContentStatus.unknown,
  };

  PluginAccessKind _accessFromCode(String? code) => switch (code) {
    'free' => PluginAccessKind.free,
    'paid' => PluginAccessKind.paid,
    'mixed' => PluginAccessKind.mixed,
    _ => PluginAccessKind.unknown,
  };

  LibraryBookDetailFailure _failure(LibraryBookDetailFailureReason reason, AppErrorCode code) =>
      LibraryBookDetailFailure(reason: reason, error: AppError.fromCode(code));
}
