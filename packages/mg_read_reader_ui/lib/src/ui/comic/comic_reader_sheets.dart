/// 漫画阅读器的评论、书签和设置模态面板。
///
/// 职责：渲染会话内弹层，并用会话世代隔离异步回调。
/// 注意：不持有独立持久状态；会话关闭时由视图关闭活动弹层。
part of 'comic_reader_view.dart';

// ignore_for_file: invalid_use_of_protected_member

extension _ComicReaderSheets on _ComicReaderViewState {
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

  Future<void> _showSettings() async {
    if (_settingsVisible) return;
    final int session = _sessionGeneration;
    final String bookId = widget.bookId;
    final ComicReaderDataSource source = widget.dataSource;
    final ComicReaderStateStore store = widget.stateStore;
    bool isCurrent() => _isSession(session, bookId, source, store);
    final int sheetGeneration = _beginSheet();
    // The sheet needs the normal system-bar geometry. This is a session-only
    // override; the persisted immersive preference is restored on dismissal.
    await _setSettingsVisible(true);
    if (!mounted || _disposed || !isCurrent()) {
      await _setSettingsVisible(false);
      return;
    }
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
                  final bool layoutChanged =
                      normalized.imageSpacing != _preferences.imageSpacing ||
                      normalized.contentWidthFraction !=
                          _preferences.contentWidthFraction;
                  // Scroll notifications may precede image layout. Capture the
                  // currently rendered anchor before changing image extents.
                  if (layoutChanged) _updateProgressFromScroll();
                  final ComicReaderProgress? anchor = _progress;
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
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: <Widget>[
                                    const Text(ComicReaderStrings.contentWidth),
                                    Text(
                                      _preferences.contentWidthFraction == 1
                                          ? '100%（不限制）'
                                          : '${(_preferences.contentWidthFraction * 100).round()}%',
                                    ),
                                  ],
                                ),
                                Slider(
                                  key: const ValueKey<String>(
                                    'comic-reader-content-width',
                                  ),
                                  value: _preferences.contentWidthFraction,
                                  min: .1,
                                  max: 1,
                                  divisions: 90,
                                  semanticFormatterCallback: (double value) =>
                                      '${(value * 100).round()}%',
                                  onChanged: (double value) => update(
                                    _preferences.copyWith(
                                      contentWidthFraction: value,
                                    ),
                                    persist: false,
                                  ),
                                  onChangeEnd: (_) => commit(),
                                ),
                                _settingSlider(
                                  label: ComicReaderStrings.brightness,
                                  value: _preferences.brightness,
                                  min: .25,
                                  max: 1,
                                  onChanged: (double value) => update(
                                    _preferences.copyWith(brightness: value),
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
                                      _preferences.copyWith(
                                        keepScreenOn: value,
                                      ),
                                    ),
                                  ),
                                SwitchListTile.adaptive(
                                  contentPadding: EdgeInsets.zero,
                                  title: const Text(
                                    ComicReaderStrings.pageTurnShortcuts,
                                  ),
                                  value: _preferences.pageTurnShortcuts,
                                  onChanged: (bool value) => update(
                                    _preferences.copyWith(
                                      pageTurnShortcuts: value,
                                    ),
                                  ),
                                ),
                                DropdownButtonFormField<double>(
                                  key: const ValueKey<String>(
                                    'comic-reader-page-turn-fraction',
                                  ),
                                  initialValue: _preferences.pageTurnFraction,
                                  decoration: const InputDecoration(
                                    labelText:
                                        ComicReaderStrings.pageTurnFraction,
                                  ),
                                  items: ComicReaderPreferences
                                      .pageTurnFractions
                                      .map(
                                        (double fraction) =>
                                            DropdownMenuItem<double>(
                                              value: fraction,
                                              child: Text(
                                                '${(fraction * 100).round()}%',
                                              ),
                                            ),
                                      )
                                      .toList(),
                                  onChanged: (double? value) {
                                    if (value != null) {
                                      update(
                                        _preferences.copyWith(
                                          pageTurnFraction: value,
                                        ),
                                      );
                                    }
                                  },
                                ),
                                DropdownButtonFormField<ComicPageTurnLayout>(
                                  key: const ValueKey<String>(
                                    'comic-reader-page-turn-layout',
                                  ),
                                  initialValue: _preferences.pageTurnLayout,
                                  decoration: const InputDecoration(
                                    labelText:
                                        ComicReaderStrings.pageTurnLayout,
                                  ),
                                  items:
                                      const <
                                        DropdownMenuItem<ComicPageTurnLayout>
                                      >[
                                        DropdownMenuItem<ComicPageTurnLayout>(
                                          value: ComicPageTurnLayout.vertical,
                                          child: Text(
                                            ComicReaderStrings.pageTurnVertical,
                                          ),
                                        ),
                                        DropdownMenuItem<ComicPageTurnLayout>(
                                          value: ComicPageTurnLayout.horizontal,
                                          child: Text(
                                            ComicReaderStrings
                                                .pageTurnHorizontal,
                                          ),
                                        ),
                                      ],
                                  onChanged: (ComicPageTurnLayout? value) {
                                    if (value != null) {
                                      update(
                                        _preferences.copyWith(
                                          pageTurnLayout: value,
                                        ),
                                      );
                                    }
                                  },
                                ),
                                SwitchListTile.adaptive(
                                  contentPadding: EdgeInsets.zero,
                                  title: const Text(
                                    ComicReaderStrings.singleHandMode,
                                  ),
                                  value: _preferences.singleHandMode,
                                  onChanged: (bool value) => update(
                                    _preferences.copyWith(
                                      singleHandMode: value,
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
                                      _preferences.copyWith(
                                        immersiveMode: value,
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
        if (_settingsVisible) unawaited(_setSettingsVisible(false));
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
