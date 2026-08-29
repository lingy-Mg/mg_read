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
    if (_restoringHorizontalAnchor) {
      final int? targetRawIndex = _restoringHorizontalRawIndex;
      if (rawIndex == targetRawIndex &&
          rawIndex > 0 &&
          rawIndex < _pages.length + 1) {
        _pageIndex = rawIndex - 1;
        _reconcileAdjacentPreparation();
        _completeHorizontalPageControllerReplacement(rawIndex);
      }
      // Replacing a chapter changes PageView's item count. It can emit a
      // callback for the old/clamped raw page before the requested semantic
      // anchor is applied. Never let that stale callback overwrite the tail
      // page selected for a previous-chapter transition.
      return;
    }
    if (rawIndex == 0) {
      return;
    }
    if (rawIndex == _pages.length + 1) {
      return;
    }
    _pageIndex = rawIndex - 1;
    _updateProgressFromPage();
    _reconcileAdjacentPreparation();
    if (mounted) setState(() {});
  }

  void _commitHorizontalBoundaryAfterScroll() {
    if (_changingChapter ||
        _pages.isEmpty ||
        !_pageController.hasClients ||
        _restoringHorizontalAnchor) {
      return;
    }
    final double? page = _pageController.page;
    if (page == null) return;
    final int rawIndex = page.round();
    if ((page - rawIndex).abs() > 0.001) return;
    if (rawIndex == 0) {
      unawaited(_previousChapter());
    } else if (rawIndex == _pages.length + 1) {
      unawaited(_nextChapter());
    }
  }

  void _restoreCurrentHorizontalPage() {
    if (_preferences.navigationMode != ReaderNavigationMode.horizontalPages) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_pageController.hasClients) return;
      _replaceHorizontalPageController(_pageIndex + 1);
      setState(() {});
    });
  }

  void _replaceHorizontalPageController(int rawIndex) {
    final PageController previous = _pageController;
    final PageController replacement = PageController(
      initialPage: rawIndex,
      keepPage: false,
    );
    _restoringHorizontalAnchor = true;
    _restoringHorizontalRawIndex = rawIndex;
    _pageController = replacement;
    _retiredPageControllers.add(previous);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_retiredPageControllers.remove(previous)) previous.dispose();
      if (!mounted ||
          !identical(_pageController, replacement) ||
          _restoringHorizontalRawIndex != rawIndex) {
        return;
      }
      final double? page = replacement.hasClients ? replacement.page : null;
      if (page != null && (page - rawIndex).abs() <= 0.001) {
        _completeHorizontalPageControllerReplacement(rawIndex);
      }
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  /// Acknowledges the target page reported by the replacement PageView.
  /// This never performs a delayed page correction: it only releases the
  /// already rendered handoff sheet after the new target page has laid out.
  void _completeHorizontalPageControllerReplacement(int rawIndex) {
    if (!_restoringHorizontalAnchor ||
        _restoringHorizontalRawIndex != rawIndex) {
      return;
    }
    if (rawIndex > 0 && rawIndex < _pages.length + 1) {
      _pageIndex = rawIndex - 1;
    }
    _restoringHorizontalRawIndex = null;
    _restoringHorizontalAnchor = false;
    final _HorizontalChapterHandoff? handoff = _horizontalChapterHandoff;
    if (handoff == null) {
      if (mounted) setState(() {});
      return;
    }
    final PageController replacement = _pageController;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !identical(_pageController, replacement) ||
          !identical(_horizontalChapterHandoff, handoff)) {
        return;
      }
      setState(() => _horizontalChapterHandoff = null);
    });
    WidgetsBinding.instance.scheduleFrame();
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
