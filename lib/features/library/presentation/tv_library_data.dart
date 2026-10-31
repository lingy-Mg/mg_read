/// Immutable TV projection of the existing library; no extra store or IO.
/// Movie/series filters use explicit source metadata, never episode counts.
/// Unknown classifications remain visible in All. Resume uses durable history.
library;

import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/library/domain/library_item_summary.dart';
import 'library_book_list_view_data.dart';
import 'library_home_view_data.dart';

enum TvLibraryFilter { all, movies, series, reading }

class TvLibraryEntry {
  const TvLibraryEntry(this.book, this.summary);
  final LibraryBookListItemViewData book;
  final LibraryItemSummary? summary;

  bool get isVideo => book.contentKind == ContentKind.video;
  bool get hasHistory => summary?.lastReadAtUtc != null;

  TvLibraryFilter? get category {
    if (!isVideo) return TvLibraryFilter.reading;
    final labels = <String>[
      ...?summary?.categories,
      ...?summary?.tags,
      for (final attribute in summary?.attributes ?? const <LibraryItemSummaryAttribute>[])
        if (const {'type', 'category', 'genre', '类型', '分类'}.contains(attribute.key.toLowerCase()) ||
            const {'类型', '分类'}.contains(attribute.label))
          attribute.value,
    ].map((value) => value.trim().toLowerCase()).toSet();
    if (labels.any(
      (value) => const {'电视剧', '剧集', '连续剧', '国产剧', '欧美剧', '日韩剧', '韩剧', '日剧', '美剧', '港剧', '台剧', 'series', 'tv'}.contains(value),
    )) {
      return TvLibraryFilter.series;
    }
    if (labels.any((value) => const {'电影', '动作片', '喜剧片', '爱情片', '科幻片', '恐怖片', '剧情片', 'movie', 'film'}.contains(value))) {
      return TvLibraryFilter.movies;
    }
    return null;
  }

  String get kindLabel => switch (category) {
    TvLibraryFilter.movies => '电影',
    TvLibraryFilter.series => '剧集',
    TvLibraryFilter.reading => switch (book.contentKind) {
      ContentKind.audio => '音频',
      ContentKind.manga => '漫画',
      _ => '小说',
    },
    _ => '影视',
  };

  String get progressLabel => hasHistory ? (isVideo ? '上次观看' : '上次阅读') : (isVideo ? '尚未观看' : '尚未阅读');
}

class TvLibraryData {
  TvLibraryData(LibraryHomeViewData data, Iterable<LibraryItemSummary> summaries) {
    final byId = {for (final item in summaries) item.id: item};
    entries = List.unmodifiable(data.books.map((book) => TvLibraryEntry(book, byId[book.id])));
  }
  late final List<TvLibraryEntry> entries;

  List<TvLibraryEntry> filtered(TvLibraryFilter filter) => entries
      .where(
        (entry) => switch (filter) {
          TvLibraryFilter.all => entry.isVideo,
          _ => entry.category == filter,
        },
      )
      .toList(growable: false);

  TvLibraryEntry? get resume {
    final watched = entries.where((entry) => entry.isVideo && entry.hasHistory).toList()
      ..sort((a, b) => b.summary!.lastReadAtUtc!.compareTo(a.summary!.lastReadAtUtc!));
    return watched.firstOrNull;
  }
}
