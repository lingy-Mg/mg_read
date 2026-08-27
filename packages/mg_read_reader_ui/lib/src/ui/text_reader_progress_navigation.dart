part of 'text_reader_view.dart';

// ignore_for_file: invalid_use_of_protected_member

/// 处理横向页面变化后的语义进度、边界恢复和短时提示。
/// 横向页变化同时是相邻准备失败后的显式恢复触发点。
extension _TextReaderProgressNavigation on _TextReaderViewState {
  void _showNotice(String message) {
    _noticeTimer?.cancel();
    if (mounted) setState(() => _noticeMessage = message);
    _noticeTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _noticeMessage = null);
    });
  }

  void _onHorizontalPageChanged(int rawIndex) {
    if (_changingChapter || _pages.isEmpty) return;
    if (_restoringHorizontalAnchor &&
        rawIndex > 0 &&
        rawIndex < _pages.length + 1) {
      _pageIndex = rawIndex - 1;
      _reconcileAdjacentPreparation();
      if (mounted) setState(() {});
      return;
    }
    if (rawIndex == 0) {
      unawaited(_previousChapter());
      return;
    }
    if (rawIndex == _pages.length + 1) {
      unawaited(_nextChapter());
      return;
    }
    _pageIndex = rawIndex - 1;
    _updateProgressFromPage();
    _reconcileAdjacentPreparation();
    if (mounted) setState(() {});
  }

  void _updateProgressFromPage() {
    if (_pages.isEmpty || _pageIndex >= _pages.length) return;
    final ReaderPage page = _pages[_pageIndex];
    if (page.blocks.isEmpty) return;
    final bool hasChapterTrailing = _pages.last.showsChapterTrailing;
    final int bodyPageCount = _pages.length - (hasChapterTrailing ? 1 : 0);
    final int visitedBodyPageCount = (_pageIndex + 1).clamp(0, bodyPageCount);
    _progress = _progressForAnchor(
      page.paragraphId,
      page.characterOffset,
      chapterFraction: bodyPageCount == 0
          ? 0
          : visitedBodyPageCount / bodyPageCount,
    );
    _scheduleProgressSave();
    _publishSnapshot();
  }

  ReaderProgress _progressForAnchor(
    String paragraphId,
    int offset, {
    required double chapterFraction,
  }) {
    final int total = _catalogTotal > 0 ? _catalogTotal : _catalog.length;
    final double bookFraction = total == 0
        ? 0
        : ((_chapterIndex + chapterFraction) / total).clamp(0, 1);
    return ReaderProgress(
      chapterId: _content?.chapterId ?? _currentChapter?.id ?? '',
      paragraphId: paragraphId,
      characterOffset: offset,
      chapterIndex: _chapterIndex,
      chapterFraction: chapterFraction.clamp(0, 1),
      bookFraction: bookFraction,
    );
  }
}
