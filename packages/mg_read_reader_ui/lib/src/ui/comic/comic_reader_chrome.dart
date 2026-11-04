part of 'comic_reader_view.dart';

// ignore_for_file: invalid_use_of_protected_member

enum _ComicOverflowAction { refreshBook }

extension _ComicReaderChrome on _ComicReaderViewState {
  void _handleVolumeKey(ReaderVolumeKey key) {
    if (!_preferences.pageTurnShortcuts ||
        !_foreground ||
        _settingsVisible ||
        _controlsVisible ||
        _currentChapter == null ||
        !_scrollController.hasClients) {
      return;
    }
    _scrollByViewport(key == ReaderVolumeKey.down ? 1 : -1);
  }

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
        onTapUp: _handleReadingSurfaceTap,
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
            physics: ComicScrollPhysics(takeCorrection: _takeLayoutCorrection),
            padding: EdgeInsets.fromLTRB(
              _horizontalInset,
              _topPadding,
              _horizontalInset,
              MediaQuery.paddingOf(context).bottom + 48,
            ),
            scrollCacheExtent: const ScrollCacheExtent.viewport(.7),
            itemCount: entries.length,
            itemExtentBuilder: (int index, _) => entries[index].extent,
            itemBuilder: (BuildContext context, int index) {
              final _ComicListEntry entry = entries[index];
              return switch (entry) {
                _ComicHeaderEntry() => _buildChapterHeader(entry),
                _ComicImageEntry() => _buildImageTile(entry, palette),
                _ComicBoundaryEntry() => _buildBoundary(entry, palette),
              };
            },
          ),
        ),
      ),
    );
  }

  Widget _buildImageTile(_ComicImageEntry entry, ReaderPalette palette) {
    final String retryKey = '${entry.chapter.info.id}\u0000${entry.image.id}';
    return ComicProgressiveImageTile(
      key: _imageKeyFor(entry),
      cache: _imageCache,
      chapterId: entry.chapter.info.id,
      image: entry.image,
      width: _viewportWidth,
      placeholderHeight: entry.placeholderExtent,
      palette: palette,
      decodeBudget: _decodeBudget,
      onPresented: (bool cacheHit) {
        _imageRetryCoordinator.markResolved(retryKey);
        _onComicImagePresented(entry.chapter.info.id, entry.image.id, cacheHit);
      },
      onAutomaticRetryAvailable: (Future<void> Function() retry) {
        _imageRetryCoordinator.register(
          key: retryKey,
          isNearViewport: () => _isImageNearViewport(retryKey),
          retry: retry,
        );
      },
      bookId: widget.bookId,
      commentFeed: widget.commentFeed,
      onOpenComments: (ReaderCommentTarget target) =>
          _showImageComments(target, palette),
      onFailure: (Object error) =>
          unawaited(_reportFailure(_asImageFailure(error))),
    );
  }

  Widget _buildChapterHeader(_ComicHeaderEntry entry) {
    return SizedBox(
      height: _ComicReaderViewState._chapterHeaderExtent,
      child: ColoredBox(
        key: const ValueKey<String>('comic-reader-chapter-header'),
        color: Colors.white,
        child: Center(
          child: Text(
            entry.chapter.info.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: const Color(0xFF242424),
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }

  void _notifyFirstContentPresented(bool cacheHit) {
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
                onPressed: () => unawaited(_loadNextAdjacent(entry.index)),
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
                onPressed: () => unawaited(_loadNextAdjacent(entry.index)),
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
              child: SizedBox(
                width: double.infinity,
                child: ColoredBox(
                  color: _comicReaderChromeColor,
                  child: SafeArea(
                    bottom: false,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Container(
                          key: const ValueKey<String>(
                            'comic-reader-primary-top-bar',
                          ),
                          height: 54,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          decoration: const BoxDecoration(
                            color: _comicReaderChromeColor,
                            border: Border(
                              bottom: BorderSide(color: Color(0x243A3D40)),
                            ),
                          ),
                          child: Row(
                            children: <Widget>[
                              _chromeButton(
                                key: const ValueKey<String>(
                                  'comic-reader-back-action',
                                ),
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
                              if (widget.bookRefreshCapability != null)
                                PopupMenuButton<_ComicOverflowAction>(
                                  key: _comicOverflowMenuKey,
                                  tooltip: ComicReaderStrings.more,
                                  icon: const Icon(Icons.more_vert_rounded),
                                  onSelected: (_ComicOverflowAction action) {
                                    switch (action) {
                                      case _ComicOverflowAction.refreshBook:
                                        unawaited(_refreshBookFromHost());
                                    }
                                  },
                                  itemBuilder: (BuildContext context) =>
                                      <PopupMenuEntry<_ComicOverflowAction>>[
                                        PopupMenuItem<_ComicOverflowAction>(
                                          value:
                                              _ComicOverflowAction.refreshBook,
                                          enabled: !_bookRefreshLoading,
                                          child: Row(
                                            children: <Widget>[
                                              _bookRefreshLoading
                                                  ? const SizedBox.square(
                                                      dimension: 20,
                                                      child:
                                                          CircularProgressIndicator(
                                                            strokeWidth: 2,
                                                          ),
                                                    )
                                                  : const Icon(
                                                      Icons.sync_rounded,
                                                      size: 20,
                                                    ),
                                              const SizedBox(width: 12),
                                              const Text(
                                                ComicReaderStrings.refreshBook,
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                ),
                            ],
                          ),
                        ),
                        ReaderSourceStrip(
                          key: const ValueKey<String>(
                            'comic-reader-source-strip',
                          ),
                          sourceName: _book?.sourceName,
                          sourceUrl: _book?.sourceUrl?.toString(),
                          sourceUri: _book?.sourceUrl,
                          style: ReaderSourceStripStyle.comic(palette),
                          onOpenSource: _book?.sourceUrl == null
                              ? null
                              : () => unawaited(
                                  _openSourceUrl(_book!.sourceUrl!),
                                ),
                          sourceNameKey: const ValueKey<String>(
                            'comic-reader-source-name',
                          ),
                          sourceUrlRegionKey: const ValueKey<String>(
                            'comic-reader-source-url-region',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: SizedBox(
                width: double.infinity,
                child: ColoredBox(
                  color: _comicReaderChromeColor,
                  child: SafeArea(
                    top: false,
                    child: Container(
                      height: 70,
                      decoration: const BoxDecoration(
                        color: _comicReaderChromeColor,
                        border: Border(
                          top: BorderSide(color: Color(0x243A3D40)),
                        ),
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
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 工具栏显示时覆盖正文，点击中间空白区域只关闭工具栏。
  ///
  /// 该层位于 chrome 之下，因此顶部和底部按钮仍可操作；同时避免
  /// 点击或拖动透明区域继续命中漫画列表。
  Widget _buildControlsInteractionLock() {
    return Positioned.fill(
      child: GestureDetector(
        key: const ValueKey<String>('comic-reader-controls-interaction-lock'),
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onTap: () => _setControlsVisible(false),
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

  Future<void> _openSourceUrl(Uri uri) async {
    try {
      final bool launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched) throw StateError(ReaderStrings.chapterUrlOpenFailed);
    } catch (error) {
      await _reportFailure(_asFailure(error, ReaderFailureKind.platform));
    }
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
    final ReaderFailure? failure = _failure;
    return ColoredBox(
      color: const Color(0xFF101112),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.broken_image_outlined, color: palette.secondaryText),
            const SizedBox(height: 12),
            Text(
              failure?.message ?? ComicReaderStrings.chapterFailed,
              style: TextStyle(color: palette.text),
            ),
            if (failure?.location case final String location) ...<Widget>[
              const SizedBox(height: 6),
              Text(
                '发生位置：$location',
                key: const Key('comic-reader-status-location'),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: palette.secondaryText),
              ),
            ],
            if (failure?.code case final String code) ...<Widget>[
              const SizedBox(height: 3),
              Text(
                '诊断编号：$code',
                key: const Key('comic-reader-status-code'),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: palette.secondaryText),
              ),
            ],
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
    final ReaderFailure? failure = _failure;
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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      failure?.message ?? ComicReaderStrings.chapterFailed,
                      style: TextStyle(color: palette.text, fontSize: 13),
                    ),
                    if (failure?.location case final String location)
                      Text(
                        '发生位置：$location',
                        style: TextStyle(
                          color: palette.secondaryText,
                          fontSize: 11,
                        ),
                      ),
                    if (failure?.code case final String code)
                      Text(
                        '诊断编号：$code',
                        style: TextStyle(
                          color: palette.secondaryText,
                          fontSize: 11,
                        ),
                      ),
                  ],
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
    if (!_preferences.pageTurnShortcuts ||
        _settingsVisible ||
        _controlsVisible ||
        !_scrollController.hasClients) {
      return;
    }
    final double delta = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowDown => 72,
      LogicalKeyboardKey.arrowUp => -72,
      LogicalKeyboardKey.arrowRight => _pageTurnDistance,
      LogicalKeyboardKey.space when !HardwareKeyboard.instance.isShiftPressed =>
        _pageTurnDistance,
      LogicalKeyboardKey.enter => _pageTurnDistance,
      LogicalKeyboardKey.pageDown => _pageTurnDistance,
      LogicalKeyboardKey.arrowLeft => -_pageTurnDistance,
      LogicalKeyboardKey.space => -_pageTurnDistance,
      LogicalKeyboardKey.pageUp => -_pageTurnDistance,
      LogicalKeyboardKey.audioVolumeDown => _pageTurnDistance,
      LogicalKeyboardKey.audioVolumeUp => -_pageTurnDistance,
      _ => 0,
    };
    if (delta == 0) return;
    _scrollBy(delta);
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
}
