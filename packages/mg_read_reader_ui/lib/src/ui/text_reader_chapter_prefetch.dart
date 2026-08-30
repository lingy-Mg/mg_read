part of 'text_reader_view.dart';

/// 阅读器相邻章节正文预取与有界正文缓存。
///
/// 职责：
/// - 复用同一章节请求并维护当前章与宿主指定数量的后续章节正文缓存。
/// - 在正文完成后通知横向布局预排调度。
///
/// 注意：
/// - 预取是 best effort；失败不得影响前台正文或语义进度。
/// - 正文完成或失败均回到相邻准备协调器，由下一真实阅读事件决定是否继续。
/// - 网络、文件和持久化仍由宿主数据源拥有。
///

extension _TextReaderChapterPrefetch on _TextReaderViewState {
  TextChapterContent? _takeCached(String id) {
    final TextChapterContent? value = _chapterCache.remove(id);
    if (value != null) _chapterCache[id] = value;
    return value;
  }

  bool _isCurrent(int generation) =>
      !_disposed && generation == _requestGeneration;

  bool _isSessionCurrent(int generation) =>
      !_disposed && generation == _sessionGeneration;

  Future<TextChapterContent> _loadChapterContent(
    TextReaderDataSource dataSource,
    String bookId,
    String chapterId, {
    bool reuseInFlight = true,
  }) async {
    final String key = '$bookId\u0000$chapterId';
    final Future<TextChapterContent>? existing = _chapterLoads[key];
    if (reuseInFlight && existing != null) return existing;
    final Future<TextChapterContent> request = dataSource.loadChapterContent(
      bookId,
      chapterId,
    );
    _chapterLoads[key] = request;
    try {
      return await request;
    } finally {
      if (identical(_chapterLoads[key], request)) _chapterLoads.remove(key);
    }
  }

  void _cacheChapter(TextChapterContent chapter) {
    _chapterCache.remove(chapter.chapterId);
    _chapterCache[chapter.chapterId] = chapter;
    _trimChapterCache();
  }

  void _trimChapterCache() {
    final int limit = widget.chapterPreloadCount + 1;
    while (_chapterCache.length > limit) {
      _chapterCache.remove(_chapterCache.keys.first);
    }
  }

  void _retainCurrentChapterOnly() {
    final TextChapterContent? current = _content;
    _chapterCache.clear();
    if (current != null) _chapterCache[current.chapterId] = current;
  }

  Future<void> _prefetchNext(int currentIndex) async {
    final int count = widget.chapterPreloadCount;
    final int preloadGeneration = ++_chapterPreloadGeneration;
    if (_chapterIndex != currentIndex || count == 0) return;
    // Content and layout are reconciled by the same state machine. In
    // particular, a failed request returns to pending and waits for a later
    // page/lifecycle/layout event instead of recursively retrying.
    _reconcileAdjacentPreparation();
    if (_preferences.navigationMode == ReaderNavigationMode.horizontalPages) {
      final ReaderChapterInfo? adjacent = _catalogByIndex[currentIndex + 1];
      if (adjacent != null && _chapterCache.containsKey(adjacent.id)) {
        unawaited(
          _prefetchFollowingChapters(
            currentIndex,
            startOffset: 2,
            preloadGeneration: preloadGeneration,
          ),
        );
      }
      return;
    }
    await _prefetchFollowingChapters(
      currentIndex,
      startOffset: 1,
      preloadGeneration: preloadGeneration,
    );
  }

  Future<void> _prefetchFollowingChapters(
    int currentIndex, {
    required int startOffset,
    required int preloadGeneration,
  }) async {
    final int count = widget.chapterPreloadCount;
    final int session = _sessionGeneration;
    final TextReaderDataSource dataSource = widget.dataSource;
    final String bookId = widget.bookId;
    for (var offset = startOffset; offset <= count; offset++) {
      if (!_foreground ||
          preloadGeneration != _chapterPreloadGeneration ||
          !_isSessionCurrent(session) ||
          _chapterIndex != currentIndex ||
          !identical(dataSource, widget.dataSource) ||
          bookId != widget.bookId) {
        return;
      }
      final int targetIndex = currentIndex + offset;
      if (_catalogTotal > 0 && targetIndex >= _catalogTotal) return;
      try {
        final ReaderChapterInfo chapter = await _chapterInfoAtIndex(
          targetIndex,
        );
        if (!_foreground ||
            preloadGeneration != _chapterPreloadGeneration ||
            !_isSessionCurrent(session) ||
            _chapterIndex != currentIndex) {
          return;
        }
        final TextChapterContent? cached = _takeCached(chapter.id);
        if (cached != null) continue;
        final TextChapterContent content = await _loadChapterContent(
          dataSource,
          bookId,
          chapter.id,
        );
        if (!_foreground ||
            preloadGeneration != _chapterPreloadGeneration ||
            !_isSessionCurrent(session) ||
            _chapterIndex != currentIndex ||
            content.chapterId != chapter.id) {
          return;
        }
        _validateChapter(content, expectedChapterId: chapter.id);
        _cacheChapter(content);
      } catch (_) {
        // Preloading is best effort. Stop this window after the first failure
        // so an unavailable chapter cannot trigger a burst of later requests.
        return;
      }
    }
  }
}
