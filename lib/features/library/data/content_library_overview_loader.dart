/// 书架概览加载器。
///
/// 职责：
/// - 通过一次联表投影读取书架条目和统一进度。
/// - 仅投影封面来源身份，不等待封面字节或网络读取。
///
/// 注意：
/// - 持久化细节只保留在 Content Library 内部。
/// - 封面由展示层在主体显示后异步解析。
///
library;

import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/library/application/library_overview_loader.dart';
import 'package:mg_read/features/library/domain/library_item_summary.dart';
import 'package:mg_read/features/library/domain/library_overview.dart';

/// 通过公开 Content Library 门面读取应用自有书架。
final class ContentLibraryOverviewLoader implements LibraryOverviewLoader {
  ContentLibraryOverviewLoader(this._library);

  final ContentLibrary _library;

  @override
  Future<LibraryOverview> load({LibraryVisibility visibility = LibraryVisibility.normal}) async {
    final shelf = await _library.loadShelfProjection(visibility: visibility);
    final items = shelf.map((item) {
      final source = item.source;
      return LibraryItemSummary(
        id: item.itemId.value,
        title: item.title,
        contentKind: item.kind,
        author: item.author,
        coverUrl: item.coverUrl,
        coverOrientation: item.coverOrientation,
        coverPluginId: source.pluginId,
        coverPluginVersion: source.pluginVersion,
        coverRemoteContentId: source.remoteContentId,
        sourceName: item.sourceName,
        description: item.summaryExcerpt,
        chapterCount: item.sourceChapterCount ?? item.catalogCount,
        readingProgress: item.bookFraction,
        readingChapterIndex: item.chapterPosition,
        lastReadAtUtc: item.progressUpdatedAtUtc,
      );
    });
    return LibraryOverview(items: items);
  }
}
