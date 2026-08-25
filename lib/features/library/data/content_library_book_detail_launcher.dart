import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/features/library/application/library_book_detail_launcher.dart';
import 'package:mg_read/features/library/application/library_book_detail_failure.dart';

/// Adapts app-owned shelf metadata and catalog to the shared detail UI input.
final class ContentLibraryBookDetailLauncher
    implements LibraryBookDetailLauncher {
  const ContentLibraryBookDetailLauncher(this._library);

  final ContentLibrary _library;

  @override
  Future<LibraryBookDetailLaunchData> load(String bookId) async {
    final item = await _loadItem(bookId);
    if (item == null) {
      throw _failure(
        LibraryBookDetailFailureReason.itemMissing,
        AppErrorCode.notFound,
      );
    }
    if (item.kind != ContentKind.novel) {
      throw _failure(
        LibraryBookDetailFailureReason.unsupportedContent,
        AppErrorCode.unsupported,
      );
    }
    if (item.source == null) {
      throw _failure(
        LibraryBookDetailFailureReason.sourceMissing,
        AppErrorCode.invalidFormat,
      );
    }
    final source = item.source!;
    final catalog = await _loadCatalog(item.id);
    return LibraryBookDetailLaunchData(
      pluginId: source.pluginId,
      remoteContentId: source.remoteContentId,
      sourceName: item.sourceName ?? '书架来源',
      initialContent: PluginContentSummary(
        id: source.remoteContentId,
        title: item.title,
        contentKind: PluginContentKind.novel,
        author: item.author,
        url: item.sourceUrl,
        coverUrl: item.coverUrl,
        description: item.description,
        language: null,
        status: _statusFromLabel(item.statusLabel),
        access: PluginAccessKind.unknown,
        wordCount: item.wordCount,
        chapterCount: item.chapterCount ?? catalog.length,
        publishedAt: null,
        updatedAt: null,
        latestChapter: item.latestChapterTitle == null
            ? null
            : PluginLatestChapter(
                id: null,
                title: item.latestChapterTitle!,
                url: item.latestChapterUrl,
                updatedAt: null,
              ),
        categories: item.labels,
        tags: const <String>[],
        attributes: const <PluginContentAttribute>[],
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
      throw LibraryBookDetailFailure(
        reason: LibraryBookDetailFailureReason.itemRead,
        error: AppError.fromUnknown(error),
      );
    }
  }

  Future<List<CatalogEntry>> _loadCatalog(LibraryItemId itemId) async {
    try {
      return await _library.listAllCatalog(itemId);
    } on Object catch (error) {
      throw LibraryBookDetailFailure(
        reason: LibraryBookDetailFailureReason.catalogRead,
        error: AppError.fromUnknown(error),
      );
    }
  }

  PluginContentStatus _statusFromLabel(String? label) => switch (label) {
    '连载' => PluginContentStatus.ongoing,
    '已完结' => PluginContentStatus.completed,
    '暂停更新' => PluginContentStatus.hiatus,
    _ => PluginContentStatus.unknown,
  };

  LibraryBookDetailFailure _failure(
    LibraryBookDetailFailureReason reason,
    AppErrorCode code,
  ) => LibraryBookDetailFailure(reason: reason, error: AppError.fromCode(code));
}
