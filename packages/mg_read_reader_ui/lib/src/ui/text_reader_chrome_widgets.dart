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
    return Material(
      color: _palette.panel,
      elevation: 0,
      child: SafeArea(
        bottom: false,
        child: Container(
          height: 76,
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: _palette.divider)),
          ),
          child: Stack(
            children: <Widget>[
              Positioned(
                left: 56,
                right: 96,
                top: 0,
                height: 45,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _book?.title ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              Positioned(
                left: 56,
                right: 56,
                bottom: 3,
                height: 24,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: _palette.panel.withValues(alpha: .76),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: _buildCompactSourceRow(),
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: IconButton(
                  key: const ValueKey<String>('reader-back-action'),
                  tooltip: ReaderStrings.back,
                  onPressed: _requestExit,
                  icon: const Icon(Icons.arrow_back_ios_new_rounded),
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    IconButton(
                      tooltip: _isCurrentBookmarked
                          ? ReaderStrings.removeBookmark
                          : ReaderStrings.addBookmark,
                      onPressed: _toggleBookmark,
                      icon: Icon(
                        _isCurrentBookmarked
                            ? Icons.bookmark_rounded
                            : Icons.bookmark_border_rounded,
                        color: _isCurrentBookmarked ? _palette.accent : null,
                      ),
                    ),
                    IconButton(
                      tooltip: ReaderStrings.refreshChapter,
                      onPressed: _content == null
                          ? null
                          : () => unawaited(_refreshCurrentChapter()),
                      icon: const Icon(Icons.refresh_rounded, size: 21),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCompactSourceRow() {
    final String sourceName = _sourceDisplayName;
    final String? sourceUrl = _sourceDisplayUrl;
    final Uri? sourceUri = _sourceDisplayUri;
    return SizedBox(
      height: 22,
      child: Row(
        children: <Widget>[
          Flexible(
            child: Text(
              sourceName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: _palette.secondaryText.withValues(alpha: .78),
                fontSize: 11,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Container(width: 1, height: 14, color: _palette.divider),
          const SizedBox(width: 8),
          Expanded(
            child: _buildSourceUrlAction(
              sourceUrl: sourceUrl,
              sourceUri: sourceUri,
              compact: true,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSourceUrlAction({
    required String? sourceUrl,
    required Uri? sourceUri,
    bool compact = false,
  }) {
    final Widget label = Row(
      children: <Widget>[
        Icon(
          Icons.open_in_new_rounded,
          size: compact ? 14 : 16,
          color: sourceUri == null
              ? _palette.secondaryText.withValues(alpha: .78)
              : compact
              ? _palette.accent.withValues(alpha: .82)
              : _palette.accent,
        ),
        const SizedBox(width: 5),
        Expanded(
          child: Text(
            sourceUrl ?? ReaderStrings.sourceUrlUnavailable,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: sourceUri == null
                  ? _palette.secondaryText.withValues(alpha: .78)
                  : compact
                  ? _palette.text.withValues(alpha: .78)
                  : _palette.text,
              fontSize: compact ? 11 : 12,
              decoration: sourceUri == null ? null : TextDecoration.underline,
              decorationColor: _palette.accent,
            ),
          ),
        ),
      ],
    );
    if (sourceUri == null) return label;
    return Tooltip(
      message: sourceUrl!,
      child: Semantics(
        button: true,
        link: true,
        label: '${ReaderStrings.openSourceUrl}: $sourceUrl',
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => unawaited(_openSourceUrl(sourceUri)),
          child: SizedBox(height: compact ? 22 : 48, child: label),
        ),
      ),
    );
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

  Future<void> _refreshCurrentChapter() async {
    final String? chapterId = _content?.chapterId;
    if (chapterId == null) return;
    await _openChapter(chapterId, forceRefresh: true);
  }

  String get _sourceDisplayName {
    final String? sourceName = _book?.sourceName?.trim();
    return sourceName == null || sourceName.isEmpty
        ? ReaderStrings.sourceUnavailable
        : sourceName;
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
                    style: TextButton.styleFrom(
                      minimumSize: const Size(58, 44),
                      textStyle: const TextStyle(fontSize: 13),
                    ),
                    onPressed: _previousChapter,
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
                    style: TextButton.styleFrom(
                      minimumSize: const Size(58, 44),
                      textStyle: const TextStyle(fontSize: 13),
                    ),
                    onPressed: _nextChapter,
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
      await _openChapter(chapter.id, targetChapterFraction: chapterFraction);
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
