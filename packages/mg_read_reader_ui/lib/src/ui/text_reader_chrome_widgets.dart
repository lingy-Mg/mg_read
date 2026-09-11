part of 'text_reader_view.dart';

// ignore_for_file: invalid_use_of_protected_member

extension _TextReaderChromeWidgets on _TextReaderViewState {
  Widget _buildChrome() {
    return IgnorePointer(
      ignoring: !_controlsVisible,
      child: AnimatedOpacity(
        opacity: _controlsVisible ? 1 : 0,
        duration: const Duration(milliseconds: 180),
        child: Stack(
          children: <Widget>[
            Align(alignment: Alignment.topCenter, child: _buildTopBar()),
            Align(alignment: Alignment.bottomCenter, child: _buildBottomBar()),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    final String bookmarkLabel = _isCurrentBookmarked
        ? ReaderStrings.removeBookmark
        : ReaderStrings.addBookmark;
    void refreshAction() => unawaited(
      _refreshCurrentChapter(dismissControls: true, showLoadingOverlay: true),
    );
    return SafeArea(
      bottom: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Material(
            key: const ValueKey<String>('reader-primary-top-bar'),
            color: _palette.panel,
            elevation: 0,
            child: SizedBox(
              height: 48,
              child: Stack(
                children: <Widget>[
                  Positioned(
                    left: 56,
                    right:
                        48 +
                        (widget.extensions.chapterRefreshCapability == null
                            ? 0
                            : 48) +
                        (widget.extensions.chapterCacheCapability == null
                            ? 0
                            : 48),
                    top: 0,
                    bottom: 0,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        _topBarTitle,
                        key: const ValueKey<String>('reader-top-title'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: ReaderAccessibleTooltip(
                      label: ReaderStrings.back,
                      onTap: _requestExit,
                      child: IconButton(
                        key: const ValueKey<String>('reader-back-action'),
                        onPressed: _requestExit,
                        icon: const Icon(Icons.arrow_back_ios_new_rounded),
                      ),
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        ReaderAccessibleTooltip(
                          label: bookmarkLabel,
                          onTap: _toggleBookmark,
                          child: IconButton(
                            key: const ValueKey<String>(
                              'reader-toolbar-bookmark',
                            ),
                            onPressed: _toggleBookmark,
                            icon: Icon(
                              _isCurrentBookmarked
                                  ? Icons.bookmark_rounded
                                  : Icons.bookmark_border_rounded,
                              color: _isCurrentBookmarked
                                  ? _palette.accent
                                  : null,
                            ),
                          ),
                        ),
                        if (widget.extensions.chapterRefreshCapability != null)
                          ReaderAccessibleTooltip(
                            label: ReaderStrings.refreshChapter,
                            onTap: refreshAction,
                            child: IconButton(
                              key: const ValueKey<String>(
                                'reader-toolbar-refresh-chapter',
                              ),
                              onPressed: refreshAction,
                              icon: const Icon(Icons.refresh_rounded, size: 21),
                            ),
                          ),
                        if (widget.extensions.chapterCacheCapability != null)
                          _buildReaderOverflowMenu(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          ReaderSourceStrip(
            key: const ValueKey<String>('reader-source-strip'),
            sourceName: _book?.sourceName,
            sourceUrl: _sourceDisplayUrl,
            sourceUri: _sourceDisplayUri,
            style: ReaderSourceStripStyle.text(_palette),
            onOpenSource: _sourceDisplayUri == null
                ? null
                : () => unawaited(_openSourceUrl(_sourceDisplayUri!)),
            sourceNameKey: const ValueKey<String>('reader-source-name'),
            sourceUrlRegionKey: const ValueKey<String>(
              'reader-source-url-region',
            ),
          ),
        ],
      ),
    );
  }

  String get _topBarTitle {
    final ReaderBookInfo? book = _book;
    if (book == null) return '';
    final bool chapterTitleIsOnPage =
        _preferences.navigationMode == ReaderNavigationMode.horizontalPages &&
        (_pages.isEmpty ||
            (_pageIndex >= 0 &&
                _pageIndex < _pages.length &&
                _pages[_pageIndex].showsTitle));
    return chapterTitleIsOnPage ? book.title : _content?.title ?? book.title;
  }

  Future<void> _openSourceUrl(Uri uri) async {
    try {
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched) {
        throw StateError(ReaderStrings.chapterUrlOpenFailed);
      }
    } catch (error) {
      await _reportFailure(_asFailure(error, ReaderFailureKind.platform));
    }
  }

  Future<void> _refreshCurrentChapter({
    bool dismissControls = false,
    bool showLoadingOverlay = false,
  }) async {
    final String? chapterId = _content?.chapterId;
    if (chapterId == null ||
        widget.extensions.chapterRefreshCapability == null) {
      return;
    }
    await _openChapter(
      chapterId,
      forceRefresh: true,
      dismissControls: dismissControls,
      showLoadingOverlay: showLoadingOverlay,
    );
  }

  String? get _sourceDisplayUrl =>
      _book?.sourceUrl?.toString() ?? _currentChapterUrl;

  Uri? get _sourceDisplayUri => _book?.sourceUrl ?? _currentChapterUri;

  String? get _currentChapterUrl {
    final String? chapterUrl = _content?.chapterUrl?.trim();
    return chapterUrl == null || chapterUrl.isEmpty ? null : chapterUrl;
  }

  Uri? get _currentChapterUri {
    final String? chapterUrl = _currentChapterUrl;
    final Uri? uri = chapterUrl == null ? null : Uri.tryParse(chapterUrl);
    if (uri == null || uri.host.isEmpty) return null;
    return switch (uri.scheme) {
      'http' || 'https' => uri,
      _ => null,
    };
  }

  Widget _buildBottomBar() {
    final double progress = _sliderPreview ?? _progress?.bookFraction ?? 0;
    return Material(
      color: _palette.panel,
      elevation: 0,
      child: SafeArea(
        top: false,
        child: Container(
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: _palette.divider)),
          ),
          padding: const EdgeInsets.fromLTRB(10, 4, 10, 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                children: <Widget>[
                  TextButton(
                    key: const ValueKey<String>(
                      'reader-toolbar-previous-chapter',
                    ),
                    style: TextButton.styleFrom(
                      minimumSize: const Size(58, 44),
                      textStyle: const TextStyle(fontSize: 13),
                    ),
                    onPressed: () => unawaited(
                      _previousChapter(
                        dismissControls: true,
                        showLoadingOverlay: true,
                      ),
                    ),
                    child: const Text(ReaderStrings.previousChapter),
                  ),
                  Expanded(
                    child: Slider(
                      value: progress.clamp(0, 1),
                      onChanged: (double value) =>
                          setState(() => _sliderPreview = value),
                      onChangeEnd: _jumpToBookFraction,
                    ),
                  ),
                  TextButton(
                    key: const ValueKey<String>('reader-toolbar-next-chapter'),
                    style: TextButton.styleFrom(
                      minimumSize: const Size(58, 44),
                      textStyle: const TextStyle(fontSize: 13),
                    ),
                    onPressed: () => unawaited(
                      _nextChapter(
                        dismissControls: true,
                        showLoadingOverlay: true,
                      ),
                    ),
                    child: const Text(ReaderStrings.nextChapter),
                  ),
                ],
              ),
              Row(
                children: <Widget>[
                  _barAction(
                    Icons.menu_book_outlined,
                    ReaderStrings.catalog,
                    () => _showLibrarySheet(initialIndex: 1),
                  ),
                  _barAction(
                    _isNightTheme(_preferences.theme)
                        ? Icons.nightlight_rounded
                        : Icons.nightlight_outlined,
                    ReaderStrings.night,
                    _toggleNightTheme,
                    key: const Key('reader-toolbar-night-theme'),
                  ),
                  _barAction(
                    Icons.tune_rounded,
                    ReaderStrings.settings,
                    _showSettingsSheet,
                    key: const Key('reader-toolbar-settings'),
                  ),
                  _barAction(
                    Icons.bookmarks_outlined,
                    ReaderStrings.bookmarks,
                    () => _showLibrarySheet(initialIndex: 2),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _barAction(
    IconData icon,
    String label,
    VoidCallback action, {
    Key? key,
  }) {
    return Expanded(
      child: Semantics(
        key: key,
        button: true,
        label: label,
        excludeSemantics: true,
        // These actions already show their labels. Avoid a Tooltip here: it
        // creates an OverlayPortal while the modal settings route is pushed or
        // popped, which can leave a stale semantics child in Flutter 3.44.
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: action,
          child: SizedBox(
            height: 50,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Icon(icon, size: 21),
                const SizedBox(height: 2),
                Text(label, style: const TextStyle(fontSize: 10.5)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String get _clockLabel {
    final String hour = _clock.hour.toString().padLeft(2, '0');
    final String minute = _clock.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  Future<void> _jumpToBookFraction(double value) async {
    setState(() => _sliderPreview = null);
    _setControlsVisible(false);
    final int navigation = ++_navigationGeneration;
    final int session = _sessionGeneration;
    if (value <= 0) {
      await _showBookPreview();
      return;
    }
    final int total = _catalogTotal > 0 ? _catalogTotal : _catalog.length;
    if (total <= 0) return;
    final double exact = (value.clamp(0, 1) * total)
        .clamp(0, total - 0.000001)
        .toDouble();
    final int index = exact.floor().clamp(0, total - 1);
    final double chapterFraction = exact - index;
    try {
      final ReaderChapterInfo chapter = await _chapterInfoAtIndex(index);
      if (!_isSessionCurrent(session) || navigation != _navigationGeneration) {
        return;
      }
      await _openChapter(
        chapter.id,
        targetChapterFraction: chapterFraction,
        showLoadingOverlay: true,
      );
    } catch (error) {
      if (!_isSessionCurrent(session) || navigation != _navigationGeneration) {
        return;
      }
      await _reportFailure(_asFailure(error, ReaderFailureKind.data));
    }
  }

  bool get _isCurrentBookmarked {
    final ReaderProgress? progress = _progress;
    if (progress == null) return false;
    return _bookmarks.any(
      (bookmark) =>
          bookmark.chapterId == progress.chapterId &&
          bookmark.paragraphId == progress.paragraphId,
    );
  }

  Future<void> _toggleBookmark() {
    _stopAutoReading();
    final int session = _sessionGeneration;
    return _queueBookmarkMutation(() async {
      if (!_isSessionCurrent(session)) return;
      await _performToggleBookmark(session);
    });
  }

  Future<void> _performToggleBookmark(int session) async {
    final ReaderProgress? progress = _progress;
    final TextChapterContent? content = _content;
    if (progress == null || content == null || content.paragraphs.isEmpty) {
      return;
    }
    final int existing = _bookmarks.indexWhere(
      (bookmark) =>
          bookmark.chapterId == progress.chapterId &&
          bookmark.paragraphId == progress.paragraphId,
    );
    final TextReaderStateStore store = widget.stateStore;
    final String bookId = widget.bookId;
    final int session = _sessionGeneration;
    try {
      if (existing >= 0) {
        final ReaderBookmark bookmark = _bookmarks[existing];
        await store.removeBookmark(bookId, bookmark.id);
        if (!mounted ||
            session != _sessionGeneration ||
            bookId != widget.bookId ||
            !identical(store, widget.stateStore)) {
          return;
        }
        setState(() {
          _bookmarks = List.unmodifiable(
            _bookmarks.where((item) => item.id != bookmark.id),
          );
        });
      } else {
        final TextParagraph paragraph = content.paragraphs.firstWhere(
          (item) => item.id == progress.paragraphId,
          orElse: () => content.paragraphs.first,
        );
        final ReaderBookmark bookmark = ReaderBookmark(
          id: '${widget.bookId}-${DateTime.now().microsecondsSinceEpoch}',
          bookId: widget.bookId,
          chapterId: progress.chapterId,
          paragraphId: progress.paragraphId,
          characterOffset: progress.characterOffset,
          chapterTitle: content.title,
          excerpt: paragraph.text.length > 48
              ? '${paragraph.text.substring(0, 48)}…'
              : paragraph.text,
          createdAt: DateTime.now(),
        );
        await store.addBookmark(bookmark);
        if (!mounted ||
            session != _sessionGeneration ||
            bookId != widget.bookId ||
            !identical(store, widget.stateStore)) {
          return;
        }
        setState(
          () => _bookmarks = List.unmodifiable(<ReaderBookmark>[
            ..._bookmarks,
            bookmark,
          ]),
        );
      }
    } catch (error) {
      if (_isSessionCurrent(session)) {
        await _reportFailure(_asFailure(error, ReaderFailureKind.persistence));
      }
    }
  }

  Future<void> _queueBookmarkMutation(Future<void> Function() mutation) {
    final Future<void> next = _bookmarkWrite.then(
      (_) => mutation(),
      onError: (_) => mutation(),
    );
    _bookmarkWrite = next.then<void>((_) {}, onError: (_) {});
    return next;
  }

  bool _isRouteSessionCurrent(
    int session,
    String bookId, {
    TextReaderStateStore? store,
  }) =>
      mounted &&
      !_disposed &&
      session == _sessionGeneration &&
      bookId == widget.bookId &&
      (store == null || identical(store, widget.stateStore));
}
