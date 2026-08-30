part of 'comic_reader_view.dart';

// ignore_for_file: invalid_use_of_protected_member

extension _ComicReaderPreferences on _ComicReaderViewState {
  Future<void> _savePreferences(
    ComicReaderPreferences value, {
    ComicReaderStateStore? store,
  }) {
    final ComicReaderPreferences normalized = value.normalized();
    final ComicReaderStateStore targetStore = store ?? widget.stateStore;
    final String writeKey =
        '${normalized.brightness}\u0000${normalized.imageSpacing}\u0000'
        '${normalized.keepScreenOn}\u0000${normalized.immersiveMode}';
    if (_lastPreferenceWriteKeys[targetStore] == writeKey) {
      return _preferenceWrites[targetStore] ?? Future<void>.value();
    }
    _lastPreferenceWriteKeys[targetStore] = writeKey;
    return _enqueueStoreWrite(
      _preferenceWrites,
      targetStore,
      () => targetStore.savePreferences(normalized),
      (Object error) {
        if (_lastPreferenceWriteKeys[targetStore] == writeKey) {
          _lastPreferenceWriteKeys.remove(targetStore);
        }
        if (identical(targetStore, widget.stateStore) &&
            normalized.brightness == _preferences.brightness &&
            normalized.imageSpacing == _preferences.imageSpacing &&
            normalized.keepScreenOn == _preferences.keepScreenOn &&
            normalized.immersiveMode == _preferences.immersiveMode) {
          _preferencesDirty = true;
        }
        if (!_disposed && identical(targetStore, widget.stateStore)) {
          unawaited(_reportFailure(_stateFailure(error)));
        }
      },
    );
  }

  Future<void> _commitPreferences() {
    if (!_preferencesDirty) {
      return _preferenceWrites[widget.stateStore] ?? Future<void>.value();
    }
    _preferencesDirty = false;
    return _savePreferences(_preferences);
  }

  Future<void> _enqueueStoreWrite<K>(
    Map<K, Future<void>> queue,
    K key,
    Future<void> Function() operation,
    void Function(Object error) onError,
  ) {
    final Future<void> previous = queue[key] ?? Future<void>.value();
    late final Future<void> next;
    next = previous
        .then((_) => Future<void>.sync(operation))
        .catchError((Object error, StackTrace stackTrace) => onError(error))
        .whenComplete(() {
          if (identical(queue[key], next)) queue.remove(key);
        });
    queue[key] = next;
    return next;
  }

  Future<void> _loadPlatformCapabilities() async {
    try {
      final ReaderPlatformCapabilities capabilities = await ReaderPlatform
          .instance
          .capabilities();
      if (_disposed) return;
      setState(() => _platformCapabilities = capabilities);
      unawaited(_syncAwake());
    } catch (error) {
      if (!_disposed) {
        unawaited(
          _reportFailure(_asFailure(error, ReaderFailureKind.platform)),
        );
      }
    }
  }

  void _handleLifecycle(AppLifecycleState state) {
    final ReaderLifecycleState normalized = switch (state) {
      AppLifecycleState.resumed => ReaderLifecycleState.foreground,
      AppLifecycleState.inactive => ReaderLifecycleState.inactive,
      AppLifecycleState.hidden ||
      AppLifecycleState.paused => ReaderLifecycleState.background,
      AppLifecycleState.detached => ReaderLifecycleState.detached,
    };
    if (_lifecycleState == normalized) return;
    _lifecycleState = normalized;
    _foreground = normalized == ReaderLifecycleState.foreground;
    if (_foreground) {
      unawaited(_syncAwake());
    } else {
      unawaited(_releaseAwake());
      unawaited(_flushProgress());
      if (_preferencesDirty) unawaited(_commitPreferences());
    }
    final ComicReaderProgress? progress = _progress;
    unawaited(
      _notify(
        () => (widget.observer ?? const ComicReaderObserver())
            .onLifecycleChanged(normalized, progress),
      ),
    );
  }

  Future<void> _syncAwake() => _reconcileAwake();

  Future<void> _reconcileAwake() async {
    final bool keep =
        _preferences.keepScreenOn && _platformCapabilities.keepScreenOn;
    final bool immersive =
        _preferences.immersiveMode && _platformCapabilities.immersiveMode;
    final bool wanted =
        !_disposed &&
        _foreground &&
        _currentChapter != null &&
        (keep || immersive);
    try {
      if (wanted) {
        await ScreenAwakeCoordinator.instance.acquire(
          _awakeHolder,
          keepScreenOn: keep,
          immersiveMode: immersive,
        );
      } else {
        await ScreenAwakeCoordinator.instance.release(_awakeHolder);
      }
    } catch (error) {
      unawaited(_reportFailure(_asFailure(error, ReaderFailureKind.platform)));
    }
  }

  Future<void> _releaseAwake() {
    // `release` removes the holder synchronously before its platform Future is
    // returned, so background/dispose never queue behind a hung acquire.
    try {
      return ScreenAwakeCoordinator.instance.release(_awakeHolder).catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        unawaited(
          _reportFailure(_asFailure(error, ReaderFailureKind.platform)),
        );
      });
    } catch (error) {
      unawaited(_reportFailure(_asFailure(error, ReaderFailureKind.platform)));
      return Future<void>.value();
    }
  }

  Future<void> _requestExit() {
    final Future<void>? current = _exitRequest;
    if (current != null) return current;
    final ComicReaderProgress? progress = _progress;
    final ComicReaderObserver observer =
        widget.observer ?? const ComicReaderObserver();
    final Future<void> request = () async {
      unawaited(_flushProgress());
      if (_preferencesDirty) unawaited(_commitPreferences());
      unawaited(_releaseAwake());
      await _notify(() => observer.onExitRequested(progress));
    }();
    _exitRequest = request.whenComplete(() => _exitRequest = null);
    return _exitRequest!;
  }

  void _setControlsVisible(bool value) {
    if (_disposed || _controlsVisible == value) return;
    setState(() => _controlsVisible = value);
    _publishSnapshot();
  }

  void _publishSnapshot() {
    _controller.updateSnapshot(
      ComicReaderSnapshot(
        isReady: _currentChapter != null && _failure == null,
        isLoading: _loading,
        controlsVisible: _controlsVisible,
        book: _book,
        chapter: _currentChapter,
        progress: _progress,
        failure: _failure,
      ),
      owner: _controllerOwner,
    );
  }

  void _scheduleSnapshotPublish() {
    if (_snapshotTimer?.isActive ?? false) return;
    _snapshotTimer = Timer(const Duration(milliseconds: 80), () {
      if (!_disposed) _publishSnapshot();
    });
  }

  Future<bool> _loadNextCatalogPage() async {
    if (_catalogLoading || !_catalogHasMore) return false;
    final String? cursor = _catalogCursor;
    final int session = _sessionGeneration;
    final String bookId = widget.bookId;
    final ComicReaderDataSource source = widget.dataSource;
    _catalogLoading = true;
    if (mounted) setState(() {});
    try {
      final ComicChapterCatalogPage page = await source.loadChapterCatalog(
        bookId,
        cursor: cursor,
        pageSize: _ComicReaderViewState._catalogPageSize,
      );
      if (!_isSessionForSource(session, bookId, source)) return false;
      _mergeCatalog(page, requestedCursor: cursor);
      return true;
    } catch (error) {
      if (_isSessionForSource(session, bookId, source)) {
        unawaited(_reportFailure(_asFailure(error, ReaderFailureKind.data)));
      }
      return false;
    } finally {
      if (_isSessionForSource(session, bookId, source)) {
        _catalogLoading = false;
        if (mounted) setState(() {});
      }
    }
  }

  void _mergeCatalog(
    ComicChapterCatalogPage page, {
    required String? requestedCursor,
  }) {
    if (page.total < 0 ||
        (_catalogTotal > 0 && page.total != _catalogTotal) ||
        (page.hasMore && page.items.isEmpty) ||
        (!page.hasMore && page.nextCursor != null) ||
        (requestedCursor == null &&
            page.total > 0 &&
            (page.items.isEmpty || page.items.first.index != 0)) ||
        (page.hasMore &&
            (page.nextCursor == null ||
                page.nextCursor!.trim().isEmpty ||
                page.nextCursor == requestedCursor ||
                _catalogCursors.contains(page.nextCursor)))) {
      throw StateError('Invalid comic catalog cursor response.');
    }
    final Map<String, ComicChapterInfo> nextById =
        Map<String, ComicChapterInfo>.of(_catalogById);
    final Map<int, ComicChapterInfo> nextByIndex =
        Map<int, ComicChapterInfo>.of(_catalogByIndex);
    var expectedPageIndex = requestedCursor == null ? 0 : _catalogPageCoverage;
    for (final ComicChapterInfo info in page.items) {
      _validateChapterInfo(info);
      if (info.index != expectedPageIndex) {
        throw StateError('Comic catalog page did not advance contiguously.');
      }
      expectedPageIndex++;
      final ComicChapterInfo? byId = nextById[info.id];
      final ComicChapterInfo? byIndex = nextByIndex[info.index];
      if ((byId != null && byId.index != info.index) ||
          (byIndex != null && byIndex.id != info.id)) {
        throw StateError('Comic catalog identifiers are inconsistent.');
      }
      nextById[info.id] = info;
      nextByIndex[info.index] = info;
    }
    final int knownCount = nextByIndex.keys.fold<int>(0, (count, index) {
      final int candidate = index + 1;
      return candidate > count ? candidate : count;
    });
    if (page.total < knownCount) {
      throw StateError(
        'Comic catalog total is smaller than its chapter index.',
      );
    }
    if (!page.hasMore && expectedPageIndex != page.total) {
      throw StateError(
        'Comic catalog ended before all chapters were supplied.',
      );
    }
    _catalogById
      ..clear()
      ..addAll(nextById);
    _catalogByIndex
      ..clear()
      ..addAll(nextByIndex);
    _catalog
      ..clear()
      ..addAll(nextByIndex.values)
      ..sort((a, b) => a.index.compareTo(b.index));
    _catalogTotal = page.total;
    _catalogPageCoverage = expectedPageIndex;
    _catalogHasMore = page.hasMore;
    _catalogCursor = page.nextCursor;
    if (page.nextCursor != null) _catalogCursors.add(page.nextCursor!);
  }

  void _rememberChapter(ComicChapterInfo info) {
    _validateChapterInfo(info);
    final ComicChapterInfo? byId = _catalogById[info.id];
    final ComicChapterInfo? byIndex = _catalogByIndex[info.index];
    if ((byId != null && byId.index != info.index) ||
        (byIndex != null && byIndex.id != info.id)) {
      throw StateError('Comic catalog identifiers are inconsistent.');
    }
    _catalogById[info.id] = info;
    _catalogByIndex[info.index] = info;
    final int existing = _catalog.indexWhere((entry) => entry.id == info.id);
    if (existing < 0) {
      _catalog.add(info);
    } else {
      _catalog[existing] = info;
    }
    _catalog.sort((a, b) => a.index.compareTo(b.index));
  }

  void _validateBook(ComicBookInfo book, String expectedId) {
    if (book.id != expectedId || book.title.trim().isEmpty) {
      throw StateError('Comic book metadata is invalid.');
    }
  }

  void _validateChapterInfo(ComicChapterInfo info, {int? expectedIndex}) {
    if (info.id.trim().isEmpty ||
        info.title.trim().isEmpty ||
        info.index < 0 ||
        (expectedIndex != null && info.index != expectedIndex) ||
        (info.imageCount != null && info.imageCount! < 0)) {
      throw StateError('Comic chapter metadata is invalid.');
    }
  }

  void _validateContent(ComicChapterContent content, ComicChapterInfo info) {
    if (content.chapterId != info.id || content.title.trim().isEmpty) {
      throw StateError(
        'Comic chapter content does not match its catalog item.',
      );
    }
    final Set<String> ids = <String>{};
    for (int index = 0; index < content.images.length; index++) {
      final ComicImageInfo image = content.images[index];
      if (image.id.trim().isEmpty ||
          !ids.add(image.id) ||
          image.index != index ||
          (image.width != null && image.width! <= 0) ||
          (image.height != null && image.height! <= 0) ||
          (image.byteLength != null &&
              (image.byteLength! <= 0 ||
                  image.byteLength! >
                      _ComicReaderViewState._maxSingleImageBytes))) {
        throw StateError('Comic image metadata is invalid.');
      }
    }
    if (info.imageCount != null && info.imageCount != content.images.length) {
      throw StateError('Comic chapter image count is inconsistent.');
    }
  }

  void _validateBookmarks(List<ComicReaderBookmark> bookmarks, String bookId) {
    final Set<String> ids = <String>{};
    for (final ComicReaderBookmark bookmark in bookmarks) {
      if (bookmark.id.trim().isEmpty ||
          !ids.add(bookmark.id) ||
          bookmark.bookId != bookId ||
          bookmark.chapterId.trim().isEmpty ||
          bookmark.imageId.trim().isEmpty ||
          !bookmark.imageFraction.isFinite ||
          bookmark.imageFraction < 0 ||
          bookmark.imageFraction > 1) {
        throw StateError('Comic bookmark state is invalid.');
      }
    }
  }

  bool _isSession(
    int generation,
    String bookId,
    ComicReaderDataSource source,
    ComicReaderStateStore store,
  ) =>
      !_disposed &&
      generation == _sessionGeneration &&
      bookId == widget.bookId &&
      identical(source, widget.dataSource) &&
      identical(store, widget.stateStore);

  bool _isSessionForSource(
    int generation,
    String bookId,
    ComicReaderDataSource source,
  ) =>
      !_disposed &&
      generation == _sessionGeneration &&
      bookId == widget.bookId &&
      identical(source, widget.dataSource);

  bool _isNavigation(int generation) =>
      !_disposed && generation == _navigationGeneration;

  ReaderFailure _stateFailure(Object error) => ReaderFailure(
    ReaderFailureKind.persistence,
    ComicReaderStrings.readerProblem,
    code: 'comic_reader_persistence_failed',
    location: '恢复或保存漫画阅读状态',
    cause: error,
  );

  ReaderFailure _asFailure(
    Object error,
    ReaderFailureKind kind, {
    String? code,
    String? location,
  }) => error is ReaderFailure
      ? error
      : ReaderFailure(
          kind,
          ComicReaderStrings.readerProblem,
          code: code ?? 'comic_reader_${kind.name}_failed',
          location: location ?? '漫画阅读器',
          cause: error,
        );

  ReaderFailure _asImageFailure(Object error) => error is ReaderFailure
      ? ReaderFailure(
          ReaderFailureKind.image,
          error.message,
          code: error.code,
          location: error.location ?? '加载漫画图片',
          cause: error,
        )
      : ReaderFailure(
          ReaderFailureKind.image,
          ComicReaderStrings.imageFailed,
          code: 'comic_image_load_failed',
          location: '加载漫画图片',
          cause: error,
        );

  Future<void> _reportFailure(ReaderFailure failure) {
    if (_disposed) return Future<void>.value();
    final ComicReaderObserver observer =
        widget.observer ?? const ComicReaderObserver();
    return _notify(() => observer.onFailure(failure));
  }

  Future<void> _notify(FutureOr<void> Function() callback) =>
      Future<void>.sync(callback).catchError((Object error, StackTrace stack) {
        debugPrint('novel_reader_ui comic observer failed: $error\n$stack');
      });

  Future<_Result<T>> _captureCall<T>(Future<T> Function() operation) async {
    try {
      return _Result<T>(value: await Future<T>.sync(operation));
    } catch (error) {
      return _Result<T>(error: error);
    }
  }

  List<_ComicListEntry> _entries() {
    final int signature = Object.hash(
      _viewportWidth,
      Object.hashAll(
        _window.map(
          (item) => Object.hash(item.info.id, identityHashCode(item.content)),
        ),
      ),
      Object.hashAll(_boundaryLoads),
      Object.hashAll(
        _boundaryFailures.entries.map(
          (entry) => Object.hash(entry.key, identityHashCode(entry.value)),
        ),
      ),
      _catalogTotal,
      _afterBoundaryIndex,
    );
    if (signature == _entryCacheSignature) return _entryCache;
    final List<_ComicListEntry> result = <_ComicListEntry>[];
    for (final _LoadedComicChapter chapter in _window) {
      result.add(_ComicHeaderEntry(chapter));
      for (final ComicImageInfo image in chapter.content.images) {
        result.add(
          _ComicImageEntry(
            chapter,
            image,
            placeholderExtent: _placeholderExtent(image),
          ),
        );
      }
    }
    if (_window.isNotEmpty) {
      final int nextIndex = _afterBoundaryIndex ?? _window.last.info.index + 1;
      if (_catalogTotal == 0 || nextIndex <= _catalogTotal) {
        result.add(
          _ComicBoundaryEntry(
            index: nextIndex,
            loading: _boundaryLoads.contains(nextIndex),
            failure: _boundaryFailures[nextIndex],
            atEnd: _catalogTotal > 0 && nextIndex >= _catalogTotal,
          ),
        );
      }
    }
    final List<double> starts = <double>[];
    final Map<String, int> indexes = <String, int>{};
    double cursor = 0;
    for (int index = 0; index < result.length; index++) {
      final _ComicListEntry entry = result[index];
      starts.add(cursor);
      if (entry is _ComicImageEntry) {
        indexes['${entry.chapter.info.id}\u0000${entry.image.id}'] = index;
      }
      cursor += entry.extent;
    }
    _entryCacheSignature = signature;
    _entryCache = List<_ComicListEntry>.unmodifiable(result);
    _entryStarts = List<double>.unmodifiable(starts);
    _imageEntryIndexes = Map<String, int>.unmodifiable(indexes);
    return _entryCache;
  }

  int _entryIndexAt(double contentOffset) {
    if (_entryStarts.isEmpty) return 0;
    int low = 0;
    int high = _entryStarts.length - 1;
    while (low <= high) {
      final int middle = (low + high) >> 1;
      if (_entryStarts[middle] <= contentOffset) {
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }
    return high.clamp(0, _entryStarts.length - 1);
  }

  GlobalKey _imageKeyFor(_ComicImageEntry entry) {
    final String key = '${entry.chapter.info.id}\u0000${entry.image.id}';
    return _imageKeys.putIfAbsent(
      key,
      () => GlobalKey(debugLabel: 'ComicImage:$key'),
    );
  }

  double _placeholderExtent(ComicImageInfo image) {
    final double ratio = image.width != null && image.height != null
        ? (image.width! / image.height!).clamp(.02, 20).toDouble()
        : _ComicReaderViewState._defaultAspectRatio;
    return _viewportWidth <= 0 ? 600 : _viewportWidth / ratio;
  }

  double _chapterExtent(ComicChapterContent content) =>
      _ComicReaderViewState._chapterHeaderExtent +
      content.images.fold<double>(
        0,
        (sum, image) => sum + _placeholderExtent(image),
      );
}
