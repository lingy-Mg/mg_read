part of 'comic_reader_view.dart';

// ignore_for_file: invalid_use_of_protected_member

extension _ComicReaderChrome on _ComicReaderViewState {
  Widget _buildReadingSurface(ReaderPalette palette) {
    if (!_loading && _failure == null && _window.isEmpty) {
      return Center(
        child: Text(
          ComicReaderStrings.noChapters,
          style: TextStyle(color: palette.secondaryText),
        ),
      );
    }
    final List<_ComicListEntry> entries = _entries();
    return Listener(
      key: const ValueKey<String>('comic-reader-content-surface'),
      onPointerSignal: (PointerSignalEvent event) {
        if (event is PointerScrollEvent) _focusNode.requestFocus();
      },
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTapUp: (_) => _setControlsVisible(!_controlsVisible),
        child: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(
            dragDevices: <PointerDeviceKind>{
              ...ScrollConfiguration.of(context).dragDevices,
              PointerDeviceKind.mouse,
            },
          ),
          child: ListView.builder(
            key: _readingSurfaceKey,
            controller: _scrollController,
            padding: EdgeInsets.fromLTRB(
              _horizontalInset,
              _topPadding,
              _horizontalInset,
              MediaQuery.paddingOf(context).bottom + 48,
            ),
            scrollCacheExtent: const ScrollCacheExtent.viewport(.7),
            itemCount: entries.length,
            itemBuilder: (BuildContext context, int index) {
              final _ComicListEntry entry = entries[index];
              return switch (entry) {
                _ComicHeaderEntry() => _buildChapterHeader(entry, palette),
                _ComicImageEntry() => ComicProgressiveImageTile(
                  key: _imageKeyFor(entry),
                  cache: _imageCache,
                  chapterId: entry.chapter.info.id,
                  image: entry.image,
                  width: _viewportWidth,
                  placeholderHeight: entry.placeholderExtent,
                  palette: palette,
                  decodeBudget: _decodeBudget,
                  onPresented: (bool cacheHit) =>
                      _notifyFirstContentPresented(entry, cacheHit),
                  bookId: widget.bookId,
                  commentFeed: widget.commentFeed,
                  onOpenComments: (ReaderCommentTarget target) =>
                      _showImageComments(target, palette),
                  onFailure: (Object error) =>
                      unawaited(_reportFailure(_asImageFailure(error))),
                ),
                _ComicBoundaryEntry() => _buildBoundary(entry, palette),
              };
            },
          ),
        ),
      ),
    );
  }

  Widget _buildChapterHeader(_ComicHeaderEntry entry, ReaderPalette palette) {
    return SizedBox(
      height: _ComicReaderViewState._chapterHeaderExtent,
      child: ColoredBox(
        color: const Color(0xFF151719),
        child: Center(
          child: Text(
            entry.chapter.info.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: palette.text,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }

  void _notifyFirstContentPresented(_ComicImageEntry entry, bool cacheHit) {
    if (_firstContentPresented || _disposed) return;
    _firstContentPresented = true;
    unawaited(
      _notify(
        () => (widget.observer ?? const ComicReaderObserver())
            .onFirstContentPresented(
              ComicFirstContentPresentation(
                anchor: _progress,
                cacheHit: cacheHit,
              ),
            ),
      ),
    );
    // This callback is posted only after the first real image is painted, so
    // nearby downloads cannot compete with the reader's first-content path.
    _prefetchAround(entry);
  }

  Widget _buildBoundary(_ComicBoundaryEntry entry, ReaderPalette palette) {
    return SizedBox(
      height: _ComicReaderViewState._boundaryExtent,
      child: Center(
        child: entry.atEnd
            ? Text(
                ComicReaderStrings.endOfBook,
                style: TextStyle(color: palette.secondaryText),
              )
            : entry.failure != null
            ? TextButton.icon(
                onPressed: () =>
                    unawaited(_loadAdjacent(entry.index, before: entry.before)),
                icon: const Icon(Icons.refresh_rounded),
                label: const Text(ComicReaderStrings.retry),
              )
            : entry.loading
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : TextButton(
                onPressed: () =>
                    unawaited(_loadAdjacent(entry.index, before: entry.before)),
                child: const Text(ComicReaderStrings.loadMore),
              ),
      ),
    );
  }

  Widget _buildChrome(ReaderPalette palette) {
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    return IgnorePointer(
      ignoring: !_controlsVisible,
      child: AnimatedOpacity(
        opacity: _controlsVisible ? 1 : 0,
        duration: reduceMotion
            ? Duration.zero
            : const Duration(milliseconds: 180),
        child: Stack(
          children: <Widget>[
            Align(
              alignment: Alignment.topCenter,
              child: SafeArea(
                bottom: false,
                child: Container(
                  height: 54,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: const BoxDecoration(
                    color: Color(0xE617191B),
                    border: Border(
                      bottom: BorderSide(color: Color(0x243A3D40)),
                    ),
                  ),
                  child: Row(
                    children: <Widget>[
                      _chromeButton(
                        key: const ValueKey<String>('comic-reader-back-action'),
                        icon: Icons.arrow_back_rounded,
                        label: ComicReaderStrings.back,
                        onPressed: () => unawaited(_requestExit()),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          _currentChapter?.title ?? _book?.title ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: palette.text,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      _chromeButton(
                        key: const ValueKey<String>(
                          'comic-reader-add-bookmark',
                        ),
                        icon: Icons.bookmark_add_outlined,
                        label: ComicReaderStrings.addBookmark,
                        onPressed: () => unawaited(_addBookmark()),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: SafeArea(
                top: false,
                child: Container(
                  height: 70,
                  decoration: const BoxDecoration(
                    color: Color(0xF2181A1C),
                    border: Border(top: BorderSide(color: Color(0x243A3D40))),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: <Widget>[
                      _bottomButton(
                        const ValueKey<String>('comic-reader-catalog'),
                        Icons.list_alt_rounded,
                        ComicReaderStrings.catalog,
                        _showCatalog,
                      ),
                      _bottomButton(
                        const ValueKey<String>('comic-reader-bookmarks'),
                        Icons.bookmarks_outlined,
                        ComicReaderStrings.bookmarks,
                        _showBookmarks,
                      ),
                      _bottomButton(
                        const ValueKey<String>('comic-reader-settings'),
                        Icons.tune_rounded,
                        ComicReaderStrings.settings,
                        _showSettings,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chromeButton({
    Key? key,
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
  }) {
    return IconButton(
      key: key,
      constraints: const BoxConstraints.tightFor(width: 48, height: 48),
      tooltip: label,
      icon: Icon(icon),
      onPressed: onPressed,
    );
  }

  Widget _bottomButton(
    Key? key,
    IconData icon,
    String label,
    VoidCallback onPressed,
  ) {
    return Semantics(
      key: key,
      button: true,
      label: label,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(14),
        child: SizedBox(
          width: 86,
          height: 58,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(icon, size: 22),
              const SizedBox(height: 3),
              Text(label, style: const TextStyle(fontSize: 11)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLoadingOverlay(ReaderPalette palette) {
    return ColoredBox(
      color: const Color(0xFF101112),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            CircularProgressIndicator(color: palette.accent, strokeWidth: 2),
            const SizedBox(height: 16),
            Text(
              ComicReaderStrings.loading,
              style: TextStyle(color: palette.secondaryText),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFailureOverlay(ReaderPalette palette) {
    return ColoredBox(
      color: const Color(0xFF101112),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.broken_image_outlined, color: palette.secondaryText),
            const SizedBox(height: 12),
            Text(
              ComicReaderStrings.chapterFailed,
              style: TextStyle(color: palette.text),
            ),
            const SizedBox(height: 10),
            FilledButton.tonal(
              onPressed: _currentChapter == null
                  ? () => unawaited(_restart())
                  : () => unawaited(_refreshCurrentChapter()),
              child: const Text(ComicReaderStrings.retry),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInlineFailure(ReaderPalette palette) {
    return SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 520),
          margin: const EdgeInsets.fromLTRB(56, 8, 56, 0),
          padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
          decoration: BoxDecoration(
            color: palette.panel.withValues(alpha: .96),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: palette.divider),
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  ComicReaderStrings.chapterFailed,
                  style: TextStyle(color: palette.text, fontSize: 13),
                ),
              ),
              TextButton(
                onPressed: () => unawaited(_refreshCurrentChapter()),
                child: const Text(ComicReaderStrings.retry),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      unawaited(_requestExit());
      return;
    }
    if (!_scrollController.hasClients) return;
    final double delta = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowDown => 72,
      LogicalKeyboardKey.arrowUp => -72,
      LogicalKeyboardKey.pageDown => _viewportHeight * .82,
      LogicalKeyboardKey.pageUp => -_viewportHeight * .82,
      _ => 0,
    };
    if (delta == 0) return;
    final double target = (_scrollController.offset + delta).clamp(
      0,
      _scrollController.position.maxScrollExtent,
    );
    if (MediaQuery.disableAnimationsOf(context)) {
      _scrollController.jumpTo(target);
    } else {
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
      );
    }
  }

  Future<void> _addBookmark() async {
    final ComicReaderProgress? progress = _progress;
    final ComicChapterInfo? chapter = _currentChapter;
    if (progress == null || chapter == null) return;
    final int session = _sessionGeneration;
    final String bookId = widget.bookId;
    final ComicReaderStateStore store = widget.stateStore;
    final ComicReaderDataSource source = widget.dataSource;
    final DateTime now = DateTime.now();
    final ComicReaderBookmark bookmark = ComicReaderBookmark(
      id:
          '$bookId:${progress.chapterId}:${progress.imageId}:'
          '${now.microsecondsSinceEpoch}',
      bookId: bookId,
      chapterId: progress.chapterId,
      imageId: progress.imageId,
      imageFraction: progress.imageFraction,
      chapterTitle: chapter.title,
      createdAt: now,
    );
    setState(() {
      _bookmarks = List<ComicReaderBookmark>.unmodifiable(<ComicReaderBookmark>[
        ..._bookmarks,
        bookmark,
      ]);
    });
    unawaited(
      _enqueueStoreWrite(
        _bookmarkWrites,
        _BookStoreKey(store, bookId),
        () => store.addBookmark(bookmark),
        (Object error) {
          if (_isSession(session, bookId, source, store)) {
            setState(() {
              _bookmarks = List<ComicReaderBookmark>.unmodifiable(
                _bookmarks.where((item) => item.id != bookmark.id),
              );
            });
            unawaited(_reportFailure(_stateFailure(error)));
          }
        },
      ),
    );
  }

  Future<void> _removeBookmark(ComicReaderBookmark bookmark) async {
    final int session = _sessionGeneration;
    final String bookId = widget.bookId;
    final ComicReaderStateStore store = widget.stateStore;
    final ComicReaderDataSource source = widget.dataSource;
    setState(() {
      _bookmarks = List<ComicReaderBookmark>.unmodifiable(
        _bookmarks.where((item) => item.id != bookmark.id),
      );
    });
    unawaited(
      _enqueueStoreWrite(
        _bookmarkWrites,
        _BookStoreKey(store, bookId),
        () => store.removeBookmark(bookId, bookmark.id),
        (Object error) {
          if (_isSession(session, bookId, source, store)) {
            setState(() {
              if (_bookmarks.every((item) => item.id != bookmark.id)) {
                _bookmarks = List<ComicReaderBookmark>.unmodifiable(
                  <ComicReaderBookmark>[..._bookmarks, bookmark]
                    ..sort((a, b) => a.createdAt.compareTo(b.createdAt)),
                );
              }
            });
            unawaited(_reportFailure(_stateFailure(error)));
          }
        },
      ),
    );
  }

  void _showImageComments(ReaderCommentTarget target, ReaderPalette palette) {
    final ReaderCommentFeed? feed = widget.commentFeed;
    if (feed == null ||
        target.bookId != widget.bookId ||
        target.chapterId == null ||
        target.chapterId!.trim().isEmpty ||
        target.imageId == null ||
        target.imageId!.trim().isEmpty ||
        target.paragraphId != null) {
      return;
    }
    final int session = _sessionGeneration;
    final String bookId = widget.bookId;
    final ComicReaderDataSource source = widget.dataSource;
    final ComicReaderStateStore store = widget.stateStore;
    final int sheetGeneration = _beginSheet();
    final Future<void> sheet = showReaderCommentsSheet(
      context: context,
      feed: feed,
      target: target,
      palette: palette,
      title: ReaderCommentStrings.title,
      onLoadError: (Object error) {
        if (_isSession(session, bookId, source, store) &&
            identical(feed, widget.commentFeed)) {
          unawaited(_reportFailure(_asFailure(error, ReaderFailureKind.data)));
        }
      },
      onSheetBuilt: (BuildContext context) =>
          _captureSheetContext(context, sheetGeneration),
    );
    unawaited(sheet.whenComplete(() => _finishSheet(sheetGeneration)));
  }

  int _beginSheet() {
    _dismissSessionSheet();
    return ++_sheetGeneration;
  }

  void _captureSheetContext(BuildContext context, int generation) {
    if (generation == _sheetGeneration && !_disposed) {
      _activeSheetContext = context;
      return;
    }
    _popSheetAfterFrame(context);
  }

  void _finishSheet(int generation) {
    if (generation == _sheetGeneration) _activeSheetContext = null;
  }

  void _dismissSessionSheet() {
    _sheetGeneration++;
    final BuildContext? context = _activeSheetContext;
    _activeSheetContext = null;
    if (context != null) _popSheetAfterFrame(context);
  }

  void _popSheetAfterFrame(BuildContext sheetContext) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!sheetContext.mounted) return;
      final ModalRoute<Object?>? route = ModalRoute.of(sheetContext);
      if (route?.isCurrent ?? false) Navigator.of(sheetContext).pop();
    });
  }

  void _showCatalog() {
    final int session = _sessionGeneration;
    final String bookId = widget.bookId;
    final ComicReaderDataSource source = widget.dataSource;
    final ComicReaderStateStore store = widget.stateStore;
    bool isCurrent() => _isSession(session, bookId, source, store);
    final int sheetGeneration = _beginSheet();
    _setControlsVisible(false);
    final Future<void> sheet = showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF202326),
      builder: (BuildContext sheetContext) {
        _captureSheetContext(sheetContext, sheetGeneration);
        return StatefulBuilder(
          builder:
              (
                BuildContext context,
                void Function(VoidCallback) sheetSetState,
              ) {
                return _darkSheet(
                  SafeArea(
                    child: SizedBox(
                      height: MediaQuery.sizeOf(context).height * .76,
                      child: Column(
                        children: <Widget>[
                          _sheetHeader(ComicReaderStrings.catalog),
                          Expanded(
                            child: ListView.builder(
                              itemCount:
                                  _catalog.length +
                                  (_catalogHasMore || _catalogLoading ? 1 : 0),
                              itemBuilder: (BuildContext context, int index) {
                                if (index == _catalog.length) {
                                  return SizedBox(
                                    height: 64,
                                    child: Center(
                                      child: _catalogLoading
                                          ? const CircularProgressIndicator(
                                              strokeWidth: 2,
                                            )
                                          : TextButton(
                                              onPressed: () async {
                                                if (!isCurrent()) {
                                                  if (sheetContext.mounted) {
                                                    Navigator.of(
                                                      sheetContext,
                                                    ).pop();
                                                  }
                                                  return;
                                                }
                                                await _loadNextCatalogPage();
                                                if (sheetContext.mounted &&
                                                    isCurrent()) {
                                                  sheetSetState(() {});
                                                }
                                              },
                                              child: const Text(
                                                ComicReaderStrings.loadMore,
                                              ),
                                            ),
                                    ),
                                  );
                                }
                                final ComicChapterInfo chapter =
                                    _catalog[index];
                                return ListTile(
                                  minTileHeight: 52,
                                  selected: chapter.id == _currentChapter?.id,
                                  title: Text(
                                    chapter.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: Text(_chapterStatus(chapter)),
                                  onTap: () {
                                    if (!isCurrent()) {
                                      Navigator.of(context).pop();
                                      return;
                                    }
                                    Navigator.of(context).pop();
                                    unawaited(
                                      _openChapterInfo(
                                        chapter,
                                        replaceWindow: true,
                                      ),
                                    );
                                  },
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
        );
      },
    );
    unawaited(sheet.whenComplete(() => _finishSheet(sheetGeneration)));
  }

  String _chapterStatus(ComicChapterInfo chapter) {
    final String count = chapter.imageCount == null
        ? ''
        : ComicReaderStrings.imageCount(chapter.imageCount!);
    final String read = chapter.hasBeenRead
        ? ComicReaderStrings.read
        : ComicReaderStrings.unread;
    final String availability = switch (chapter.availability) {
      ReaderChapterAvailability.downloaded => ComicReaderStrings.cached,
      ReaderChapterAvailability.downloading => ComicReaderStrings.loadingStatus,
      ReaderChapterAvailability.notDownloaded => ComicReaderStrings.notCached,
      ReaderChapterAvailability.failed => ComicReaderStrings.failedStatus,
      ReaderChapterAvailability.unknown => '',
    };
    return <String>[
      count,
      read,
      availability,
    ].where((value) => value.isNotEmpty).join(' · ');
  }

  void _showBookmarks() {
    final int session = _sessionGeneration;
    final String bookId = widget.bookId;
    final ComicReaderDataSource source = widget.dataSource;
    final ComicReaderStateStore store = widget.stateStore;
    bool isCurrent() => _isSession(session, bookId, source, store);
    final int sheetGeneration = _beginSheet();
    _setControlsVisible(false);
    final Future<void> sheet = showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF202326),
      builder: (BuildContext context) {
        _captureSheetContext(context, sheetGeneration);
        return _darkSheet(
          SafeArea(
            child: SizedBox(
              height: MediaQuery.sizeOf(context).height * .7,
              child: Column(
                children: <Widget>[
                  _sheetHeader(ComicReaderStrings.bookmarks),
                  Expanded(
                    child: _bookmarks.isEmpty
                        ? const Center(
                            child: Text(ComicReaderStrings.noBookmarks),
                          )
                        : ListView.builder(
                            itemCount: _bookmarks.length,
                            itemBuilder: (BuildContext context, int index) {
                              final ComicReaderBookmark bookmark =
                                  _bookmarks[index];
                              return ListTile(
                                minTileHeight: 56,
                                title: Text(bookmark.chapterTitle),
                                subtitle: Text(
                                  ComicReaderStrings.imageProgress(
                                    bookmark.imageId,
                                    (bookmark.imageFraction * 100).round(),
                                  ),
                                ),
                                trailing: IconButton(
                                  tooltip: ComicReaderStrings.removeBookmark,
                                  icon: const Icon(
                                    Icons.delete_outline_rounded,
                                  ),
                                  onPressed: () {
                                    if (!isCurrent()) {
                                      Navigator.of(context).pop();
                                      return;
                                    }
                                    Navigator.of(context).pop();
                                    unawaited(_removeBookmark(bookmark));
                                  },
                                ),
                                onTap: () {
                                  if (!isCurrent()) {
                                    Navigator.of(context).pop();
                                    return;
                                  }
                                  Navigator.of(context).pop();
                                  unawaited(_openBookmark(bookmark));
                                },
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
    unawaited(sheet.whenComplete(() => _finishSheet(sheetGeneration)));
  }

  Future<void> _openBookmark(ComicReaderBookmark bookmark) async {
    ComicChapterInfo? chapter = _catalogById[bookmark.chapterId];
    while (chapter == null && _catalogHasMore && !_disposed) {
      if (!await _loadNextCatalogPage()) break;
      chapter = _catalogById[bookmark.chapterId];
    }
    if (chapter == null) return;
    await _openChapterInfo(
      chapter,
      restore: ComicReaderProgress(
        chapterId: bookmark.chapterId,
        imageId: bookmark.imageId,
        imageFraction: bookmark.imageFraction,
        chapterIndex: chapter.index,
      ),
      replaceWindow: true,
    );
  }

  void _showSettings() {
    final int session = _sessionGeneration;
    final String bookId = widget.bookId;
    final ComicReaderDataSource source = widget.dataSource;
    final ComicReaderStateStore store = widget.stateStore;
    bool isCurrent() => _isSession(session, bookId, source, store);
    final int sheetGeneration = _beginSheet();
    _setControlsVisible(false);
    final Future<void> sheet = showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF202326),
      builder: (BuildContext context) {
        _captureSheetContext(context, sheetGeneration);
        return StatefulBuilder(
          builder:
              (
                BuildContext context,
                void Function(VoidCallback) sheetSetState,
              ) {
                void update(
                  ComicReaderPreferences value, {
                  bool persist = true,
                }) {
                  if (!isCurrent()) {
                    Navigator.of(context).pop();
                    return;
                  }
                  final ComicReaderPreferences normalized = value.normalized();
                  final ComicReaderProgress? anchor = _progress;
                  final bool layoutChanged =
                      normalized.imageSpacing != _preferences.imageSpacing;
                  setState(() {
                    _preferences = normalized;
                    _preferencesAuthoritative = true;
                  });
                  _preferencesDirty = !persist;
                  sheetSetState(() {});
                  if (layoutChanged) {
                    _restoring = true;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (_disposed) return;
                      _restorePosition(anchor);
                      _restoring = false;
                    });
                  }
                  unawaited(_syncAwake());
                  if (persist) {
                    unawaited(_savePreferences(normalized, store: store));
                  }
                }

                void commit() {
                  if (!isCurrent()) return;
                  _preferencesDirty = false;
                  unawaited(_savePreferences(_preferences, store: store));
                }

                return _darkSheet(
                  SafeArea(
                    child: SizedBox(
                      height: MediaQuery.sizeOf(context).height * .55,
                      child: Column(
                        children: <Widget>[
                          _sheetHeader(ComicReaderStrings.settings),
                          Expanded(
                            child: ListView(
                              padding: const EdgeInsets.fromLTRB(20, 6, 20, 24),
                              children: <Widget>[
                                _settingSlider(
                                  label: ComicReaderStrings.brightness,
                                  value: _preferences.brightness,
                                  min: .25,
                                  max: 1,
                                  onChanged: (double value) => update(
                                    ComicReaderPreferences(
                                      brightness: value,
                                      keepScreenOn: _preferences.keepScreenOn,
                                      immersiveMode: _preferences.immersiveMode,
                                      imageSpacing: _preferences.imageSpacing,
                                    ),
                                    persist: false,
                                  ),
                                  onChangeEnd: (double value) => commit(),
                                ),
                                if (_platformCapabilities.keepScreenOn)
                                  SwitchListTile.adaptive(
                                    contentPadding: EdgeInsets.zero,
                                    title: const Text(
                                      ComicReaderStrings.keepAwake,
                                    ),
                                    value: _preferences.keepScreenOn,
                                    onChanged: (bool value) => update(
                                      ComicReaderPreferences(
                                        brightness: _preferences.brightness,
                                        keepScreenOn: value,
                                        immersiveMode:
                                            _preferences.immersiveMode,
                                        imageSpacing: _preferences.imageSpacing,
                                      ),
                                    ),
                                  ),
                                if (_platformCapabilities.immersiveMode)
                                  SwitchListTile.adaptive(
                                    contentPadding: EdgeInsets.zero,
                                    title: const Text(
                                      ComicReaderStrings.immersive,
                                    ),
                                    value: _preferences.immersiveMode,
                                    onChanged: (bool value) => update(
                                      ComicReaderPreferences(
                                        brightness: _preferences.brightness,
                                        keepScreenOn: _preferences.keepScreenOn,
                                        immersiveMode: value,
                                        imageSpacing: _preferences.imageSpacing,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
        );
      },
    );
    unawaited(
      sheet.whenComplete(() {
        _finishSheet(sheetGeneration);
        if (isCurrent()) {
          _preferencesDirty = false;
          unawaited(_savePreferences(_preferences, store: store));
        }
      }),
    );
  }

  Widget _settingSlider({
    required String label,
    required double value,
    required double min,
    required double max,
    int? divisions,
    required ValueChanged<double> onChanged,
    required ValueChanged<double> onChangeEnd,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: <Widget>[
          SizedBox(width: 76, child: Text(label)),
          Expanded(
            child: Slider(
              value: value,
              min: min,
              max: max,
              divisions: divisions,
              onChanged: onChanged,
              onChangeEnd: onChangeEnd,
            ),
          ),
        ],
      ),
    );
  }

  Widget _darkSheet(Widget child) {
    final ReaderPalette palette = ReaderPalette.fromPreset(
      ReaderThemePreset.deepNight,
    );
    return Theme(
      data: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: palette.accent,
          brightness: Brightness.dark,
          surface: const Color(0xFF202326),
        ),
        scaffoldBackgroundColor: const Color(0xFF202326),
        fontFamily: readerDefaultFontFamily,
        fontFamilyFallback: const <String>[
          'PingFang SC',
          'Microsoft YaHei',
          'Noto Sans CJK SC',
          'sans-serif',
        ],
        textTheme: ThemeData.dark().textTheme.apply(
          bodyColor: palette.text,
          displayColor: palette.text,
        ),
        iconTheme: IconThemeData(color: palette.text),
      ),
      child: DefaultTextStyle.merge(
        style: TextStyle(color: palette.text),
        child: child,
      ),
    );
  }

  Widget _sheetHeader(String title) {
    return SizedBox(
      height: 52,
      child: Row(
        children: <Widget>[
          const SizedBox(width: 20),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 20),
        ],
      ),
    );
  }
}
