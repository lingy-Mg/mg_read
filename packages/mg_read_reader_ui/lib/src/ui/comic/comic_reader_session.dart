part of 'comic_reader_view.dart';

// ignore_for_file: invalid_use_of_protected_member

extension _ComicReaderSession on _ComicReaderViewState {
  void _bindController() {
    _controller.bind(
      owner: _controllerOwner,
      openChapter: _openChapterById,
      nextChapter: _nextChapter,
      previousChapter: _previousChapter,
      toggleControls: () async => _setControlsVisible(!_controlsVisible),
      showControls: () async => _setControlsVisible(true),
      hideControls: () async => _setControlsVisible(false),
      refresh: _refreshCurrentChapter,
    );
  }

  Future<void> _restart({ComicReaderPreferences? preferenceOverride}) async {
    final int generation = ++_sessionGeneration;
    _navigationGeneration++;
    _saveTimer?.cancel();
    _snapshotTimer?.cancel();
    _contentCache.clear();
    _contentLoads.clear();
    _chapterInfoLoads.clear();
    _contentEpochs.clear();
    _catalog.clear();
    _catalogById.clear();
    _catalogByIndex.clear();
    _window.clear();
    _boundaryFailures.clear();
    _boundaryLoads.clear();
    _catalogCursors.clear();
    _catalogCursor = null;
    _catalogTotal = 0;
    _catalogHasMore = false;
    _catalogLoading = false;
    _catalogPageCoverage = 0;
    _beforeBoundaryIndex = null;
    _afterBoundaryIndex = null;
    _book = null;
    _currentChapter = null;
    _progress = null;
    _preferences = ComicReaderPreferences.defaults;
    _preferencesAuthoritative = false;
    _bookmarks = const <ComicReaderBookmark>[];
    _firstContentPresented = false;
    _prefetchForward = true;
    _lastObservedScrollOffset = null;
    _failure = null;
    _loading = true;
    if (mounted) setState(() {});
    _publishSnapshot();
    await _initialize(
      generation: generation,
      preferenceOverride: preferenceOverride,
    );
  }

  Future<void> _initialize({
    int? generation,
    ComicReaderPreferences? preferenceOverride,
  }) async {
    final int session = generation ?? ++_sessionGeneration;
    final String bookId = widget.bookId;
    final ComicReaderDataSource dataSource = widget.dataSource;
    final ComicReaderStateStore store = widget.stateStore;

    try {
      if (bookId.trim().isEmpty) {
        throw StateError('Comic book ID must contain visible text.');
      }
      // All five reads start together. State failures are recoverable and do
      // not discard usable book/catalog data.
      final Future<_Result<ComicBookInfo>> bookFuture = _captureCall(
        () => dataSource.loadBookInfo(bookId),
      );
      final Future<_Result<ComicChapterCatalogPage>> catalogFuture =
          _captureCall(
            () => dataSource.loadChapterCatalog(
              bookId,
              pageSize: _ComicReaderViewState._catalogPageSize,
            ),
          );
      final _BookStoreKey stateKey = _BookStoreKey(store, bookId);
      final Future<_Result<ComicReaderProgress?>> progressFuture = _captureCall(
        () async {
          await (_progressWrites[stateKey] ?? Future<void>.value());
          return store.loadProgress(bookId);
        },
      );
      final Future<_Result<ComicReaderPreferences?>> preferencesFuture =
          preferenceOverride != null
          ? Future<_Result<ComicReaderPreferences?>>.value(
              _Result<ComicReaderPreferences?>(value: preferenceOverride),
            )
          : _captureCall(() async {
              await (_preferenceWrites[store] ?? Future<void>.value());
              return store.loadPreferences();
            });
      final Future<_Result<List<ComicReaderBookmark>>> bookmarksFuture =
          _captureCall(() async {
            await (_bookmarkWrites[stateKey] ?? Future<void>.value());
            return store.loadBookmarks(bookId);
          });
      final _Result<ComicBookInfo> bookResult = await bookFuture;
      final _Result<ComicChapterCatalogPage> catalogResult =
          await catalogFuture;
      final _Result<ComicReaderProgress?> savedResult = await progressFuture;
      final _Result<ComicReaderPreferences?> preferencesResult =
          await preferencesFuture;
      final _Result<List<ComicReaderBookmark>> bookmarksResult =
          await bookmarksFuture;
      if (!_isSession(session, bookId, dataSource, store)) return;
      if (bookResult.error != null) throw bookResult.error!;
      if (catalogResult.error != null) throw catalogResult.error!;
      final ComicBookInfo book = bookResult.value!;
      final ComicChapterCatalogPage firstPage = catalogResult.value!;
      _validateBook(book, bookId);
      _mergeCatalog(firstPage, requestedCursor: null);
      _book = book;
      _preferences =
          (preferenceOverride ??
                  preferencesResult.value ??
                  ComicReaderPreferences.defaults)
              .normalized();
      _preferencesAuthoritative =
          preferenceOverride != null || preferencesResult.error == null;
      final List<ComicReaderBookmark> loadedBookmarks =
          List<ComicReaderBookmark>.unmodifiable(
            bookmarksResult.value ?? const <ComicReaderBookmark>[],
          );
      try {
        _validateBookmarks(loadedBookmarks, bookId);
        _bookmarks = loadedBookmarks;
      } catch (error) {
        _bookmarks = const <ComicReaderBookmark>[];
        unawaited(_reportFailure(_stateFailure(error)));
      }
      if (savedResult.error != null) {
        unawaited(_reportFailure(_stateFailure(savedResult.error!)));
      }
      if (preferencesResult.error != null && preferenceOverride == null) {
        unawaited(_reportFailure(_stateFailure(preferencesResult.error!)));
      }
      if (bookmarksResult.error != null) {
        unawaited(_reportFailure(_stateFailure(bookmarksResult.error!)));
      }
      if (_catalog.isEmpty) {
        setState(() => _loading = false);
        _publishSnapshot();
        unawaited(
          _notify(
            () => (widget.observer ?? const ComicReaderObserver())
                .onSessionStarted(bookId),
          ),
        );
        return;
      }
      final ComicReaderProgress? saved = savedResult.value;
      ComicChapterInfo target = _catalog.first;
      if (saved != null) {
        final ComicChapterInfo? restored = await _resolveSavedChapter(saved);
        if (restored != null) target = restored;
      }
      if (!_isSession(session, bookId, dataSource, store)) return;
      await _openChapterInfo(target, replaceWindow: true);
      if (!_isSession(session, bookId, dataSource, store)) return;
      unawaited(
        _notify(
          () => (widget.observer ?? const ComicReaderObserver())
              .onSessionStarted(bookId),
        ),
      );
    } catch (error) {
      if (!_isSession(session, bookId, dataSource, store)) return;
      final ReaderFailure failure = _asFailure(
        error,
        ReaderFailureKind.data,
        code: 'comic_reader_initial_load_failed',
        location: '加载漫画信息、目录或首章',
      );
      setState(() {
        _loading = false;
        _failure = failure;
      });
      _publishSnapshot();
      unawaited(_reportFailure(failure));
    }
  }

  Future<ComicChapterInfo?> _resolveSavedChapter(
    ComicReaderProgress saved,
  ) async {
    if (saved.chapterId.trim().isEmpty || saved.chapterIndex < 0) {
      unawaited(
        _reportFailure(
          const ReaderFailure(
            ReaderFailureKind.persistence,
            '已保存的漫画进度无效，已从首章开始',
          ),
        ),
      );
      return null;
    }
    final ComicChapterInfo? known = _catalogById[saved.chapterId];
    if (known != null) return known;
    if (saved.chapterIndex < 0 ||
        (_catalogTotal > 0 && saved.chapterIndex >= _catalogTotal)) {
      return null;
    }
    try {
      final ComicChapterInfo info = await _chapterAtIndex(saved.chapterIndex);
      if (info.id != saved.chapterId) return null;
      return info;
    } catch (error) {
      unawaited(_reportFailure(_asFailure(error, ReaderFailureKind.data)));
      return null;
    }
  }

  Future<void> _openChapterById(String chapterId) async {
    final String id = chapterId.trim();
    if (id.isEmpty) return;
    ComicChapterInfo? chapter = _catalogById[id];
    while (chapter == null && _catalogHasMore && !_disposed) {
      final bool loaded = await _loadNextCatalogPage();
      if (!loaded) break;
      chapter = _catalogById[id];
    }
    if (chapter == null) {
      unawaited(
        _reportFailure(
          const ReaderFailure(ReaderFailureKind.data, '找不到指定漫画章节'),
        ),
      );
      return;
    }
    await _openChapterInfo(chapter, replaceWindow: true);
  }

  Future<void> _openChapterInfo(
    ComicChapterInfo info, {
    ComicReaderProgress? restore,
    required bool replaceWindow,
    bool forceRefresh = false,
  }) async {
    final ComicReaderProgress? checkpoint = _progress;
    if (checkpoint != null) {
      unawaited(
        _queueProgressSave(
          store: widget.stateStore,
          bookId: widget.bookId,
          progress: checkpoint,
        ),
      );
    }
    _saveTimer?.cancel();
    final int navigation = ++_navigationGeneration;
    if (mounted) {
      setState(() {
        _loading = true;
        _failure = null;
        if (replaceWindow) {
          _boundaryLoads.clear();
          _boundaryFailures.clear();
          _beforeBoundaryIndex = null;
          _afterBoundaryIndex = null;
        }
      });
    }
    _publishSnapshot();
    try {
      final ComicChapterContent content = await _loadContent(
        info,
        forceRefresh: forceRefresh,
      );
      if (!_isNavigation(navigation)) return;
      if (replaceWindow) _window.clear();
      _window
        ..removeWhere((item) => item.info.id == info.id)
        ..add(_LoadedComicChapter(info, content))
        ..sort((a, b) => a.info.index.compareTo(b.info.index));
      _trimWindow(aroundIndex: info.index);
      _currentChapter = info;
      final ComicReaderProgress? resolvedRestore = _progressForContent(
        info,
        content,
        restore,
      );
      _progress = resolvedRestore;
      if (resolvedRestore != null) _scheduleProgressSave();
      _loading = false;
      _failure = null;
      _restoring = true;
      if (mounted) setState(() {});
      _publishSnapshot();
      unawaited(
        _notify(
          () => (widget.observer ?? const ComicReaderObserver())
              .onChapterChanged(info),
        ),
      );
      unawaited(_syncAwake());
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_isNavigation(navigation)) return;
        _restorePosition(resolvedRestore);
        _restoring = false;
        unawaited(_loadAdjacent(info.index - 1, before: true));
        unawaited(_loadAdjacent(info.index + 1, before: false));
      });
    } catch (error) {
      if (!_isNavigation(navigation)) return;
      final ReaderFailure failure = _asFailure(
        error,
        ReaderFailureKind.data,
        code: 'comic_chapter_load_failed',
        location: '加载漫画章节内容',
      );
      setState(() {
        _loading = false;
        _failure = failure;
      });
      _publishSnapshot();
      unawaited(_reportFailure(failure));
    }
  }

  ComicReaderProgress? _progressForContent(
    ComicChapterInfo info,
    ComicChapterContent content,
    ComicReaderProgress? requested,
  ) {
    if (content.images.isEmpty) return null;
    int imageIndex = 0;
    double imageFraction = 0;
    if (requested != null && requested.chapterId == info.id) {
      final int requestedIndex = content.images.indexWhere(
        (ComicImageInfo image) => image.id == requested.imageId,
      );
      if (requestedIndex >= 0 &&
          requested.imageFraction.isFinite &&
          requested.imageFraction >= 0 &&
          requested.imageFraction <= 1) {
        imageIndex = requestedIndex;
        imageFraction = requested.imageFraction;
      }
    }
    final double chapterFraction =
        (imageIndex + imageFraction) / content.images.length;
    final int total = _catalogTotal > 0 ? _catalogTotal : info.index + 1;
    return ComicReaderProgress(
      chapterId: info.id,
      imageId: content.images[imageIndex].id,
      imageFraction: imageFraction,
      chapterIndex: info.index,
      chapterFraction: chapterFraction.clamp(0, 1).toDouble(),
      bookFraction: ((info.index + chapterFraction) / total)
          .clamp(0, 1)
          .toDouble(),
    );
  }

  Future<ComicChapterContent> _loadContent(
    ComicChapterInfo info, {
    bool forceRefresh = false,
  }) {
    if (forceRefresh) {
      _contentEpochs[info.id] = (_contentEpochs[info.id] ?? 0) + 1;
      _contentCache.remove(info.id);
      _contentLoads.remove(info.id);
    }
    final ComicChapterContent? cached = _contentCache.remove(info.id);
    if (cached != null) {
      _contentCache[info.id] = cached;
      return Future<ComicChapterContent>.value(cached);
    }
    final Future<ComicChapterContent>? existing = _contentLoads[info.id];
    if (existing != null) return existing;
    final int session = _sessionGeneration;
    final int contentEpoch = _contentEpochs[info.id] ?? 0;
    final String bookId = widget.bookId;
    final ComicReaderDataSource source = widget.dataSource;
    late final Future<ComicChapterContent> load;
    load = source.loadChapterContent(bookId, info.id).then((
      ComicChapterContent content,
    ) {
      _validateContent(content, info);
      if (_isSessionForSource(session, bookId, source) &&
          contentEpoch == (_contentEpochs[info.id] ?? 0) &&
          identical(_contentLoads[info.id], load)) {
        _contentCache[info.id] = content;
        while (_contentCache.length >
            _ComicReaderViewState._metadataWindowLimit) {
          _contentCache.remove(_contentCache.keys.first);
        }
      }
      return content;
    });
    _contentLoads[info.id] = load;
    load.whenComplete(() {
      if (identical(_contentLoads[info.id], load)) {
        _contentLoads.remove(info.id);
      }
    }).ignore();
    return load;
  }

  Future<void> _loadAdjacent(int index, {required bool before}) async {
    if (_disposed ||
        index < 0 ||
        (_catalogTotal > 0 && index >= _catalogTotal) ||
        !_isBoundaryCursor(index, before: before) ||
        _window.any((chapter) => chapter.info.index == index) ||
        !_boundaryLoads.add(index)) {
      return;
    }
    if (mounted) setState(() => _boundaryFailures.remove(index));
    final int navigation = _navigationGeneration;
    var scanAdvanced = false;
    try {
      final ComicChapterInfo info = await _chapterAtIndex(index);
      final ComicChapterContent content = await _loadContent(info);
      if (!_isNavigation(navigation)) return;
      if (content.images.isEmpty && info.index != _currentChapter?.index) {
        if (!_isBoundaryCursor(index, before: before)) return;
        setState(() {
          if (before) {
            _beforeBoundaryIndex = index - 1;
          } else {
            _afterBoundaryIndex = index + 1;
          }
        });
        scanAdvanced = true;
        return;
      }
      if (!_isBoundaryCursor(index, before: before)) return;
      final double insertedExtent = _chapterExtent(content);
      double removedFromTop = 0;
      setState(() {
        if (before) {
          _beforeBoundaryIndex = index - 1;
        } else {
          _afterBoundaryIndex = index + 1;
        }
        _window
          ..add(_LoadedComicChapter(info, content))
          ..sort((a, b) => a.info.index.compareTo(b.info.index));
        removedFromTop = _trimWindow(
          aroundIndex: _currentChapter?.index ?? info.index,
        );
      });
      final double offsetDelta =
          (before ? _beforeInsertionExtent(index, insertedExtent) : 0) -
          removedFromTop;
      if (offsetDelta != 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!_isNavigation(navigation) || !_scrollController.hasClients) {
            return;
          }
          _restoring = true;
          // Keep wheel/trackpad movement received during this frame instead of
          // restoring the stale offset captured before the prepend layout.
          final double liveOffset = _scrollController.offset;
          _scrollController.jumpTo(
            (liveOffset + offsetDelta).clamp(
              0,
              _scrollController.position.maxScrollExtent,
            ),
          );
          _restoring = false;
        });
      }
    } catch (error) {
      if (!_isNavigation(navigation)) return;
      final ReaderFailure failure = _asFailure(error, ReaderFailureKind.data);
      setState(() => _boundaryFailures[index] = failure);
      unawaited(_reportFailure(failure));
    } finally {
      if (_isNavigation(navigation)) {
        _boundaryLoads.remove(index);
        if (mounted) setState(() {});
        if (scanAdvanced) {
          unawaited(
            _loadAdjacent(before ? index - 1 : index + 1, before: before),
          );
        }
      }
    }
  }

  bool _isBoundaryCursor(int index, {required bool before}) {
    if (_window.isEmpty) return false;
    final int expected = before
        ? (_beforeBoundaryIndex ?? _window.first.info.index - 1)
        : (_afterBoundaryIndex ?? _window.last.info.index + 1);
    return index == expected;
  }

  Future<ComicChapterInfo> _chapterAtIndex(int index) async {
    final ComicChapterInfo? known = _catalogByIndex[index];
    if (known != null) return known;
    final Future<ComicChapterInfo>? existing = _chapterInfoLoads[index];
    if (existing != null) return existing;
    final int session = _sessionGeneration;
    final String bookId = widget.bookId;
    final ComicReaderDataSource source = widget.dataSource;
    late final Future<ComicChapterInfo> load;
    load = source.loadChapterAtIndex(bookId, index).then((info) {
      _validateChapterInfo(info, expectedIndex: index);
      if (!_isSessionForSource(session, bookId, source)) {
        throw StateError('Stale comic chapter request.');
      }
      _rememberChapter(info);
      return info;
    });
    _chapterInfoLoads[index] = load;
    load.whenComplete(() {
      if (identical(_chapterInfoLoads[index], load)) {
        _chapterInfoLoads.remove(index);
      }
    }).ignore();
    return load;
  }

  double _trimWindow({required int aroundIndex}) {
    double removedFromTop = 0;
    while (_window.length > _ComicReaderViewState._metadataWindowLimit) {
      final int firstDistance = (_window.first.info.index - aroundIndex).abs();
      final int lastDistance = (_window.last.info.index - aroundIndex).abs();
      if (firstDistance > lastDistance) {
        final _LoadedComicChapter removed = _window.first;
        final double oldBoundary = removed.info.index > 0
            ? _ComicReaderViewState._boundaryExtent
            : 0;
        _window.removeAt(0);
        _beforeBoundaryIndex = removed.info.index;
        final double newBoundary = _window.first.info.index > 0
            ? _ComicReaderViewState._boundaryExtent
            : 0;
        removedFromTop +=
            _chapterExtent(removed.content) + oldBoundary - newBoundary;
      } else {
        final _LoadedComicChapter removed = _window.removeLast();
        _afterBoundaryIndex = removed.info.index;
      }
    }
    final Set<String> retained = _window.map((e) => e.info.id).toSet();
    for (final String id in _contentCache.keys.toList()) {
      if (!retained.contains(id)) _contentCache.remove(id);
    }
    return removedFromTop;
  }

  double _beforeInsertionExtent(int index, double chapterExtent) =>
      chapterExtent +
      (index > 0 ? _ComicReaderViewState._boundaryExtent : 0) -
      _ComicReaderViewState._boundaryExtent;

  Future<void> _nextChapter() async {
    final ComicChapterInfo? current = _currentChapter;
    if (current == null) return;
    final int next = current.index + 1;
    if (_catalogTotal > 0 && next >= _catalogTotal) return;
    try {
      await _openChapterInfo(await _chapterAtIndex(next), replaceWindow: true);
    } catch (error) {
      unawaited(_reportFailure(_asFailure(error, ReaderFailureKind.data)));
    }
  }

  Future<void> _previousChapter() async {
    final ComicChapterInfo? current = _currentChapter;
    if (current == null || current.index <= 0) return;
    try {
      await _openChapterInfo(
        await _chapterAtIndex(current.index - 1),
        replaceWindow: true,
      );
    } catch (error) {
      unawaited(_reportFailure(_asFailure(error, ReaderFailureKind.data)));
    }
  }

  Future<void> _refreshCurrentChapter() async {
    final ComicChapterInfo? current = _currentChapter;
    if (current == null) return;
    _imageCache.removeChapter(current.id);
    await _openChapterInfo(
      current,
      restore: _progress,
      replaceWindow: true,
      forceRefresh: true,
    );
  }

  void _restorePosition(ComicReaderProgress? saved) {
    if (!_scrollController.hasClients || _window.isEmpty) return;
    double anchorOffset = _topPadding;
    bool found = false;
    for (final _ComicListEntry entry in _entries()) {
      if (entry is _ComicImageEntry &&
          saved != null &&
          entry.chapter.info.id == saved.chapterId &&
          entry.image.id == saved.imageId) {
        anchorOffset +=
            entry.placeholderExtent * saved.imageFraction.clamp(0, 1);
        found = true;
        break;
      }
      if (saved == null &&
          entry is _ComicImageEntry &&
          entry.chapter.info.id == _currentChapter?.id) {
        found = true;
        break;
      }
      anchorOffset += entry.extent;
    }
    if (!found) anchorOffset = _topPadding;
    final double offset =
        anchorOffset -
        _viewportHeight * _ComicReaderViewState._progressProbeFraction;
    _scrollController.jumpTo(
      offset.clamp(0, _scrollController.position.maxScrollExtent),
    );
    _updateProgressFromScroll();
  }

  void _handleScroll() {
    if (_disposed || _restoring || !_scrollController.hasClients) return;
    final double offset = _scrollController.offset;
    final double? previousOffset = _lastObservedScrollOffset;
    if (previousOffset != null && offset != previousOffset) {
      _prefetchForward = offset > previousOffset;
    }
    _lastObservedScrollOffset = offset;
    _updateProgressFromScroll();
    final ScrollPosition position = _scrollController.position;
    final double trigger = position.viewportDimension * 1.5;
    if (position.extentAfter < trigger && _window.isNotEmpty) {
      unawaited(
        _loadAdjacent(
          _afterBoundaryIndex ?? _window.last.info.index + 1,
          before: false,
        ),
      );
    }
    if (position.extentBefore < trigger && _window.isNotEmpty) {
      unawaited(
        _loadAdjacent(
          _beforeBoundaryIndex ?? _window.first.info.index - 1,
          before: true,
        ),
      );
    }
  }

  void _updateProgressFromScroll() {
    if (_window.isEmpty || _viewportWidth <= 0) return;
    final double probe =
        _scrollController.offset +
        _viewportHeight * _ComicReaderViewState._progressProbeFraction;
    final ({_ComicImageEntry entry, double fraction})? measured =
        _imageAtViewportProbe();
    _ComicImageEntry? selected = measured?.entry;
    double fraction = measured?.fraction ?? 0;
    if (selected == null) {
      final List<_ComicListEntry> entries = _entries();
      final int candidate = _entryIndexAt(probe - _topPadding);
      for (int index = candidate; index < entries.length; index++) {
        final _ComicListEntry entry = entries[index];
        if (entry is! _ComicImageEntry) continue;
        selected = entry;
        final double start = _entryStarts[index] + _topPadding;
        fraction = ((probe - start) / entry.placeholderExtent)
            .clamp(0, 1)
            .toDouble();
        break;
      }
    }
    if (selected == null) return;
    final _LoadedComicChapter chapter = selected.chapter;
    final int imageIndex = selected.image.index.clamp(
      0,
      chapter.content.images.length - 1,
    );
    final double chapterFraction = chapter.content.images.isEmpty
        ? 0
        : (imageIndex + fraction) / chapter.content.images.length;
    final int total = _catalogTotal > 0
        ? _catalogTotal
        : _catalogByIndex.keys.fold<int>(1, (max, value) {
            final int count = value + 1;
            return count > max ? count : max;
          });
    final ComicReaderProgress next = ComicReaderProgress(
      chapterId: chapter.info.id,
      imageId: selected.image.id,
      imageFraction: fraction,
      chapterIndex: chapter.info.index,
      chapterFraction: chapterFraction.clamp(0, 1).toDouble(),
      bookFraction: ((chapter.info.index + chapterFraction) / total)
          .clamp(0, 1)
          .toDouble(),
    );
    final bool chapterChanged = _currentChapter?.id != chapter.info.id;
    _progress = next;
    if (chapterChanged) {
      _currentChapter = chapter.info;
      if (mounted) setState(() {});
      unawaited(
        _notify(
          () => (widget.observer ?? const ComicReaderObserver())
              .onChapterChanged(chapter.info),
        ),
      );
    }
    if (chapterChanged) _scheduleProgressSave();
    _scheduleSnapshotPublish();
    _prefetchAround(selected);
  }

  void _prefetchAround(_ComicImageEntry selected) {
    if (!_firstContentPresented) return;
    final List<_ComicListEntry> entries = _entries();
    final int index =
        _imageEntryIndexes['${selected.chapter.info.id}\u0000${selected.image.id}'] ??
        -1;
    if (index < 0) return;
    final int aheadStep = _prefetchForward ? 1 : -1;
    _prefetchImages(entries, startIndex: index, step: aheadStep, limit: 6);
    _prefetchImages(entries, startIndex: index, step: -aheadStep, limit: 2);
  }

  void _prefetchImages(
    List<_ComicListEntry> entries, {
    required int startIndex,
    required int step,
    required int limit,
  }) {
    int loaded = 0;
    for (
      int candidate = startIndex + step;
      candidate >= 0 && candidate < entries.length && loaded < limit;
      candidate += step
    ) {
      final _ComicListEntry entry = entries[candidate];
      if (entry is! _ComicImageEntry) continue;
      _imageCache.prefetch(entry.chapter.info.id, entry.image);
      loaded++;
    }
  }

  ({_ComicImageEntry entry, double fraction})? _imageAtViewportProbe() {
    final RenderBox? surface =
        _readingSurfaceKey.currentContext?.findRenderObject() as RenderBox?;
    if (surface == null || !surface.hasSize) return null;
    final double probeY = surface
        .localToGlobal(
          Offset(
            0,
            _viewportHeight * _ComicReaderViewState._progressProbeFraction,
          ),
        )
        .dy;
    for (final _ComicListEntry entry in _entries()) {
      if (entry is! _ComicImageEntry) continue;
      final RenderBox? image =
          _imageKeys['${entry.chapter.info.id}\u0000${entry.image.id}']
                  ?.currentContext
                  ?.findRenderObject()
              as RenderBox?;
      if (image == null || !image.hasSize || image.size.height <= 0) continue;
      final double top = image.localToGlobal(Offset.zero).dy;
      if (probeY < top || probeY > top + image.size.height) continue;
      return (
        entry: entry,
        fraction: ((probeY - top) / image.size.height).clamp(0, 1).toDouble(),
      );
    }
    return null;
  }

  void _scheduleProgressSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(_ComicReaderViewState._saveDelay, _flushProgress);
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
  }) {
    final ComicReaderProgress durableProgress = _chapterStartProgress(progress);
    final _BookStoreKey stateKey = _BookStoreKey(store, bookId);
    final String writeKey =
        '${durableProgress.chapterId}\u0000'
        '${durableProgress.chapterIndex}';
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

  /// Keeps exact image coordinates transient while persisting only a stable
  /// chapter-start anchor until image-position restoration is reliable.
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
