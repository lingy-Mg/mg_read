/// Session navigation, semantic progress and image geometry reconciliation.
/// Restore operations use the extent index until jumpTo has been laid out.
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
    _boundaryLoadOwners.clear();
    _catalogCursors.clear();
    _catalogCursor = null;
    _catalogTotal = 0;
    _catalogHasMore = false;
    _catalogLoading = false;
    _catalogPageCoverage = 0;
    _afterBoundaryIndex = null;
    _book = null;
    _currentChapter = null;
    _pendingChapter = null;
    _progress = null;
    _pendingExactRestore = null;
    _preferences = ComicReaderPreferences.defaults;
    _preferencesAuthoritative = false;
    _bookmarks = const <ComicReaderBookmark>[];
    _firstContentPresented = false;
    _preloader?.cancel();
    _imageRetryCoordinator.clear();
    _layoutCorrection = 0;
    _failure = null;
    _loading = true;
    if (mounted) setState(() {});
    _publishSnapshot();
    await _initialize(
      generation: generation,
      preferenceOverride: preferenceOverride,
    );
  }

  Future<void> _refreshCatalogFromHost() async {
    if (_catalogLoading) return;
    final int generation = _sessionGeneration;
    final ComicReaderDataSource dataSource = widget.dataSource;
    final String bookId = widget.bookId;
    try {
      if (dataSource case final ReaderCatalogRefreshDataSource refreshable) {
        await refreshable.refreshCatalog(bookId);
      }
      if (!_isSessionForSource(generation, bookId, dataSource)) return;
      final current = _currentChapter;
      _catalog.clear();
      _catalogById.clear();
      _catalogByIndex.clear();
      _catalogCursors.clear();
      _catalogCursor = null;
      _catalogTotal = 0;
      _catalogHasMore = false;
      _catalogPageCoverage = 0;
      final page = await dataSource.loadChapterCatalog(
        bookId,
        pageSize: _ComicReaderViewState._catalogPageSize,
      );
      if (!_isSessionForSource(generation, bookId, dataSource)) return;
      _mergeCatalog(page, requestedCursor: null);
      if (current != null && !_catalogById.containsKey(current.id)) {
        _rememberChapter(current);
      }
      if (current != null) {
        _currentChapter = _catalogById[current.id] ?? current;
      }
      if (mounted) setState(() {});
      _publishSnapshot();
    } on Object {
      // A silent background signal must never interrupt an active chapter.
    }
  }

  Future<void> _refreshBookFromHost() async {
    final ReaderBookRefreshCapability? capability =
        widget.bookRefreshCapability;
    if (capability == null || _bookRefreshLoading) return;
    if (mounted) setState(() => _bookRefreshLoading = true);
    _activeCatalogRevision?.value++;
    try {
      await capability.refresh(widget.bookId);
      await _refreshCatalogFromHost();
      final int generation = _sessionGeneration;
      final ComicBookInfo book = await widget.dataSource.loadBookInfo(
        widget.bookId,
      );
      if (!_isSessionForSource(generation, widget.bookId, widget.dataSource) ||
          !mounted) {
        return;
      }
      setState(() => _book = book);
      _publishSnapshot();
    } catch (error) {
      await _reportFailure(_asFailure(error, ReaderFailureKind.data));
    } finally {
      if (mounted) setState(() => _bookRefreshLoading = false);
      _activeCatalogRevision?.value++;
    }
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
      await _openChapterInfo(
        target,
        restore: _supportsPreciseProgress ? saved : null,
        replaceWindow: true,
      );
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
    _beginChapterLookup();
    ComicChapterInfo? chapter = _catalogById[id];
    while (chapter == null && _catalogHasMore && !_disposed) {
      final bool loaded = await _loadNextCatalogPage();
      if (!loaded) break;
      chapter = _catalogById[id];
    }
    if (chapter == null) {
      _endChapterLookup();
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
    _pendingChapter = info;
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
    _pendingExactRestore = null;
    _preloader?.cancel();
    _layoutCorrection = 0;
    final int navigation = ++_navigationGeneration;
    if (mounted) {
      setState(() {
        _loading = true;
        _failure = null;
        if (replaceWindow) {
          _boundaryLoadOwners.clear();
          _boundaryFailures.clear();
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
      _pendingChapter = null;
      _startChapterPreload();
      final ComicReaderProgress? resolvedRestore = _progressForContent(
        info,
        content,
        restore,
      );
      _progress = resolvedRestore;
      _pendingExactRestore = _supportsPreciseProgress && restore != null
          ? resolvedRestore
          : null;
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
        if (content.images.isEmpty) {
          unawaited(_loadNextAdjacent(info.index + 1));
        }
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

  Future<void> _loadNextAdjacent(int index) async {
    if (_disposed ||
        index < 0 ||
        (_catalogTotal > 0 && index >= _catalogTotal) ||
        !_isNextBoundaryCursor(index) ||
        _window.any((chapter) => chapter.info.index == index) ||
        _boundaryLoadOwners.containsKey(index)) {
      return;
    }
    final int owner = ++_nextBoundaryLoadOwner;
    _boundaryLoadOwners[index] = owner;
    if (mounted) setState(() => _boundaryFailures.remove(index));
    final int navigation = _navigationGeneration;
    var scanAdvanced = false;
    try {
      final ComicChapterInfo info = await _chapterAtIndex(index);
      final ComicChapterContent content = await _loadContent(info);
      if (!_isNavigation(navigation)) return;
      if (content.images.isEmpty && info.index != _currentChapter?.index) {
        if (!_isNextBoundaryCursor(index)) return;
        setState(() => _afterBoundaryIndex = index + 1);
        scanAdvanced = true;
        return;
      }
      if (!_isNextBoundaryCursor(index)) return;
      double removedFromTop = 0;
      setState(() {
        _afterBoundaryIndex = index + 1;
        _window
          ..add(_LoadedComicChapter(info, content))
          ..sort((a, b) => a.info.index.compareTo(b.info.index));
        removedFromTop = _trimWindow(
          aroundIndex: _currentChapter?.index ?? info.index,
        );
      });
      if (removedFromTop != 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!_isNavigation(navigation) || !_scrollController.hasClients) {
            return;
          }
          _restoring = true;
          // Preserve the visible content when a now-distant chapter is
          // removed from the top of the forward-only window.
          final double liveOffset = _scrollController.offset;
          _scrollController.jumpTo(
            (liveOffset - removedFromTop).clamp(
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
      if (_boundaryLoadOwners[index] == owner) {
        _boundaryLoadOwners.remove(index);
        if (mounted && _isNavigation(navigation)) setState(() {});
        if (_isNavigation(navigation) && scanAdvanced) {
          unawaited(_loadNextAdjacent(index + 1));
        }
      }
    }
  }

  bool _isNextBoundaryCursor(int index) {
    if (_window.isEmpty) return false;
    final int expected = _afterBoundaryIndex ?? _window.last.info.index + 1;
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
        _window.removeAt(0);
        removedFromTop += _chapterExtent(removed.content);
      } else {
        final _LoadedComicChapter removed = _window.removeLast();
        _afterBoundaryIndex = removed.info.index;
      }
    }
    final Set<String> retained = _window.map((e) => e.info.id).toSet();
    _imageCache.retainGeometry(retained);
    _imageKeys.removeWhere((key, _) {
      final bool remove = !retained.contains(key.split('\u0000').first);
      if (remove) _imageRetryCoordinator.remove(key);
      return remove;
    });
    for (final String id in _contentCache.keys.toList()) {
      if (!retained.contains(id)) _contentCache.remove(id);
    }
    return removedFromTop;
  }

  Future<void> _nextChapter() async {
    final ComicChapterInfo? current = _currentChapter;
    if (current == null) return;
    final int next = current.index + 1;
    if (_catalogTotal > 0 && next >= _catalogTotal) return;
    _beginChapterLookup();
    try {
      await _openChapterInfo(await _chapterAtIndex(next), replaceWindow: true);
    } catch (error) {
      _endChapterLookup();
      unawaited(_reportFailure(_asFailure(error, ReaderFailureKind.data)));
    }
  }

  Future<void> _previousChapter() async {
    final ComicChapterInfo? current = _currentChapter;
    if (current == null || current.index <= 0) return;
    _beginChapterLookup();
    try {
      await _openChapterInfo(
        await _chapterAtIndex(current.index - 1),
        replaceWindow: true,
      );
    } catch (error) {
      _endChapterLookup();
      unawaited(_reportFailure(_asFailure(error, ReaderFailureKind.data)));
    }
  }

  void _beginChapterLookup() {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _failure = null;
    });
    _publishSnapshot();
  }

  void _endChapterLookup() {
    if (!mounted) return;
    setState(() => _loading = false);
    _publishSnapshot();
  }

  Future<void> _refreshCurrentChapter() async {
    final ComicChapterInfo? target = _pendingChapter ?? _currentChapter;
    if (target == null) return;
    _imageCache.removeChapter(target.id);
    await _openChapterInfo(
      target,
      restore: target.id == _currentChapter?.id ? _progress : null,
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
    if (!_supportsPreciseProgress || _pendingExactRestore == null) {
      _updateProgressFromScroll(useRenderedPosition: false);
    }
  }

  void _handleScroll() {
    if (_disposed || _restoring || !_scrollController.hasClients) return;
    _imageRetryCoordinator.onViewportChanged();
    _updateProgressFromScroll();
    if (_supportsPreciseProgress) _schedulePreciseProgressProbe();
    final ScrollPosition position = _scrollController.position;
    final double trigger = position.viewportDimension * 1.5;
    if (position.extentAfter < trigger && _window.isNotEmpty) {
      unawaited(
        _loadNextAdjacent(_afterBoundaryIndex ?? _window.last.info.index + 1),
      );
    }
  }

  bool _isImageNearViewport(String key) {
    final RenderBox? surface =
        _readingSurfaceKey.currentContext?.findRenderObject() as RenderBox?;
    final RenderBox? image =
        _imageKeys[key]?.currentContext?.findRenderObject() as RenderBox?;
    if (surface == null ||
        image == null ||
        !surface.hasSize ||
        !image.hasSize) {
      return false;
    }
    final double surfaceTop = surface.localToGlobal(Offset.zero).dy;
    final double imageTop = image.localToGlobal(Offset.zero).dy - surfaceTop;
    final double padding = surface.size.height * .75;
    return imageTop + image.size.height >= -padding &&
        imageTop <= surface.size.height + padding;
  }

  void _updateProgressFromScroll({bool useRenderedPosition = true}) {
    if (_supportsPreciseProgress && _pendingExactRestore != null) return;
    if (_window.isEmpty || _viewportWidth <= 0) return;
    final double probe =
        _scrollController.offset +
        _viewportHeight * _ComicReaderViewState._progressProbeFraction;
    final ({_ComicImageEntry entry, double fraction})? measured =
        useRenderedPosition ? _imageAtViewportProbe() : null;
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
    final ComicReaderProgress? previous = _progress;
    final bool chapterChanged = _currentChapter?.id != chapter.info.id;
    final bool positionChanged =
        previous?.chapterId != next.chapterId ||
        previous?.imageId != next.imageId ||
        (previous?.imageFraction ?? -1) != next.imageFraction;
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
    if (chapterChanged || (_supportsPreciseProgress && positionChanged)) {
      _scheduleProgressSave();
    }
    _scheduleSnapshotPublish();
    _startChapterPreload();
  }

  void _startChapterPreload() {
    if (_disposed || !_foreground || _currentChapter == null) return;
    final chapters = _window.where((c) => c.info.id == _currentChapter!.id);
    if (chapters.isEmpty) return;
    final chapter = chapters.first;
    final int navigation = _navigationGeneration;
    (_preloader ??= ComicChapterPreloader(
      _imageCache,
      onProgress: _updateChapterCacheProgress,
    )).start(
      chapter.content,
      followingChapterCount: widget.chapterPreloadCount,
      followingChapter: (int offset) async {
        final int index = chapter.info.index + offset;
        if (!_isNavigation(navigation) ||
            (_catalogTotal > 0 && index >= _catalogTotal)) {
          return null;
        }
        if (offset == 1) {
          await _loadNextAdjacent(index);
          if (!_isNavigation(navigation)) return null;
          final Iterable<_LoadedComicChapter> adjacent = _window.where(
            (_LoadedComicChapter item) => item.info.index == index,
          );
          return adjacent.isEmpty ? null : adjacent.first.content;
        }
        final ComicChapterInfo info = await _chapterAtIndex(index);
        if (!_isNavigation(navigation)) return null;
        final ComicChapterContent content = await _loadContent(info);
        return _isNavigation(navigation) ? content : null;
      },
    );
  }

  void _updateChapterCacheProgress(
    ComicChapterContent content,
    int cachedImageCount,
    int failedImageCount,
  ) {
    if (_disposed) return;
    final ComicChapterInfo? existing = _catalogById[content.chapterId];
    if (existing == null) return;
    final int imageCount = content.images.length;
    final bool finished = cachedImageCount + failedImageCount >= imageCount;
    final ReaderChapterAvailability availability =
        failedImageCount > 0 && finished
        ? ReaderChapterAvailability.failed
        : cachedImageCount == imageCount
        ? ReaderChapterAvailability.downloaded
        : ReaderChapterAvailability.downloading;
    final updated = ComicChapterInfo(
      id: existing.id,
      title: existing.title,
      index: existing.index,
      availability: availability,
      imageCount: imageCount,
      cachedImageCount: cachedImageCount,
      failedImageCount: failedImageCount,
      manifestCached: true,
      hasBeenRead: existing.hasBeenRead,
    );
    _catalogById[updated.id] = updated;
    _catalogByIndex[updated.index] = updated;
    final int catalogIndex = _catalog.indexWhere(
      (ComicChapterInfo chapter) => chapter.id == updated.id,
    );
    if (catalogIndex >= 0) _catalog[catalogIndex] = updated;
    for (var index = 0; index < _window.length; index++) {
      final loaded = _window[index];
      if (loaded.info.id == updated.id) {
        _window[index] = _LoadedComicChapter(updated, loaded.content);
      }
    }
    if (_pendingChapter?.id == updated.id) _pendingChapter = updated;
    if (_currentChapter?.id == updated.id) {
      _currentChapter = updated;
      if (finished || cachedImageCount == 0) _scheduleSnapshotPublish();
    }
    final revision = _activeCatalogRevision;
    if (revision != null) revision.value++;
  }

  double _takeLayoutCorrection() {
    final correction = _layoutCorrection;
    _layoutCorrection = 0;
    return correction;
  }

  void _scheduleDimensionsUpdate() {
    if (_disposed || _dimensionsUpdateScheduled) return;
    _dimensionsUpdateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _dimensionsUpdateScheduled = false;
      if (mounted && !_disposed) setState(() {});
    });
    WidgetsBinding.instance.ensureVisualUpdate();
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
}
