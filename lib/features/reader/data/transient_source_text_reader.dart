import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';

import 'package:mg_read/features/reader/application/reader_launch_request.dart';

/// Loads one opaque Runtime-owned page of a source chapter catalog.
typedef SourceChapterPageLoader =
    Future<PluginChaptersResult> Function({String? cursor, int pageSize});

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
    required PluginChaptersResult firstCatalogPage,
    required SourceChapterPageLoader loadChapterPage,
    required SourceChapterContentLoader loadChapterContent,
    String? bookId,
  }) : _dataSource = _TransientSourceTextReaderDataSource(
         detail: detail,
         firstCatalogPage: firstCatalogPage,
         loadChapterPage: loadChapterPage,
         loadChapterContent: loadChapterContent,
         bookId: bookId ?? 'source:${detail.pluginId}:${detail.summary.id}',
       );

  /// Typed source metadata returned by the Runtime Facade.
  final PluginContentDetail detail;

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
        'The selected source chapter is not in the initial catalog page.',
      );
    }
    return ReaderLaunchRequest(
      bookId: _dataSource.bookId,
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
    required PluginChaptersResult firstCatalogPage,
    required this._loadChapterPage,
    required this._loadChapterContent,
    required this.bookId,
  }) {
    _cachePage(null, firstCatalogPage, offset: 0);
  }

  final PluginContentDetail detail;
  final String bookId;
  final SourceChapterPageLoader _loadChapterPage;
  final SourceChapterContentLoader _loadChapterContent;
  final Map<String?, PluginChaptersResult> _catalogPages =
      <String?, PluginChaptersResult>{};
  final Map<String?, int> _pageOffsets = <String?, int>{};
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
    final page = await _pageFor(cursor, pageSize: pageSize);
    final offset = _pageOffsets[cursor];
    if (offset == null) throw StateError('Unknown source catalog cursor.');
    final total = page.totalCount ?? offset + page.items.length;
    final hasMore = page.totalCount != null && page.nextCursor != null;
    return ChapterCatalogPage(
      items: <ReaderChapterInfo>[
        for (var index = 0; index < page.items.length; index += 1)
          _toReaderChapter(page.items[index], offset + index),
      ],
      total: total,
      hasMore: hasMore,
      nextCursor: hasMore ? page.nextCursor : null,
    );
  }

  @override
  Future<ReaderChapterInfo> loadChapterAtIndex(String bookId, int index) async {
    _requireBook(bookId);
    while (!_chapterByIndex.containsKey(index)) {
      final page = _catalogPages.values.last;
      final cursor = page.nextCursor;
      if (cursor == null || page.totalCount == null) {
        throw RangeError.index(index, _chapterByIndex, 'index');
      }
      await _pageFor(cursor, pageSize: 100);
    }
    return _toReaderChapter(_chapterByIndex[index]!, index);
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

  Future<PluginChaptersResult> _pageFor(
    String? cursor, {
    required int pageSize,
  }) async {
    final cached = _catalogPages[cursor];
    if (cached != null) return cached;
    final offset = _pageOffsets[cursor];
    if (offset == null) throw StateError('Unknown source catalog cursor.');
    final page = await _loadChapterPage(cursor: cursor, pageSize: pageSize);
    _cachePage(cursor, page, offset: offset);
    return page;
  }

  void _cachePage(
    String? cursor,
    PluginChaptersResult page, {
    required int offset,
  }) {
    _catalogPages[cursor] = page;
    _pageOffsets[cursor] = offset;
    for (var index = 0; index < page.items.length; index += 1) {
      final absoluteIndex = offset + index;
      final chapter = page.items[index];
      if (_chapterByIndex.containsKey(absoluteIndex) ||
          _indexByChapterId.containsKey(chapter.id)) {
        throw StateError(
          'Source catalog contains duplicate chapter positions.',
        );
      }
      _chapterByIndex[absoluteIndex] = chapter;
      _indexByChapterId[chapter.id] = absoluteIndex;
    }
    if (page.nextCursor != null) {
      _pageOffsets[page.nextCursor] = offset + page.items.length;
    }
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
