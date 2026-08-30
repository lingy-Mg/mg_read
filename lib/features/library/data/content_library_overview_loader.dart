/// 书架概览加载器。
///
/// 职责：
/// - 从 Content Library 读取书架条目和小说、漫画、音频、视频进度。
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
    final page = await _library.listLibrary(LibraryQuery(limit: bookshelfMaxItemCount, visibility: visibility));
    final novelProgressFuture = _library.readingProgress.loadMany(
      page.items.where((item) => item.kind == ContentKind.novel).map((item) => item.id),
    );
    final mangaProgressFuture = _library.mangaState.loadProgressMany(
      page.items.where((item) => item.kind == ContentKind.manga).map((item) => item.id),
    );
    final audioProgressFuture = _library.audioProgress.loadMany(
      page.items.where((item) => item.kind == ContentKind.audio).map((item) => item.id),
    );
    final videoProgressFuture = _library.videoProgress.loadMany(
      page.items.where((item) => item.kind == ContentKind.video).map((item) => item.id),
    );
    final progressByItemId = <String, LibraryReadingProgress>{
      for (final progress in await novelProgressFuture) progress.itemId.value: progress,
    };
    final mangaProgressByItemId = <String, LibraryMangaReadingProgress>{
      for (final progress in await mangaProgressFuture) progress.itemId.value: progress,
    };
    final audioProgressByItemId = <String, LibraryAudioPlaybackProgress>{
      for (final progress in await audioProgressFuture) progress.itemId.value: progress,
    };
    final videoProgressByItemId = <String, LibraryVideoPlaybackProgress>{
      for (final progress in await videoProgressFuture) progress.itemId.value: progress,
    };
    final items = page.items.map((item) {
      final progress = switch (item.kind) {
        ContentKind.novel => _OverviewProgress.fromNovel(progressByItemId[item.id.value]),
        ContentKind.manga => _OverviewProgress.fromManga(mangaProgressByItemId[item.id.value]),
        ContentKind.audio => _OverviewProgress.fromAudio(audioProgressByItemId[item.id.value]),
        ContentKind.video => _OverviewProgress.fromVideo(videoProgressByItemId[item.id.value]),
      };
      final source = item.source;
      return LibraryItemSummary(
        id: item.id.value,
        title: item.title,
        contentKind: item.kind,
        author: item.author,
        coverUrl: item.coverUrl,
        coverPluginId: source?.pluginId,
        coverPluginVersion: source?.pluginVersion,
        coverRemoteContentId: source?.remoteContentId,
        sourceName: item.sourceName,
        sourceUrl: item.sourceUrl,
        description: item.description,
        language: item.language,
        accessCode: item.accessCode,
        wordCount: item.wordCount,
        chapterCount: item.chapterCount,
        publishedAt: item.publishedAt,
        updatedAt: item.updatedAt,
        statusLabel: item.statusLabel,
        latestChapterId: item.latestChapterId,
        latestChapterTitle: item.latestChapterTitle,
        latestChapterUrl: item.latestChapterUrl,
        latestChapterUpdatedAt: item.latestChapterUpdatedAt,
        categories: item.categories,
        tags: item.tags,
        attributes: <LibraryItemSummaryAttribute>[
          for (final attribute in item.attributes)
            LibraryItemSummaryAttribute(key: attribute.key, label: attribute.label, value: attribute.value),
        ],
        readingProgress: progress?.fraction,
        readingChapterIndex: progress?.chapterIndex,
        lastReadAtUtc: progress?.updatedAtUtc,
      );
    });
    return LibraryOverview(items: items);
  }
}

final class _OverviewProgress {
  const _OverviewProgress({required this.fraction, required this.updatedAtUtc, this.chapterIndex});

  static _OverviewProgress? fromNovel(LibraryReadingProgress? progress) => progress == null
      ? null
      : _OverviewProgress(fraction: progress.bookFraction, chapterIndex: progress.chapterIndex, updatedAtUtc: progress.updatedAtUtc);

  static _OverviewProgress? fromManga(LibraryMangaReadingProgress? progress) => progress == null
      ? null
      : _OverviewProgress(fraction: progress.bookFraction, chapterIndex: progress.chapterIndex, updatedAtUtc: progress.updatedAtUtc);

  static _OverviewProgress? fromAudio(LibraryAudioPlaybackProgress? progress) =>
      progress == null ? null : _OverviewProgress(fraction: null, updatedAtUtc: progress.updatedAtUtc);

  static _OverviewProgress? fromVideo(LibraryVideoPlaybackProgress? progress) =>
      progress == null ? null : _OverviewProgress(fraction: null, updatedAtUtc: progress.updatedAtUtc);

  final double? fraction;
  final int? chapterIndex;
  final DateTime? updatedAtUtc;
}
