import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';

import 'package:mg_read/features/reader/application/reader_launch_request.dart';

/// Loads one Runtime-owned source chapter without exposing transport to reader UI.
typedef SourceChapterContentLoader =
    Future<PluginChapterContent> Function(String chapterId);

/// Builds one non-persistent text-reader session from an already resolved source.
///
/// The adapter exists only for the discovery-to-reader trial. It holds catalog,
/// text, progress, bookmarks, and preferences in memory for the life of the
/// page. It never opens app persistence or writes a cache file.
final class TransientSourceTextReader {
  TransientSourceTextReader({
    required this.detail,
    required PluginChaptersResult catalog,
    required SourceChapterContentLoader loadChapterContent,
    List<int>? entryCoverBytes,
    String? bookId,
  }) : _entryCoverBytes = entryCoverBytes ?? detail.summary.coverBytes,
       _dataSource = _TransientSourceTextReaderDataSource(
         detail: detail,
         catalog: catalog,
         loadChapterContent: loadChapterContent,
         bookId: bookId ?? 'source:${detail.pluginId}:${detail.summary.id}',
       );

  /// Typed source metadata returned by the Runtime Facade.
  final PluginContentDetail detail;
  final List<int>? _entryCoverBytes;

  final _TransientSourceTextReaderDataSource _dataSource;

  /// Creates a launch request whose selected source chapter opens immediately.
  ReaderLaunchRequest createLaunchRequest({
    required String initialChapterId,
    ReaderObserver? observer,
    TextReaderStateStore? stateStore,
    ReaderExtensions extensions = const ReaderExtensions(),
  }) {
    final initialIndex = _dataSource.indexOf(initialChapterId);
    if (initialIndex == null) {
      throw ArgumentError.value(
        initialChapterId,
        'initialChapterId',
        'The selected source chapter is not in the catalog.',
      );
    }
    return ReaderLaunchRequest(
      bookId: _dataSource.bookId,
      entryCoverBytes: _entryCoverBytes,
      dataSource: _dataSource,
      stateStore:
          stateStore ??
          _EphemeralTextReaderStateStore(
            ReaderProgress(
              chapterId: initialChapterId,
              paragraphId: '',
              chapterIndex: initialIndex,
            ),
          ),
      observer: observer,
      extensions: extensions,
    );
  }
}

final class _TransientSourceTextReaderDataSource
    implements TextReaderDataSource {
  _TransientSourceTextReaderDataSource({
    required this.detail,
    required PluginChaptersResult catalog,
    required this._loadChapterContent,
    required this.bookId,
  }) {
    _cacheCatalog(catalog);
  }

  final PluginContentDetail detail;
  final String bookId;
  final SourceChapterContentLoader _loadChapterContent;
  late final PluginChaptersResult _catalog;
  final Map<int, PluginChapterSummary> _chapterByIndex =
      <int, PluginChapterSummary>{};
  final Map<String, int> _indexByChapterId = <String, int>{};

  @override
  Future<ReaderBookInfo> loadBookInfo(String bookId) async {
    _requireBook(bookId);
    final summary = detail.summary;
    return ReaderBookInfo(
      id: bookId,
      title: summary.title,
      author: summary.author,
      description: summary.description,
      sourceName: detail.sourceName,
      sourceUrl: detail.catalogUrl ?? summary.url,
      coverUrl: summary.coverUrl,
      wordCount: summary.wordCount,
      chapterCount: summary.chapterCount ?? detail.summary.chapterCount,
      statusLabel: _statusLabel(summary.status),
      latestChapterTitle: summary.latestChapter?.title,
      latestChapterUrl: summary.latestChapter?.url,
      labels: List<String>.unmodifiable(<String>[
        ...summary.categories,
        ...summary.tags,
        for (final attribute in summary.attributes) attribute.value,
      ]),
      sourceKind: ReaderBookSourceKind.remote,
    );
  }

  String? _statusLabel(PluginContentStatus status) => switch (status) {
    PluginContentStatus.ongoing => '连载',
    PluginContentStatus.completed => '已完结',
    PluginContentStatus.hiatus => '暂停更新',
    PluginContentStatus.unknown => null,
  };

  @override
  Future<ChapterCatalogPage> loadChapterCatalog(
    String bookId, {
    String? cursor,
    int pageSize = 100,
  }) async {
    _requireBook(bookId);
    final offset = _catalogOffset(cursor);
    final boundedPageSize = pageSize.clamp(1, 500);
    final end = (offset + boundedPageSize).clamp(0, _catalog.items.length);
    final items = _catalog.items.sublist(offset, end);
    final hasMore = end < _catalog.items.length;
    return ChapterCatalogPage(
      items: <ReaderChapterInfo>[
        for (var index = 0; index < items.length; index += 1)
          _toReaderChapter(items[index], offset + index),
      ],
      total: _catalog.items.length,
      hasMore: hasMore,
      nextCursor: hasMore ? 'catalog-offset:$end' : null,
    );
  }

  @override
  Future<ReaderChapterInfo> loadChapterAtIndex(String bookId, int index) async {
    _requireBook(bookId);
    final chapter = _chapterByIndex[index];
    if (chapter == null) {
      throw RangeError.index(index, _chapterByIndex, 'index');
    }
    return _toReaderChapter(chapter, index);
  }

  @override
  Future<TextChapterContent> loadChapterContent(
    String bookId,
    String chapterId,
  ) async {
    _requireBook(bookId);
    final chapter = _chapterByIndex[_indexByChapterId[chapterId]];
    if (chapter == null) throw ArgumentError.value(chapterId, 'chapterId');
    final content = await _loadChapterContent(chapterId);
    if (content.contentKind != PluginContentKind.novel ||
        content.text == null) {
      throw StateError('The source chapter is not a text-reader chapter.');
    }
    return TextChapterContent(
      chapterId: content.chapterId,
      title: content.title ?? chapter.title,
      paragraphs: _paragraphs(content.chapterId, content.text!),
      contentVersion: content.updatedAt?.toUtc().toIso8601String(),
      chapterUrl: chapter.url?.toString(),
    );
  }

  int? indexOf(String chapterId) => _indexByChapterId[chapterId];

  void _cacheCatalog(PluginChaptersResult catalog) {
    _catalog = catalog;
    for (var index = 0; index < catalog.items.length; index += 1) {
      final absoluteIndex = index;
      final chapter = catalog.items[index];
      if (_chapterByIndex.containsKey(absoluteIndex) ||
          _indexByChapterId.containsKey(chapter.id)) {
        throw StateError(
          'Source catalog contains duplicate chapter positions.',
        );
      }
      _chapterByIndex[absoluteIndex] = chapter;
      _indexByChapterId[chapter.id] = absoluteIndex;
    }
  }

  int _catalogOffset(String? cursor) {
    if (cursor == null) return 0;
    final match = RegExp(r'^catalog-offset:(\d+)$').firstMatch(cursor);
    final offset = int.tryParse(match?.group(1) ?? '');
    if (offset == null || offset <= 0 || offset >= _catalog.items.length) {
      throw StateError('Unknown source catalog cursor.');
    }
    return offset;
  }

  ReaderChapterInfo _toReaderChapter(PluginChapterSummary chapter, int index) {
    return ReaderChapterInfo(
      id: chapter.id,
      title: chapter.title,
      index: index,
      availability: ReaderChapterAvailability.notDownloaded,
      wordCount: chapter.wordCount,
    );
  }

  void _requireBook(String bookId) {
    if (bookId != this.bookId) {
      throw ArgumentError.value(bookId, 'bookId');
    }
  }
}

List<TextParagraph> _paragraphs(String chapterId, String text) {
  final paragraphs = <TextParagraph>[];
  for (final line in text.split(RegExp(r'\r?\n\s*\r?\n'))) {
    final value = line.trim();
    if (value.isEmpty) continue;
    paragraphs.add(
      TextParagraph(
        id: '$chapterId:paragraph:${paragraphs.length}',
        text: value,
      ),
    );
  }
  return paragraphs.isEmpty
      ? <TextParagraph>[TextParagraph(id: '$chapterId:paragraph:0', text: '')]
      : paragraphs;
}

/// A reader state store with no backing store beyond the current route.
final class _EphemeralTextReaderStateStore implements TextReaderStateStore {
  _EphemeralTextReaderStateStore(this._progress);

  ReaderProgress? _progress;
  TextReaderPreferences? _preferences;
  final Map<String, ReaderBookmark> _bookmarks = <String, ReaderBookmark>{};

  @override
  Future<ReaderProgress?> loadProgress(String bookId) async => _progress;

  @override
  Future<void> saveProgress(String bookId, ReaderProgress progress) async {
    _progress = progress;
  }

  @override
  Future<TextReaderPreferences?> loadPreferences() async => _preferences;

  @override
  Future<void> savePreferences(TextReaderPreferences preferences) async {
    _preferences = preferences;
  }

  @override
  Future<List<ReaderBookmark>> loadBookmarks(String bookId) async {
    return List<ReaderBookmark>.unmodifiable(_bookmarks.values);
  }

  @override
  Future<void> addBookmark(ReaderBookmark bookmark) async {
    _bookmarks[bookmark.id] = bookmark;
  }

  @override
  Future<void> removeBookmark(String bookId, String bookmarkId) async {
    _bookmarks.remove(bookmarkId);
  }
}
