part of 'text_reader_view.dart';

/// Toolbar chapter actions move between authored chapters, skipping physical
/// continuation segments. Page-boundary navigation remains in pagination.
extension _TextReaderLogicalNavigation on _TextReaderViewState {
  Future<void> _navigateLogicalChapter(
    int direction, {
    bool dismissControls = false,
    bool showLoadingOverlay = false,
  }) async {
    assert(direction == -1 || direction == 1);
    _stopAutoReading();
    _completeChapterTransition(ReaderChapterPerformanceOutcome.cancelled);
    final int navigation = ++_navigationGeneration;
    final int total = _catalogTotal > 0 ? _catalogTotal : _catalog.length;
    _beginChapterLookup(
      dismissControls: dismissControls,
      showLoadingOverlay: showLoadingOverlay,
    );

    try {
      int index = _chapterIndex + direction;
      ReaderChapterInfo? target;
      while (index >= 0 && index < total) {
        final ReaderChapterInfo candidate = await _chapterInfoAtIndex(index);
        if (navigation != _navigationGeneration) return;
        if (!candidate.isContinuation) {
          target = candidate;
          break;
        }
        index += direction;
      }

      if (navigation != _navigationGeneration) return;
      if (target == null) {
        _endChapterLookup(navigation);
        _restoreCurrentHorizontalPage();
        _showNotice(
          direction > 0
              ? ReaderStrings.noNextChapter
              : ReaderStrings.noPreviousChapter,
        );
        return;
      }

      await _openChapter(
        target.id,
        openAtEnd: direction < 0,
        preserveAutoReading: direction > 0,
        dismissControls: dismissControls,
        showLoadingOverlay: showLoadingOverlay,
      );
    } catch (error) {
      if (navigation != _navigationGeneration) return;
      _restoreCurrentHorizontalPage();
      _endChapterLookup(navigation);
      _showChapterLoadFailure(
        error,
        () => _navigateLogicalChapter(
          direction,
          dismissControls: true,
          showLoadingOverlay: true,
        ),
      );
    }
  }
}
