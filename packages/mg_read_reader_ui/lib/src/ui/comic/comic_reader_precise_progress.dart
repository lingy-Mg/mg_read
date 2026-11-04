part of 'comic_reader_view.dart';

/// Opt-in exact image progress support for stable local image catalogs.
extension _ComicReaderPreciseProgress on _ComicReaderViewState {
  bool get _supportsPreciseProgress =>
      widget.dataSource is ComicReaderPreciseProgressDataSource;

  void _onComicImagePresented(String chapterId, String imageId, bool cacheHit) {
    _notifyFirstContentPresented(cacheHit);
    final ComicReaderProgress? saved = _pendingExactRestore;
    if (saved == null ||
        saved.chapterId != chapterId ||
        saved.imageId != imageId ||
        !_scrollController.hasClients) {
      return;
    }
    final int navigation = _navigationGeneration;
    if (_exactRestoreGeneration == navigation) return;
    _exactRestoreGeneration = navigation;
    // Decoding can change several preceding image extents in one frame.
    // Let layout publish the new scroll range before releasing the durable
    // semantic anchor; a placeholder-clamped offset must never replace it.
    void afterLayout(int remainingPasses) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_isNavigation(navigation) ||
            !identical(_pendingExactRestore, saved) ||
            !_scrollController.hasClients) {
          return;
        }
        if (remainingPasses == 0) {
          _pendingExactRestore = null;
          _updateProgressFromScroll();
          return;
        }
        _restoring = true;
        _restorePosition(saved);
        _restoring = false;
        afterLayout(remainingPasses - 1);
      });
      WidgetsBinding.instance.ensureVisualUpdate();
    }

    afterLayout(2);
  }

  void _schedulePreciseProgressProbe() {
    if (_preciseProgressProbeScheduled) return;
    _preciseProgressProbeScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _preciseProgressProbeScheduled = false;
      if (!_disposed && !_restoring && _scrollController.hasClients) {
        _updateProgressFromScroll();
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _flushProgress() {
    _saveTimer?.cancel();
    final ComicReaderProgress? progress = _progress;
    if (progress == null) return Future<void>.value();
    return _queueProgressSave(
      store: widget.stateStore,
      bookId: widget.bookId,
      progress: progress,
    );
  }

  Future<void> _queueProgressSave({
    required ComicReaderStateStore store,
    required String bookId,
    required ComicReaderProgress progress,
    bool? precisePosition,
  }) {
    final bool precise =
        precisePosition ??
        (identical(store, widget.stateStore) && _supportsPreciseProgress);
    final ComicReaderProgress effectiveProgress =
        precise &&
            _pendingExactRestore?.chapterId == progress.chapterId &&
            _pendingExactRestore?.chapterIndex == progress.chapterIndex
        ? _pendingExactRestore!
        : progress;
    final ComicReaderProgress durableProgress = precise
        ? effectiveProgress
        : _chapterStartProgress(effectiveProgress);
    final _BookStoreKey stateKey = _BookStoreKey(store, bookId);
    final String writeKey =
        '${durableProgress.chapterId}\u0000'
        '${durableProgress.chapterIndex}'
        '${precise ? '\u0000${durableProgress.imageId}\u0000${durableProgress.imageFraction.toStringAsPrecision(8)}' : ''}';
    if (_lastProgressWriteKeys[stateKey] == writeKey) {
      return _progressWrites[stateKey] ?? Future<void>.value();
    }
    _lastProgressWriteKeys[stateKey] = writeKey;
    return _enqueueStoreWrite(
      _progressWrites,
      stateKey,
      () => store.saveProgress(bookId, durableProgress),
      (Object error) {
        if (_lastProgressWriteKeys[stateKey] == writeKey) {
          _lastProgressWriteKeys.remove(stateKey);
        }
        if (!_disposed &&
            identical(store, widget.stateStore) &&
            bookId == widget.bookId) {
          unawaited(_reportFailure(_stateFailure(error)));
        }
      },
    );
  }

  ComicReaderProgress _chapterStartProgress(ComicReaderProgress progress) {
    String firstImageId = progress.imageId;
    for (final _LoadedComicChapter chapter in _window) {
      if (chapter.info.id == progress.chapterId &&
          chapter.content.images.isNotEmpty) {
        firstImageId = chapter.content.images.first.id;
        break;
      }
    }
    final int total = _catalogTotal > 0
        ? _catalogTotal
        : math.max(progress.chapterIndex + 1, 1);
    return ComicReaderProgress(
      chapterId: progress.chapterId,
      imageId: firstImageId,
      imageFraction: 0,
      chapterIndex: progress.chapterIndex,
      chapterFraction: 0,
      bookFraction: (progress.chapterIndex / total).clamp(0, 1).toDouble(),
    );
  }
}
