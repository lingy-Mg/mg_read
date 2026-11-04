/// Adapts generation-pinned Content Library document leases to the reader APIs.
///
/// It owns exactly one local session lease and never opens paths or performs
/// network access. The entry transition releases the source after the route.
/// Text presentation omits duplicate headings and blank-line blocks without
/// changing stored IDs. A 32-chapter LRU remaps legacy progress/bookmark anchors
/// to retained paragraphs; all anchor maps are released with the session.
library;

import 'dart:collection';

import 'package:novel_reader_ui/novel_reader_ui.dart';

import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/reader/application/library_reader_launcher.dart';
import 'package:mg_read/features/reader/application/reader_launch_failure.dart';
import 'package:mg_read/features/reader/application/reader_launch_request.dart';
import 'package:mg_read/features/reader/data/content_library_text_reader_state_store.dart';
import 'package:mg_read/features/reader/data/content_library_local_comic_reader.dart';

/// Opens a local TXT or EPUB item through a generation-pinned library lease.
final class ContentLibraryLocalReader implements LibraryReaderLauncher {
  const ContentLibraryLocalReader(this._library, [this._settings]);

  final ContentLibrary _library;
  final AppSettingsManager? _settings;

  @override
  Future<ReaderLaunchRequest> launch(String id) async {
    final itemId = LibraryItemId(id);
    final session = await _library.openLocalDocumentSession(itemId);
    if (session == null) {
      final item = await _library.getLibraryItem(itemId);
      final reason = item == null ? ReaderLaunchFailureReason.shelfItemMissing : ReaderLaunchFailureReason.unsupportedContentKind;
      throw ReaderLaunchFailure(reason: reason, error: AppError.fromUnknown(StateError('Local document is unavailable.')));
    }
    try {
      final readingKind = session.readingKind;
      if (readingKind == null) {
        throw ReaderLaunchFailure(
          reason: ReaderLaunchFailureReason.localReparseRequired,
          error: AppError.fromUnknown(const LocalDocumentException('epub_reparse_required')),
        );
      }
      final cover = await session.readCover();
      if (readingKind == LocalDocumentReadingKind.comic) {
        return createLocalComicReaderRequest(session, _library, _settings, cover);
      }
      final durable = await _library.loadProgress(itemId);
      final initialProgress = durable is LibraryReadingProgress ? durable : null;
      final store = ContentLibraryTextReaderStateStore(
        _library,
        itemId: itemId,
        settings: _settings,
        localGeneration: session.generation,
        initialProgress: initialProgress,
        progressAlreadyLoaded: true,
      );
      final source = _ContentLibraryLocalDocumentSource(session);
      final observer = _LocalDocumentObserver(store);
      final int warmBytes = session.chapterAt(0)?.wordCount.clamp(0, 1 << 18).toInt() ?? 0;
      final textStateStore = _LocalTextReaderStateStore(store, source);
      final progress = await textStateStore.loadProgress(id);
      var index = progress?.chapterIndex ?? 0;
      if (progress != null) {
        final byId = session.chapterById(progress.chapterId);
        if (byId != null) index = byId.index;
      }
      index = index.clamp(0, session.chapterCount - 1);
      final entry = (await source.loadChapterAtIndex(id, index));
      final content = await source.loadChapterContent(id, entry.id);
      return NovelReaderLaunchRequest(
        bookId: id,
        dataSource: source,
        stateStore: textStateStore,
        seed: ReaderSessionSeed(
          book: await source.loadBookInfo(id),
          initialChapter: entry,
          initialContent: content,
          catalogTotal: session.chapterCount,
        ),
        observer: observer,
        entryCoverBytes: cover,
        estimatedWarmBytes: warmBytes * 2,
        preparationKind: ReaderLaunchPreparationKind.persistent,
      );
    } on Object catch (error) {
      await session.close();
      throw ReaderLaunchFailure.fromError(error);
    }
  }
}

final class _ContentLibraryLocalDocumentSource implements TextReaderDataSource, DisposableReaderDataSource {
  static const int _maxTextAnchorCacheChapters = 32;

  _ContentLibraryLocalDocumentSource(this._session);

  final LocalDocumentReadingSession _session;
  Future<void>? _disposing;
  final LinkedHashMap<String, Set<String>> _textParagraphIds = LinkedHashMap<String, Set<String>>();
  final LinkedHashMap<String, Map<String, _TxtParagraphTarget>> _removedTextAnchors =
      LinkedHashMap<String, Map<String, _TxtParagraphTarget>>();
  final LinkedHashMap<String, Set<String>> _headingAnchorsAtSegmentEnd = LinkedHashMap<String, Set<String>>();

  @override
  Future<ReaderBookInfo> loadBookInfo(String bookId) async {
    _requireBook(bookId);
    final item = _session.item;
    return ReaderBookInfo(
      id: item.id.value,
      title: item.title,
      author: item.author,
      description: item.description,
      sourceName: '本地文档',
      wordCount: item.wordCount,
      chapterCount: _session.logicalChapterCount,
      statusLabel: item.statusLabel,
      latestChapterTitle: item.latestChapterTitle,
      labels: item.labels,
      sourceKind: ReaderBookSourceKind.local,
    );
  }

  @override
  Future<ChapterCatalogPage> loadChapterCatalog(String bookId, {String? cursor, int pageSize = 100}) async {
    _requireBook(bookId);
    final after = cursor == null ? -1 : int.tryParse(cursor);
    if (cursor != null && after == null) {
      throw ArgumentError.value(cursor, 'cursor', 'Invalid local chapter cursor.');
    }
    final chapters = _session.chapters(afterIndex: after ?? -1, limit: pageSize);
    final hasMore = chapters.isNotEmpty && chapters.last.index + 1 < _session.chapterCount;
    return ChapterCatalogPage(
      items: [
        for (final chapter in chapters)
          ReaderChapterInfo(
            id: chapter.id,
            title: chapter.title,
            index: chapter.index,
            availability: ReaderChapterAvailability.downloaded,
            wordCount: chapter.wordCount,
            isContinuation: _session.isChapterContinuation(chapter.id),
          ),
      ],
      total: _session.chapterCount,
      hasMore: hasMore,
      nextCursor: hasMore ? '${chapters.last.index}' : null,
    );
  }

  @override
  Future<ReaderChapterInfo> loadChapterAtIndex(String bookId, int index) async {
    _requireBook(bookId);
    final chapter = _session.chapterAt(index);
    if (chapter == null) throw RangeError.index(index, _session.chapters());
    return ReaderChapterInfo(
      id: chapter.id,
      title: chapter.title,
      index: chapter.index,
      availability: ReaderChapterAvailability.downloaded,
      wordCount: chapter.wordCount,
      isContinuation: _session.isChapterContinuation(chapter.id),
    );
  }

  @override
  Future<TextChapterContent> loadChapterContent(String bookId, String chapterId) async {
    _requireBook(bookId);
    final raw = await _session.readChapter(chapterId);
    final blocks = raw['blocks'] as List? ?? const [];
    final title = raw['title'] as String? ?? _session.chapterById(chapterId)?.title ?? '';
    final retained = <(int, TextParagraph)>[];
    final removed = <(int, String)>[];
    var sawHeading = false;
    for (var index = 0; index < blocks.length; index++) {
      final block = blocks[index];
      if (block is! Map) continue;
      final id = block['id'] as String? ?? '';
      if (id.isEmpty) continue;
      final type = block['type'] as String? ?? 'paragraph';
      final text = _withoutOneLineEnding(block['text'] as String? ?? '');
      final duplicateFirstHeading = type == 'heading' && !sawHeading && text.trim() == title.trim();
      if (type == 'heading') sawHeading = true;
      if (duplicateFirstHeading || text.trim().isEmpty) {
        removed.add((index, id));
      } else {
        retained.add((index, TextParagraph(id: id, text: text)));
      }
    }
    final paragraphs = retained.map((entry) => entry.$2).toList(growable: false);
    final knownIds = paragraphs.map((paragraph) => paragraph.id).toSet();
    final anchorTargets = <String, _TxtParagraphTarget>{};
    final headingAnchorsAtEnd = <String>{};
    for (final (removedIndex, removedId) in removed) {
      final next = retained.where((entry) => entry.$1 > removedIndex).firstOrNull;
      final previous = retained.where((entry) => entry.$1 < removedIndex).lastOrNull;
      final target = next ?? previous;
      if (target != null) {
        anchorTargets[removedId] = _TxtParagraphTarget(
          chapterId: chapterId,
          chapterIndex: _session.chapterById(chapterId)?.index ?? 0,
          paragraphId: target.$2.id,
        );
      }
      if (next == null && target != null && (blocks[removedIndex] as Map)['type'] == 'heading') {
        headingAnchorsAtEnd.add(removedId);
      }
    }
    _cacheTextAnchorMaps(chapterId, knownIds, anchorTargets, headingAnchorsAtEnd);
    return TextChapterContent(chapterId: raw['chapterId'] as String? ?? chapterId, title: title, paragraphs: paragraphs);
  }

  Future<_TxtParagraphTarget?> resolveTextAnchor(String chapterId, String paragraphId) async {
    if (!_textParagraphIds.containsKey(chapterId)) {
      await loadChapterContent(_session.item.id.value, chapterId);
    }
    _touchTextAnchorMaps(chapterId);
    if (_textParagraphIds[chapterId]?.contains(paragraphId) == true) {
      final chapter = _session.chapterById(chapterId);
      return _TxtParagraphTarget(chapterId: chapterId, chapterIndex: chapter?.index ?? 0, paragraphId: paragraphId);
    }
    final fallback = _removedTextAnchors[chapterId]?[paragraphId];
    if (_headingAnchorsAtSegmentEnd[chapterId]?.contains(paragraphId) != true) {
      return fallback;
    }
    final chapter = _session.chapterById(chapterId);
    if (chapter == null) return fallback;
    for (var index = chapter.index + 1; index < _session.chapterCount; index++) {
      final nextChapter = _session.chapterAt(index);
      if (nextChapter == null) break;
      final content = await loadChapterContent(_session.item.id.value, nextChapter.id);
      final first = content.paragraphs.firstOrNull;
      if (first != null) {
        return _TxtParagraphTarget(chapterId: nextChapter.id, chapterIndex: nextChapter.index, paragraphId: first.id);
      }
    }
    return fallback;
  }

  void _cacheTextAnchorMaps(
    String chapterId,
    Set<String> paragraphIds,
    Map<String, _TxtParagraphTarget> removedAnchors,
    Set<String> headingAnchorsAtEnd,
  ) {
    _textParagraphIds.remove(chapterId);
    _removedTextAnchors.remove(chapterId);
    _headingAnchorsAtSegmentEnd.remove(chapterId);
    _textParagraphIds[chapterId] = paragraphIds;
    _removedTextAnchors[chapterId] = removedAnchors;
    _headingAnchorsAtSegmentEnd[chapterId] = headingAnchorsAtEnd;
    while (_textParagraphIds.length > _maxTextAnchorCacheChapters) {
      final oldest = _textParagraphIds.keys.first;
      _textParagraphIds.remove(oldest);
      _removedTextAnchors.remove(oldest);
      _headingAnchorsAtSegmentEnd.remove(oldest);
    }
  }

  void _touchTextAnchorMaps(String chapterId) {
    final paragraphIds = _textParagraphIds.remove(chapterId);
    if (paragraphIds == null) return;
    final removedAnchors = _removedTextAnchors.remove(chapterId) ?? {};
    final headingAnchorsAtEnd = _headingAnchorsAtSegmentEnd.remove(chapterId) ?? {};
    _textParagraphIds[chapterId] = paragraphIds;
    _removedTextAnchors[chapterId] = removedAnchors;
    _headingAnchorsAtSegmentEnd[chapterId] = headingAnchorsAtEnd;
  }

  void _clearTextAnchorMaps() {
    _textParagraphIds.clear();
    _removedTextAnchors.clear();
    _headingAnchorsAtSegmentEnd.clear();
  }

  String _withoutOneLineEnding(String text) {
    if (text.endsWith('\r\n')) return text.substring(0, text.length - 2);
    if (text.endsWith('\n') || text.endsWith('\r')) {
      return text.substring(0, text.length - 1);
    }
    return text;
  }

  void _requireBook(String bookId) {
    if (bookId != _session.item.id.value) {
      throw ArgumentError.value(bookId, 'bookId', 'Unexpected local book ID.');
    }
  }

  @override
  Future<void> dispose() => _disposing ??= _disposeSession();

  Future<void> _disposeSession() async {
    _clearTextAnchorMaps();
    await _session.close();
  }
}

final class _TxtParagraphTarget {
  const _TxtParagraphTarget({required this.chapterId, required this.chapterIndex, required this.paragraphId});

  final String chapterId;
  final int chapterIndex;
  final String paragraphId;
}

final class _LocalTextReaderStateStore implements TextReaderStateStore {
  const _LocalTextReaderStateStore(this._inner, this._source);

  final TextReaderStateStore _inner;
  final _ContentLibraryLocalDocumentSource _source;

  @override
  Future<ReaderProgress?> loadProgress(String bookId) async {
    final progress = await _inner.loadProgress(bookId);
    if (progress == null) return null;
    final target = await _source.resolveTextAnchor(progress.chapterId, progress.paragraphId);
    if (target == null || (target.chapterId == progress.chapterId && target.paragraphId == progress.paragraphId)) {
      return progress;
    }
    return progress.copyWith(
      chapterId: target.chapterId,
      chapterIndex: target.chapterIndex,
      paragraphId: target.paragraphId,
      characterOffset: 0,
    );
  }

  @override
  Future<List<ReaderBookmark>> loadBookmarks(String bookId) async {
    final bookmarks = await _inner.loadBookmarks(bookId);
    final result = <ReaderBookmark>[];
    for (final bookmark in bookmarks) {
      final target = await _source.resolveTextAnchor(bookmark.chapterId, bookmark.paragraphId);
      if (target == null || (target.chapterId == bookmark.chapterId && target.paragraphId == bookmark.paragraphId)) {
        result.add(bookmark);
        continue;
      }
      result.add(
        ReaderBookmark(
          id: bookmark.id,
          bookId: bookmark.bookId,
          chapterId: target.chapterId,
          paragraphId: target.paragraphId,
          characterOffset: 0,
          chapterTitle: bookmark.chapterTitle,
          excerpt: bookmark.excerpt,
          createdAt: bookmark.createdAt,
        ),
      );
    }
    return result;
  }

  @override
  Future<void> saveProgress(String bookId, ReaderProgress progress) => _inner.saveProgress(bookId, progress);

  @override
  Future<TextReaderPreferences?> loadPreferences() => _inner.loadPreferences();

  @override
  Future<void> savePreferences(TextReaderPreferences preferences) => _inner.savePreferences(preferences);

  @override
  Future<void> addBookmark(ReaderBookmark bookmark) => _inner.addBookmark(bookmark);

  @override
  Future<void> removeBookmark(String bookId, String bookmarkId) => _inner.removeBookmark(bookId, bookmarkId);
}

final class _LocalDocumentObserver extends ReaderObserver {
  _LocalDocumentObserver(this._store);
  final ContentLibraryTextReaderStateStore _store;

  @override
  Future<void> onSessionStarted(String bookId) async {
    _store.startSession();
  }

  @override
  Future<void> onSessionEnded(String bookId, ReaderProgress? progress) async {
    _store.finishSession();
  }

  @override
  Future<void> onLifecycleChanged(ReaderLifecycleState state, ReaderProgress? progress) async {
    _store.onLifecycleChanged(state);
  }
}
