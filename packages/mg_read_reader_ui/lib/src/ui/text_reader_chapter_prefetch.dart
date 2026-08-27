part of 'text_reader_view.dart';

/// 阅读器相邻章节正文预取与有界正文缓存。
///
/// 职责：
/// - 复用同一章节请求并维护当前章/下一章正文缓存。
/// - 在正文完成后通知横向布局预排调度。
///
/// 注意：
/// - 预取是 best effort；失败不得影响前台正文或语义进度。
/// - 正文完成或失败均回到相邻准备协调器，由下一真实阅读事件决定是否继续。
/// - 网络、文件和持久化仍由宿主数据源拥有。
///
/// TODO:
/// - 无。

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
    while (_chapterCache.length > _TextReaderViewState._chapterCacheLimit) {
      _chapterCache.remove(_chapterCache.keys.first);
    }
  }

  Future<void> _prefetchNext(int currentIndex) async {
    if (_chapterIndex != currentIndex) return;
    // Content and layout are reconciled by the same state machine. In
    // particular, a failed request returns to pending and waits for a later
    // page/lifecycle/layout event instead of recursively retrying.
    _reconcileAdjacentPreparation();
  }
}
