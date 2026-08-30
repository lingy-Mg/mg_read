/// Content Library 书架书籍完整刷新适配器。
///
/// 职责：
/// - 使用保存的数据源内容身份重新读取详情和完整目录。
/// - 在 Content Library 中原子切换目录快照并更新书架元数据。
///
/// 注意：
/// - 仅在详情和目录都成功后提交新投影，失败时保留旧书架数据。
/// - 旧封面缓存只按当前书籍键失效，不能清空全局封面缓存。
library;

import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/discovery/application/persisted_source_detail.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/library/application/library_book_refresher.dart';

/// Refreshes one source-backed shelf item through typed source and library APIs.
final class ContentLibraryBookRefresher implements LibraryBookRefresher {
  ContentLibraryBookRefresher(this._library, this._gateway);

  final ContentLibrary _library;
  final SourceContentGateway _gateway;
  final Map<String, Future<void>> _active = <String, Future<void>>{};

  @override
  Future<void> refresh(String bookId) {
    final current = _active[bookId];
    if (current != null) return current;
    final task = _refresh(bookId);
    _active[bookId] = task;
    return task.whenComplete(() {
      if (identical(_active[bookId], task)) _active.remove(bookId);
    });
  }

  Future<void> _refresh(String bookId) async {
    final item = await _library.getLibraryItem(LibraryItemId(bookId));
    final source = item?.source;
    if (item == null) throw StateError('The bookshelf item no longer exists.');
    // The persisted source identity is the durable refresh key. Early shelf
    // records may predate sourceUrl persistence, but they are still refreshable
    // when pluginId and remoteContentId are present.
    if (source == null) throw StateError('The bookshelf item has no source identity.');

    final results = await Future.wait<Object>(<Future<Object>>[
      _gateway.getDetail(pluginId: source.pluginId, id: source.remoteContentId),
      _gateway.getChapters(pluginId: source.pluginId, id: source.remoteContentId),
    ]);
    final detail = results[0] as PluginContentDetail;
    final chapters = results[1] as PluginChaptersResult;
    final summary = detail.summary;
    final kind = _contentKind(item.kind);
    if (summary.contentKind != kind) throw StateError('The refreshed content kind does not match the shelf item.');

    await _syncCatalog(item, chapters);
    await _library.bookshelf.addFromSource(
      BookshelfAddRequest(
        title: summary.title.isEmpty ? item.title : summary.title,
        author: summary.author ?? item.author,
        kind: item.kind,
        pluginId: source.pluginId,
        pluginVersion: source.pluginVersion,
        remoteContentId: source.remoteContentId,
        coverUrl: summary.coverUrl ?? item.coverUrl,
        sourceName: detail.sourceName.isEmpty ? item.sourceName : detail.sourceName,
        sourceUrl: detail.catalogUrl ?? summary.url ?? item.sourceUrl,
        description: summary.description,
        language: summary.language,
        accessCode: summary.access.code,
        wordCount: summary.wordCount,
        chapterCount: summary.chapterCount ?? chapters.items.length,
        publishedAt: summary.publishedAt,
        updatedAt: summary.updatedAt,
        statusLabel: _statusLabel(summary.status),
        latestChapterId: summary.latestChapter?.id,
        latestChapterTitle: summary.latestChapter?.title,
        latestChapterUrl: summary.latestChapter?.url,
        latestChapterUpdatedAt: summary.latestChapter?.updatedAt,
        categories: summary.categories,
        tags: summary.tags,
        attributes: <LibraryItemAttribute>[
          for (final attribute in summary.attributes)
            LibraryItemAttribute(key: attribute.key, label: attribute.label, value: attribute.value),
        ],
        sourceDetail: encodePersistedSourceDetail(detail),
        labels: <String>[...summary.categories, ...summary.tags, for (final attribute in summary.attributes) attribute.value],
      ),
    );
    final coverUrls = <Uri>{
      if (item.coverUrl case final Uri oldCover) oldCover,
      if (summary.coverUrl case final Uri refreshedCover) refreshedCover,
    };
    await Future.wait<void>(<Future<void>>[
      _library.bookshelf.removeCover(item.id),
      for (final coverUrl in coverUrls)
        _library.covers.remove(
          CoverKey(
            pluginId: source.pluginId,
            pluginVersion: source.pluginVersion,
            remoteContentId: source.remoteContentId,
            coverUrl: coverUrl,
          ),
        ),
    ]);
  }

  Future<void> _syncCatalog(LibraryItem item, PluginChaptersResult chapters) => switch (item.kind) {
    ContentKind.novel => _library.syncNovelCatalog(
      itemId: item.id,
      chapters: <SourceNovelCatalogChapter>[
        for (final chapter in chapters.items)
          SourceNovelCatalogChapter(
            remoteIdentity: chapter.id,
            title: chapter.title,
            index: chapter.order,
            wordCount: chapter.wordCount,
            chapterUrl: chapter.url,
          ),
      ],
    ),
    ContentKind.manga => _library.syncMangaCatalog(
      itemId: item.id,
      chapters: <MangaChapterDescriptor>[
        for (final chapter in chapters.items)
          MangaChapterDescriptor(
            remoteIdentity: chapter.id,
            title: chapter.title,
            index: chapter.order,
            pages: const <MangaPageDescriptor>[],
          ),
      ],
    ),
    // Media catalogs are session-owned because their playable resources may
    // contain short-lived proxy state. The detail/player refreshes them from
    // the source instead of persisting a stale playback catalog.
    ContentKind.audio || ContentKind.video => Future<void>.value(),
  }.then<void>((_) {});

  PluginContentKind _contentKind(ContentKind kind) => switch (kind) {
    ContentKind.audio => PluginContentKind.audio,
    ContentKind.novel => PluginContentKind.novel,
    ContentKind.manga => PluginContentKind.manga,
    ContentKind.video => PluginContentKind.video,
  };

  String? _statusLabel(PluginContentStatus status) => switch (status) {
    PluginContentStatus.ongoing => '连载',
    PluginContentStatus.completed => '已完结',
    PluginContentStatus.hiatus => '暂停更新',
    PluginContentStatus.unknown => null,
  };
}
