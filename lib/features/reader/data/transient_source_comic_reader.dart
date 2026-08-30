/// Route-lifetime comic reader adapter for discovery/detail previews.
///
/// The adapter keeps only the source catalog and a three-entry manifest LRU in
/// memory. It does not write the bookshelf, Content Library, progress,
/// bookmarks, or image bytes to disk; shelf reading uses the library adapter.
library;

import 'dart:typed_data';

import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';

import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/reader/data/bounded_reader_session_cache.dart';
import 'package:mg_read/features/reader/data/content_library_source_comic_reader.dart';

/// Serves one discovery/detail comic session without requiring a shelf item.
final class TransientSourceComicReaderDataSource implements ComicReaderDataSource {
  TransientSourceComicReaderDataSource({required this.detail, required this.catalog, required this.gateway, ComicImageFetcher? fetcher})
    : fetcher = fetcher ?? fetchComicImage {
    _chapters = List<PluginChapterSummary>.unmodifiable(catalog.items);
  }

  final PluginContentDetail detail;
  final PluginChaptersResult catalog;
  final SourceContentGateway gateway;
  final ComicImageFetcher fetcher;
  late final List<PluginChapterSummary> _chapters;
  final BoundedReaderSessionCache<String, ComicChapterContent> _contents = BoundedReaderSessionCache<String, ComicChapterContent>(
    maxEntries: 3,
  );

  @override
  Future<ComicBookInfo> loadBookInfo(String bookId) async {
    _checkBook(bookId);
    final summary = detail.summary;
    return ComicBookInfo(
      id: summary.id,
      title: summary.title,
      author: summary.author,
      description: summary.description,
      sourceName: detail.sourceName,
      sourceKind: ReaderBookSourceKind.remote,
    );
  }

  @override
  Future<ComicChapterCatalogPage> loadChapterCatalog(String bookId, {String? cursor, int pageSize = 50}) async {
    _checkBook(bookId);
    final start = _cursorOffset(cursor);
    final end = (start + pageSize.clamp(1, 500)).clamp(0, _chapters.length);
    final items = <ComicChapterInfo>[for (var index = start; index < end; index += 1) _chapterInfo(index)];
    return ComicChapterCatalogPage(
      items: items,
      total: _chapters.length,
      hasMore: end < _chapters.length,
      nextCursor: end < _chapters.length ? 'transient:$end' : null,
    );
  }

  @override
  Future<ComicChapterInfo> loadChapterAtIndex(String bookId, int index) async {
    _checkBook(bookId);
    if (index < 0 || index >= _chapters.length) {
      throw RangeError.index(index, _chapters);
    }
    return _chapterInfo(index);
  }

  @override
  Future<ComicChapterContent> loadChapterContent(String bookId, String chapterId) async {
    _checkBook(bookId);
    final cached = _contents[chapterId];
    if (cached != null) return cached;
    final PluginChapterContent remote;
    try {
      remote = await gateway.getContent(
        pluginId: detail.pluginId,
        id: detail.summary.id,
        chapterId: chapterId,
      );
    } on ReaderFailure {
      rethrow;
    } on Object catch (error) {
      throw ReaderFailure(
        ReaderFailureKind.data,
        '漫画章节暂时无法加载，请检查数据源或网络后重试。',
        code: 'source_comic_chapter_load_failed',
        location: '请求漫画章节内容',
        cause: error,
      );
    }
    if (remote.contentKind != PluginContentKind.manga || remote.chapterId != chapterId || remote.pages.isEmpty) {
      throw const ReaderFailure(
        ReaderFailureKind.data,
        '数据源没有返回有效的漫画图片清单。',
        code: 'source_comic_manifest_invalid',
        location: '解析漫画章节图片清单',
      );
    }
    final version = remote.updatedAt?.toUtc().millisecondsSinceEpoch ?? 1;
    final content = ComicChapterContent(
      chapterId: chapterId,
      title: remote.title ?? _chapterById(chapterId).title,
      contentVersion: '$version',
      images: [
        for (final page in remote.pages)
          ComicImageInfo(
            id: page.id,
            index: page.index,
            width: page.width,
            height: page.height,
            contentType: page.mimeType,
            contentVersion: '$version',
          ),
      ],
    );
    _validateImages(content);
    _contents[chapterId] = content;
    return content;
  }

  @override
  Future<Uint8List> loadImageBytes(String bookId, String chapterId, String imageId) async {
    _checkBook(bookId);
    final content = _contents[chapterId] ?? await loadChapterContent(bookId, chapterId);
    final image = content.images.firstWhere(
      (candidate) => candidate.id == imageId,
      orElse: () => throw StateError('Source comic image is not in the chapter.'),
    );
    final PluginChapterContent remote;
    try {
      remote = await gateway.getContent(
        pluginId: detail.pluginId,
        id: detail.summary.id,
        chapterId: chapterId,
      );
    } on Object catch (error) {
      throw ReaderFailure(
        ReaderFailureKind.image,
        '漫画图片清单暂时无法刷新，请稍后重试。',
        code: 'source_comic_image_manifest_refresh_failed',
        location: '刷新漫画图片清单',
        cause: error,
      );
    }
    final page = remote.pages.firstWhere(
      (candidate) => candidate.id == image.id,
      orElse: () => throw StateError('Source comic image is not in the refreshed chapter.'),
    );
    try {
      return await fetcher(page.url);
    } on Object catch (error) {
      throw ReaderFailure(
        ReaderFailureKind.image,
        '漫画图片暂时无法加载，请检查网络后重试。',
        code: 'source_comic_image_load_failed',
        location: '下载漫画图片',
        cause: error,
      );
    }
  }

  ComicChapterInfo _chapterInfo(int index) {
    final chapter = _chapters[index];
    return ComicChapterInfo(id: chapter.id, title: chapter.title, index: index, availability: ReaderChapterAvailability.notDownloaded);
  }

  PluginChapterSummary _chapterById(String chapterId) =>
      _chapters.firstWhere((chapter) => chapter.id == chapterId, orElse: () => throw ArgumentError.value(chapterId, 'chapterId'));

  int _cursorOffset(String? cursor) {
    if (cursor == null) return 0;
    final match = RegExp(r'^transient:(\d+)$').firstMatch(cursor);
    final offset = int.tryParse(match?.group(1) ?? '');
    if (offset == null || offset < 0 || offset > _chapters.length) {
      throw StateError('Transient comic catalog cursor is invalid.');
    }
    return offset;
  }

  void _validateImages(ComicChapterContent content) {
    final ids = <String>{};
    for (var index = 0; index < content.images.length; index += 1) {
      final image = content.images[index];
      if (image.id.trim().isEmpty || !ids.add(image.id) || image.index != index) {
        throw StateError('Source comic image manifest is invalid.');
      }
    }
  }

  void _checkBook(String bookId) {
    if (bookId != detail.summary.id) throw ArgumentError.value(bookId, 'bookId');
  }
}

/// Route-lifetime state for an unsaved discovery comic session.
final class TransientComicReaderStateStore implements ComicReaderStateStore {
  ComicReaderProgress? _progress;
  ComicReaderPreferences? _preferences;

  @override
  Future<ComicReaderProgress?> loadProgress(String bookId) async => _progress;

  @override
  Future<void> saveProgress(String bookId, ComicReaderProgress progress) async => _progress = progress;

  @override
  Future<ComicReaderPreferences?> loadPreferences() async => _preferences;

  @override
  Future<void> savePreferences(ComicReaderPreferences preferences) async => _preferences = preferences;

  @override
  Future<List<ComicReaderBookmark>> loadBookmarks(String bookId) async => const <ComicReaderBookmark>[];

  @override
  Future<void> addBookmark(ComicReaderBookmark bookmark) async {}

  @override
  Future<void> removeBookmark(String bookId, String bookmarkId) async {}
}
