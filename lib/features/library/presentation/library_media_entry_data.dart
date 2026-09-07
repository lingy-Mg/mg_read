/// 书架详情预览与媒体入口数据。
///
/// 职责：
/// - 从已加载的书架投影立即构造详情预览和媒体入口。
/// - 在持久化目录为空时提供仅用于启动的稳定章节占位。
/// - 将首页已解析的封面字节交给下一个路由，避免重复 IO。
///
/// 注意：
/// - 本文件只进行内存投影，不读取 Runtime、网络或持久化。
/// - 占位章节不是真实目录；播放器进入后必须刷新真实媒体目录。
library;

import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/discovery/application/source_content_cover_handoff.dart';
import 'package:mg_read/features/library/domain/library_item_summary.dart';
import 'package:mg_read/features/library/presentation/library_book_list_view_data.dart';
import 'package:mg_read/shared/presentation/widgets/async_book_cover_loader.dart';

final class LibraryMediaEntryData {
  const LibraryMediaEntryData({required this.detail, required this.catalog, required this.chapter});

  final PluginContentDetail detail;
  final PluginChaptersResult catalog;
  final PluginChapterSummary chapter;
}

LibraryMediaEntryData? immediateLibraryMediaEntry(LibraryItemSummary? item, LibraryBookListItemViewData book) {
  if (item?.coverPluginId == null || item?.coverRemoteContentId == null) return null;
  final detail = libraryDetailPreview(item, book);
  final catalog = PluginChaptersResult(pluginId: detail.pluginId, sourceName: detail.sourceName, items: const <PluginChapterSummary>[]);
  return LibraryMediaEntryData(detail: detail, catalog: catalog, chapter: initialLibraryMediaChapter(detail, catalog));
}

LibraryMediaEntryData persistedLibraryMediaEntry({
  required PluginContentDetail detail,
  required PluginChaptersResult catalog,
  required LibraryBookListItemViewData book,
}) {
  final coveredDetail = _withEntryCover(detail, book);
  return LibraryMediaEntryData(detail: coveredDetail, catalog: catalog, chapter: initialLibraryMediaChapter(coveredDetail, catalog));
}

PluginChapterSummary initialLibraryMediaChapter(PluginContentDetail detail, PluginChaptersResult catalog) {
  for (final chapter in catalog.items) {
    if (chapter.isLocked != true) return chapter;
  }
  final latest = detail.summary.latestChapter;
  return PluginChapterSummary(
    id: latest?.id ?? '__shelf_media_entry__',
    title: latest?.title ?? '开始播放',
    order: 0,
    url: latest?.url,
    volumeTitle: null,
    wordCount: null,
    updatedAt: latest?.updatedAt,
    isLocked: false,
    attributes: const <PluginContentAttribute>[],
  );
}

PluginContentDetail libraryDetailPreview(LibraryItemSummary? item, LibraryBookListItemViewData book) {
  final latestTitle = item?.latestChapterTitle;
  final pluginId = item?.coverPluginId ?? book.coverRequest?.pluginId ?? 'library-preview';
  return PluginContentDetail(
    pluginId: pluginId,
    sourceName: item?.sourceName ?? '书架来源',
    aliases: const <String>[],
    catalogUrl: item?.sourceUrl,
    summary: PluginContentSummary(
      id: item?.coverRemoteContentId ?? book.id,
      title: item?.title ?? book.title,
      contentKind: switch (item?.contentKind) {
        ContentKind.audio => PluginContentKind.audio,
        ContentKind.video => PluginContentKind.video,
        ContentKind.manga => PluginContentKind.manga,
        _ => PluginContentKind.novel,
      },
      author: item?.author,
      url: item?.sourceUrl,
      coverUrl: item?.coverUrl ?? book.coverUrl,
      coverBytes: _entryCoverBytes(book, item?.coverBytes),
      description: item?.description,
      language: item?.language,
      status: switch (item?.statusLabel) {
        '连载' => PluginContentStatus.ongoing,
        '已完结' => PluginContentStatus.completed,
        '暂停更新' => PluginContentStatus.hiatus,
        _ => PluginContentStatus.unknown,
      },
      access: switch (item?.accessCode) {
        'free' => PluginAccessKind.free,
        'paid' => PluginAccessKind.paid,
        'mixed' => PluginAccessKind.mixed,
        _ => PluginAccessKind.unknown,
      },
      wordCount: item?.wordCount,
      chapterCount: item?.chapterCount,
      publishedAt: item?.publishedAt,
      updatedAt: item?.updatedAt,
      latestChapter: latestTitle == null
          ? null
          : PluginLatestChapter(
              id: item?.latestChapterId,
              title: latestTitle,
              url: item?.latestChapterUrl,
              updatedAt: item?.latestChapterUpdatedAt,
            ),
      categories: item?.categories ?? const <String>[],
      tags: item?.tags ?? const <String>[],
      attributes: <PluginContentAttribute>[
        for (final attribute in item?.attributes ?? const <LibraryItemSummaryAttribute>[])
          PluginContentAttribute(key: attribute.key, label: attribute.label, value: attribute.value),
      ],
    ),
  );
}

PluginContentDetail _withEntryCover(PluginContentDetail detail, LibraryBookListItemViewData book) {
  // Shelf audio/video launches bypass the detail route when possible, so they
  // must apply the same cover-handoff rule at this projection boundary.
  return preserveSourceContentCover(detail: detail, resolvedCoverBytes: _entryCoverBytes(book, detail.summary.coverBytes));
}

List<int>? _entryCoverBytes(LibraryBookListItemViewData book, List<int>? fallback) =>
    book.coverBytes ?? (book.coverRequest == null ? null : BookCoverMemoryCache.peek(book.coverRequest!)) ?? fallback;
