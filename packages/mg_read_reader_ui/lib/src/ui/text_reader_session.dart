part of 'text_reader_view.dart';

// ignore_for_file: invalid_use_of_protected_member

extension _TextReaderSession on _TextReaderViewState {
  void _bindController() {
    _controller.bind(
      owner: _controllerBindingOwner,
      openChapter: (String id) => _openChapter(id),
      nextPage: _nextPage,
      previousPage: _previousPage,
      nextChapter: _nextChapter,
      previousChapter: _previousChapter,
      showBookPreview: _showBookPreview,
      toggleControls: () async => _setControlsVisible(!_controlsVisible),
      showControls: () async => _setControlsVisible(true),
      hideControls: () async => _setControlsVisible(false),
      refresh: () =>
          _openChapter(_content?.chapterId ?? '', forceRefresh: true),
      startAutoReading: _startAutoReading,
      stopAutoReading: () async => _stopAutoReading(),
      toggleAutoReading: _toggleAutoReading,
    );
  }

  Future<void> _restart({Future<void>? persistenceCheckpoint}) async {
    _stopAutoReading();
    _completeChapterTransition(ReaderChapterPerformanceOutcome.cancelled);
    _requestGeneration++;
    final int generation = ++_sessionGeneration;
    _navigationGeneration++;
    _commentGeneration++;
    _fontLoadGeneration++;
    _chapterStateRefreshGeneration++;
    _saveTimer?.cancel();
    _chapterCache.clear();
    _chapterLoads.clear();
    _layoutFingerprint = null;
    _cancelAdjacentPreparation();
    _currentPaginationComplete = false;
    _contentEpoch++;
    _commentSummaries.clear();
    _commentSummariesLoading = false;
    _commentSummariesFailed = false;
    _catalog.clear();
    _catalogById.clear();
    _catalogByIndex.clear();
    _catalogPageIds.clear();
    _book = null;
    _bookmarks = const <ReaderBookmark>[];
    _catalogCursor = null;
    _catalogTotal = 0;
    _catalogHasMore = false;
    _catalogLoading = false;
    _content = null;
    _currentChapterInfo = null;
    _pages = const <ReaderPage>[];
    _progress = null;
    _failure = null;
    _runtimeFontFamily = null;
    _runtimeFontDescriptor = null;
    _chapterIndex = -1;
    _pageIndex = 0;
    _changingChapter = false;
    _awaitingPreviousChapterTail = false;
    _controlsVisible = false;
    _sliderPreview = null;
    _noticeMessage = null;
    _wheelDelta = 0;
    _wheelResetTimer?.cancel();
    _loading = true;
    _firstContentNotificationScheduled = false;
    _firstContentNotificationSent = false;
    _firstContentLayoutDuration = Duration.zero;
    _firstContentPreparation = ReaderPaginationPreparation.firstPage;
    if (mounted) setState(() {});
    unawaited(_releaseAwake());
    if (persistenceCheckpoint != null) await persistenceCheckpoint;
    if (!_isSessionCurrent(generation)) return;
    await _initialize();
  }

  Future<void> _initialize() async {
    final int generation = ++_sessionGeneration;
    final ReaderObserver observer = _observer;
    final String bookId = widget.bookId;
    if (mounted) {
      setState(() {
        _loading = true;
        _failure = null;
      });
    }

    try {
      final Future<ReaderBookInfo> bookFuture = widget.dataSource.loadBookInfo(
        widget.bookId,
      );
      final Future<ChapterCatalogPage> catalogFuture = widget.dataSource
          .loadChapterCatalog(widget.bookId);
      final Future<ReaderProgress?> progressFuture = _safeLoadProgress(
        generation,
        observer,
      );
      final Future<TextReaderPreferences> preferencesFuture =
          _safeLoadPreferences(generation, observer);
      final List<dynamic> results = await Future.wait<dynamic>(
        <Future<dynamic>>[
          bookFuture,
          catalogFuture,
          progressFuture,
          preferencesFuture,
        ],
      );
      if (!_isSessionCurrent(generation)) return;

      _book = results[0] as ReaderBookInfo;
      _mergeCatalog(results[1] as ChapterCatalogPage);
      final ReaderProgress? loadedProgress = results[2] as ReaderProgress?;
      // A new shelf item has no saved anchor yet. Start at chapter zero rather
      // than showing a separate metadata page with a second "开始阅读" action.
      // Normalize older preview anchors as well so that page does not return
      // when the book is opened again after an app update.
      _progress = loadedProgress == null || loadedProgress.isBookPreview
          ? _defaultChapterProgress()
          : loadedProgress;
      _preferences = results[3] as TextReaderPreferences;
      unawaited(_loadPersistedCustomFont());
      if (!_isNightTheme(_preferences.theme)) {
        _lastNonNightTheme = _preferences.theme;
      }
      // Bookmark/state/comment work is deliberately deferred until after the
      // first real text frame so it cannot compete with first-page layout.
      _bookmarks = const <ReaderBookmark>[];

      if (_progress!.isBookPreview) {
        _content = null;
        _currentChapterInfo = null;
        _chapterIndex = -1;
      } else {
        if (_catalogTotal <= 0) {
          throw const ReaderFailure(
            ReaderFailureKind.data,
            ReaderStrings.savedProgressWithoutChapters,
          );
        }
        ReaderChapterInfo? target = _catalogById[_progress!.chapterId];
        target ??= await _chapterInfoAtIndex(_progress!.chapterIndex);
        if (!_isSessionCurrent(generation)) return;
        await _openChapter(target.id, initial: true);
        if (!_isSessionCurrent(generation)) return;
      }
      _loading = false;
      _failure = null;
      if (mounted) setState(() {});
      _scheduleFirstContentPresentation(generation);
      if (_firstContentNotificationSent) {
        await _syncAwake();
      } else {
        // Screen-awake is non-essential to the first text frame. Do not let
        // a platform queue delay chapter presentation during cold start.
        unawaited(_syncAwake());
      }
      if (!_isSessionCurrent(generation)) return;
      unawaited(_notify(() => observer.onSessionStarted(bookId)));
      _publishSnapshot();
    } catch (error) {
      if (!_isSessionCurrent(generation)) return;
      final ReaderFailure failure = _asFailure(error, ReaderFailureKind.data);
      if (mounted) {
        setState(() {
          _loading = false;
          _failure = failure;
        });
      }
      _publishSnapshot();
      await _reportFailure(failure);
    }
  }

  Future<ReaderProgress?> _safeLoadProgress(
    int generation,
    ReaderObserver observer,
  ) async {
    final TextReaderStateStore store = widget.stateStore;
    final String bookId = widget.bookId;
    try {
      return await store.loadProgress(bookId);
    } catch (error) {
      if (_isSessionCurrent(generation)) {
        unawaited(
          _notify(
            () => observer.onFailure(
              _asFailure(error, ReaderFailureKind.persistence),
            ),
          ),
        );
      }
      return null;
    }
  }

  Future<TextReaderPreferences> _safeLoadPreferences(
    int generation,
    ReaderObserver observer,
  ) async {
    final TextReaderStateStore store = widget.stateStore;
    try {
      return (await store.loadPreferences() ?? TextReaderPreferences.defaults)
          .normalized();
    } catch (error) {
      if (_isSessionCurrent(generation)) {
        unawaited(
          _notify(
            () => observer.onFailure(
              _asFailure(error, ReaderFailureKind.persistence),
            ),
          ),
        );
      }
      return TextReaderPreferences.defaults;
    }
  }

  Future<List<ReaderBookmark>> _safeLoadBookmarks(
    int generation,
    ReaderObserver observer,
  ) async {
    final TextReaderStateStore store = widget.stateStore;
    final String bookId = widget.bookId;
    try {
      return List.unmodifiable(await store.loadBookmarks(bookId));
    } catch (error) {
      if (_isSessionCurrent(generation)) {
        unawaited(
          _notify(
            () => observer.onFailure(
              _asFailure(error, ReaderFailureKind.persistence),
            ),
          ),
        );
      }
      return const <ReaderBookmark>[];
    }
  }

  void _scheduleFirstContentPresentation(int generation) {
    if (_firstContentNotificationScheduled || _firstContentNotificationSent) {
      return;
    }
    _firstContentNotificationScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _disposed || _content == null) return;
      _firstContentNotificationSent = true;
      final ReaderObserver observer = _observer;
      final ReaderFirstContentPresentation presentation =
          ReaderFirstContentPresentation(
            anchor: _progress,
            paginationPreparation: _firstContentPreparation,
            layoutDuration: _firstContentLayoutDuration,
          );
      unawaited(_notify(() => observer.onFirstContentPresented(presentation)));
      unawaited(_finishDeferredFirstFrameWork(generation));
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  Future<void> _finishDeferredFirstFrameWork(int generation) async {
    if (!_isSessionCurrent(generation)) return;
    final List<ReaderBookmark> bookmarks = await _safeLoadBookmarks(
      generation,
      _observer,
    );
    if (!_isSessionCurrent(generation)) return;
    _bookmarks = bookmarks;
    if (mounted) setState(() {});
    if (_content != null && _currentChapterInfo != null) {
      _scheduleProgressSave(immediate: true);
      unawaited(_prefetchNext(_currentChapterInfo!.index));
      unawaited(_refreshCommentSummaries());
      unawaited(_recordChapterOpened(_content!.chapterId));
    }
  }

  void _mergeCatalog(ChapterCatalogPage page) {
    final bool firstPage = _catalogPageIds.isEmpty && _catalogCursor == null;
    final String? nextCursor = page.nextCursor;
    if (page.total < 0 ||
        page.items.length > page.total ||
        (!firstPage && page.total != _catalogTotal) ||
        (page.hasMore &&
            (page.items.isEmpty ||
                nextCursor == null ||
                nextCursor.trim().isEmpty ||
                nextCursor == _catalogCursor)) ||
        (!page.hasMore && nextCursor != null)) {
      throw const ReaderFailure(
        ReaderFailureKind.data,
        ReaderStrings.invalidChapterLocation,
      );
    }

    var expectedIndex = _catalogPageIds.length;
    final Set<String> pageIds = <String>{};
    final Set<int> pageIndexes = <int>{};
    for (final ReaderChapterInfo item in page.items) {
      if (item.id.trim().isEmpty ||
          item.index < 0 ||
          item.index >= page.total ||
          item.index != expectedIndex ||
          !pageIds.add(item.id) ||
          !pageIndexes.add(item.index)) {
        throw const ReaderFailure(
          ReaderFailureKind.data,
          ReaderStrings.invalidChapterLocation,
        );
      }
      expectedIndex++;
      if (_catalogPageIds.contains(item.id)) {
        throw const ReaderFailure(
          ReaderFailureKind.data,
          ReaderStrings.invalidChapterLocation,
        );
      }
      final ReaderChapterInfo? sameId = _catalogById[item.id];
      final ReaderChapterInfo? sameIndex = _catalogByIndex[item.index];
      if ((sameId != null && sameId.index != item.index) ||
          (sameIndex != null && sameIndex.id != item.id)) {
        throw const ReaderFailure(
          ReaderFailureKind.data,
          ReaderStrings.invalidChapterLocation,
        );
      }
    }
    if (!page.hasMore &&
        _catalogPageIds.length + page.items.length != page.total) {
      throw const ReaderFailure(
        ReaderFailureKind.data,
        ReaderStrings.invalidChapterLocation,
      );
    }
    _catalog.addAll(page.items);
    for (final ReaderChapterInfo item in page.items) {
      _catalogById[item.id] = item;
      _catalogByIndex[item.index] = item;
    }
    _catalogPageIds.addAll(page.items.map((ReaderChapterInfo item) => item.id));
    _catalogCursor = page.nextCursor;
    _catalogTotal = page.total;
    _catalogHasMore = page.hasMore;
    unawaited(_refreshLoadedChapterStates());
  }

  Future<ReaderChapterInfo> _chapterInfoAtIndex(int index) async {
    if (index < 0 || (_catalogTotal > 0 && index >= _catalogTotal)) {
      throw ReaderFailure(
        ReaderFailureKind.data,
        ReaderStrings.chapterIndexOutOfRange(index),
      );
    }
    final ReaderChapterInfo? cached = _catalogByIndex[index];
    if (cached != null) return cached;
    final int session = _sessionGeneration;
    final TextReaderDataSource dataSource = widget.dataSource;
    final String bookId = widget.bookId;
    final ReaderChapterInfo chapter = await dataSource.loadChapterAtIndex(
      bookId,
      index,
    );
    if (!_isSessionCurrent(session) ||
        !identical(dataSource, widget.dataSource) ||
        bookId != widget.bookId) {
      throw StateError(ReaderStrings.staleSession);
    }
    if (chapter.index != index || chapter.id.trim().isEmpty) {
      throw const ReaderFailure(
        ReaderFailureKind.data,
        ReaderStrings.invalidChapterLocation,
      );
    }
    final ReaderChapterInfo? sameId = _catalogById[chapter.id];
    final ReaderChapterInfo? sameIndex = _catalogByIndex[chapter.index];
    if ((sameId != null && sameId.index != chapter.index) ||
        (sameIndex != null && sameIndex.id != chapter.id)) {
      throw const ReaderFailure(
        ReaderFailureKind.data,
        ReaderStrings.invalidChapterLocation,
      );
    }
    _catalogById[chapter.id] = chapter;
    _catalogByIndex[chapter.index] = chapter;
    unawaited(_refreshLoadedChapterStates(chapterId: chapter.id));
    return chapter;
  }

  Future<void> _loadMoreCatalog({bool notify = true}) async {
    if (_catalogLoading || !_catalogHasMore) return;
    final int generation = _sessionGeneration;
    final TextReaderDataSource dataSource = widget.dataSource;
    final String bookId = widget.bookId;
    final String? cursor = _catalogCursor;
    _catalogLoading = true;
    if (notify && mounted) setState(() {});
    try {
      final ChapterCatalogPage page = await dataSource.loadChapterCatalog(
        bookId,
        cursor: cursor,
      );
      if (!_isCatalogSessionCurrent(generation, dataSource, bookId) ||
          cursor != _catalogCursor) {
        return;
      }
      _mergeCatalog(page);
    } catch (error) {
      if (_isCatalogSessionCurrent(generation, dataSource, bookId) &&
          cursor == _catalogCursor) {
        await _reportFailure(_asFailure(error, ReaderFailureKind.data));
      }
    } finally {
      if (_isCatalogSessionCurrent(generation, dataSource, bookId)) {
        _catalogLoading = false;
        if (notify && mounted) setState(() {});
      }
    }
  }

  bool _isCatalogSessionCurrent(
    int generation,
    TextReaderDataSource dataSource,
    String bookId,
  ) =>
      _isSessionCurrent(generation) &&
      identical(dataSource, widget.dataSource) &&
      bookId == widget.bookId;

  Future<void> _openChapter(
    String chapterId, {
    bool initial = false,
    bool forceRefresh = false,
    bool openAtEnd = false,
    double? targetChapterFraction,
    bool preserveAutoReading = false,
  }) async {
    if (!preserveAutoReading) _stopAutoReading();
    if (chapterId.isEmpty) return;
    final ReaderChapterInfo? targetInfo = _catalogById[chapterId];
    if (targetInfo == null) return;
    final TextChapterContent? previousContent = _content;
    final int previousIndex = _chapterIndex;
    final int navigation = ++_navigationGeneration;
    final int generation = ++_requestGeneration;
    final int session = _sessionGeneration;
    final ReaderObserver observer = _observer;
    final TextReaderDataSource dataSource = widget.dataSource;
    final String bookId = widget.bookId;
    _changingChapter = true;
    if (!initial && mounted) setState(() {});
    try {
      TextChapterContent? chapter;
      if (!forceRefresh) chapter = _takeCached(chapterId);
      chapter ??= await _loadChapterContent(
        dataSource,
        bookId,
        chapterId,
        reuseInFlight: !forceRefresh,
      );
      if (!_isCurrent(generation) || navigation != _navigationGeneration) {
        return;
      }
      if (session != _sessionGeneration || chapter.chapterId != chapterId) {
        if (chapter.chapterId != chapterId) {
          throw const ReaderFailure(
            ReaderFailureKind.data,
            ReaderStrings.invalidChapterLocation,
          );
        }
        return;
      }
      _validateChapter(chapter, expectedChapterId: chapterId);
      if (openAtEnd &&
          previousContent != null &&
          previousIndex == targetInfo.index + 1) {
        _chapterCache
          ..clear()
          ..[chapter.chapterId] = chapter
          ..[previousContent.chapterId] = previousContent;
      } else {
        _cacheChapter(chapter);
      }
      _cancelAdjacentPreparation();
      _chapterIndex = targetInfo.index;
      _currentChapterInfo = targetInfo;
      _content = chapter;
      _contentEpoch++;
      _pages = const <ReaderPage>[];
      _currentPaginationComplete = false;
      _pageIndex = 0;
      _paragraphKeys.clear();
      _awaitingPreviousChapterTail =
          openAtEnd &&
          _preferences.navigationMode == ReaderNavigationMode.horizontalPages;

      final ReaderProgress? saved = _progress;
      final TextParagraph first = chapter.paragraphs.isEmpty
          ? const TextParagraph(id: '', text: '')
          : chapter.paragraphs.first;
      if (initial && saved?.chapterId == chapterId && !saved!.isBookPreview) {
        final int total = _catalogTotal > 0 ? _catalogTotal : _catalog.length;
        _progress = saved.copyWith(
          chapterIndex: targetInfo.index,
          bookFraction: total <= 0
              ? 0
              : ((targetInfo.index + saved.chapterFraction) / total).clamp(
                  0,
                  1,
                ),
        );
      } else {
        final double fraction =
            targetChapterFraction?.clamp(0, 1) ?? (openAtEnd ? 1 : 0);
        final int paragraphIndex = chapter.paragraphs.isEmpty
            ? 0
            : (fraction * chapter.paragraphs.length).floor().clamp(
                0,
                chapter.paragraphs.length - 1,
              );
        final TextParagraph anchor = chapter.paragraphs.isEmpty
            ? first
            : chapter.paragraphs[paragraphIndex];
        final int offset = openAtEnd
            ? anchor.text.length
            : (fraction * anchor.text.length).floor().clamp(
                0,
                anchor.text.length,
              );
        _progress = _progressForAnchor(
          anchor.id,
          offset,
          chapterFraction: fraction,
        );
      }
      _progress = _normalizeSemanticAnchor(_progress);
      _failure = null;
      if (mounted) setState(() {});
      _publishSnapshot();
      unawaited(_notify(() => observer.onChapterChanged(targetInfo)));
      // Screen-awake is non-essential to a page turn. A slow platform queue
      // must never hold the chapter transition or its first readable frame.
      unawaited(_syncAwake());
      if (!_isCurrent(generation) || session != _sessionGeneration) return;
      if (_preferences.navigationMode == ReaderNavigationMode.verticalScroll) {
        _scheduleVerticalRestore();
      }
      if (_firstContentNotificationSent) {
        _scheduleProgressSave(immediate: true);
        if (!openAtEnd) unawaited(_prefetchNext(targetInfo.index));
        unawaited(_refreshCommentSummaries());
        unawaited(_recordChapterOpened(chapterId));
      }
    } catch (error) {
      if (!_isCurrent(generation) || navigation != _navigationGeneration) {
        return;
      }
      _stopAutoReading();
      _awaitingPreviousChapterTail = false;
      final ReaderFailure failure = _asFailure(error, ReaderFailureKind.data);
      _failure = failure;
      if (mounted) setState(() {});
      await _reportFailure(failure);
      unawaited(_refreshLoadedChapterStates(chapterId: chapterId));
    } finally {
      if (_isCurrent(generation)) {
        _changingChapter = false;
        if (mounted) setState(() {});
      }
    }
  }

  void _validateChapter(
    TextChapterContent chapter, {
    required String expectedChapterId,
  }) {
    if (chapter.chapterId.trim().isEmpty ||
        chapter.chapterId != expectedChapterId) {
      throw const ReaderFailure(
        ReaderFailureKind.data,
        ReaderStrings.invalidChapterLocation,
      );
    }
    final Set<String> paragraphIds = <String>{};
    for (final TextParagraph paragraph in chapter.paragraphs) {
      if (paragraph.id.trim().isEmpty || !paragraphIds.add(paragraph.id)) {
        throw const ReaderFailure(
          ReaderFailureKind.data,
          ReaderStrings.invalidParagraphIdentifiers,
        );
      }
    }
  }

  ReaderProgress? _normalizeSemanticAnchor(ReaderProgress? progress) {
    final TextChapterContent? content = _content;
    if (progress == null || content == null || content.paragraphs.isEmpty) {
      return progress;
    }
    final TextParagraph? exact = content.paragraphs
        .where(
          (TextParagraph paragraph) => paragraph.id == progress.paragraphId,
        )
        .firstOrNull;
    if (exact != null) {
      return progress.copyWith(
        paragraphId: exact.id,
        characterOffset: progress.characterOffset.clamp(0, exact.text.length),
      );
    }
    final int totalCharacters = content.paragraphs.fold<int>(
      0,
      (int sum, TextParagraph paragraph) => sum + paragraph.text.length,
    );
    if (totalCharacters <= 0) {
      final TextParagraph first = content.paragraphs.first;
      return progress.copyWith(paragraphId: first.id, characterOffset: 0);
    }
    var target = (progress.chapterFraction.clamp(0, 1) * totalCharacters)
        .floor()
        .clamp(0, totalCharacters);
    for (final TextParagraph paragraph in content.paragraphs) {
      if (target <= paragraph.text.length) {
        return progress.copyWith(
          paragraphId: paragraph.id,
          characterOffset: target.clamp(0, paragraph.text.length),
        );
      }
      target -= paragraph.text.length;
    }
    final TextParagraph last = content.paragraphs.last;
    return progress.copyWith(
      paragraphId: last.id,
      characterOffset: last.text.length,
    );
  }

  Future<void> _loadPersistedCustomFont() async {
    final int generation = ++_fontLoadGeneration;
    final ReaderFontRepository? repository = widget.extensions.fontRepository;
    final String? fontId = _preferences.customFontId?.trim();
    if (repository == null || fontId == null || fontId.isEmpty) {
      if (!_disposed && generation == _fontLoadGeneration && mounted) {
        setState(() {
          _runtimeFontFamily = null;
          _runtimeFontDescriptor = null;
        });
      }
      return;
    }
    try {
      final List<ReaderFontDescriptor> catalog = await repository.loadCatalog();
      final ReaderFontDescriptor descriptor = catalog.firstWhere(
        (ReaderFontDescriptor value) => value.id.trim() == fontId,
        orElse: () => throw StateError(ReaderStrings.externalFontUnavailable),
      );
      final String runtimeFamily = await loadReaderRuntimeFont(
        repository: repository,
        descriptor: descriptor,
      );
      if (_disposed ||
          !mounted ||
          generation != _fontLoadGeneration ||
          !identical(repository, widget.extensions.fontRepository) ||
          _preferences.customFontId?.trim() != fontId) {
        return;
      }
      final ReaderProgress? anchor = _progress;
      setState(() {
        _runtimeFontFamily = runtimeFamily;
        _runtimeFontDescriptor = descriptor;
      });
      if (_preferences.navigationMode == ReaderNavigationMode.verticalScroll) {
        _scheduleVerticalRestore(paragraphId: anchor?.paragraphId);
      }
    } catch (error) {
      if (_disposed ||
          generation != _fontLoadGeneration ||
          !identical(repository, widget.extensions.fontRepository) ||
          _preferences.customFontId?.trim() != fontId) {
        return;
      }
      if (mounted) {
        setState(() {
          _runtimeFontFamily = null;
          _runtimeFontDescriptor = null;
        });
      }
      await _reportFailure(
        ReaderFailure(
          ReaderFailureKind.data,
          ReaderStrings.externalFontUnavailable,
          cause: error,
        ),
      );
    }
  }

  void _applySelectedCustomFont(
    ReaderFontDescriptor descriptor,
    String runtimeFamily,
  ) {
    if (_disposed || !mounted) return;
    _fontLoadGeneration++;
    final ReaderProgress? anchor = _progress;
    setState(() {
      _runtimeFontFamily = runtimeFamily;
      _runtimeFontDescriptor = descriptor;
    });
    if (_preferences.navigationMode == ReaderNavigationMode.verticalScroll) {
      _scheduleVerticalRestore(paragraphId: anchor?.paragraphId);
    }
  }
}
