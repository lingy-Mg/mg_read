part of 'text_reader_view.dart';

// ignore_for_file: invalid_use_of_protected_member

final class _HorizontalChapterHandoff {
  const _HorizontalChapterHandoff({
    required this.content,
    required this.page,
    required this.pageIndex,
    required this.pageCount,
    required this.bookFraction,
  });

  final TextChapterContent content;
  final ReaderPage page;
  final int pageIndex;
  final int pageCount;
  final double bookFraction;
}

extension _TextReaderContentWidgets on _TextReaderViewState {
  Widget _buildHorizontalChapterHandoff(_HorizontalChapterHandoff handoff) {
    return ExcludeSemantics(
      child: IgnorePointer(
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            ReaderBackgroundSurface(
              preset: _preferences.background,
              palette: _palette,
              child: KeyedSubtree(
                key: const ValueKey<String>('reader-chapter-handoff-page'),
                child: _buildPage(
                  handoff.page,
                  handoff.pageIndex,
                  pageContent: handoff.content,
                  pageCount: handoff.pageCount,
                  bookFraction: handoff.bookFraction,
                ),
              ),
            ),
            ColoredBox(
              color: Colors.black.withValues(
                alpha: (1 - _preferences.brightness) * 0.65,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 工具栏显示时覆盖正文，保留其上方 chrome 的交互。
  Widget _buildControlsInteractionLock() {
    return Positioned.fill(
      child: GestureDetector(
        key: const ValueKey<String>('reader-controls-interaction-lock'),
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onTap: _dismissReaderControlsFromReader,
      ),
    );
  }

  /// 覆盖正文并阻止设置弹层之外的输入继续传给阅读器。
  ///
  /// 该层位于 Navigator 的设置路由之下，因此不会拦截设置面板本身；
  /// 仅在弹层透明区域的事件继续命中阅读器时作为最终输入锁和关闭入口。
  Widget _buildSettingsInteractionLock() {
    return Positioned.fill(
      child: GestureDetector(
        key: const ValueKey<String>('reader-settings-interaction-lock'),
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onTap: _dismissReaderSettingsFromReader,
      ),
    );
  }

  ThemeData _readerMaterialTheme(ReaderPalette palette) {
    final ColorScheme scheme =
        ColorScheme.fromSeed(
          seedColor: palette.accent,
          brightness: palette.systemBrightness,
        ).copyWith(
          primary: palette.accent,
          surface: palette.panel,
          onSurface: palette.text,
          outline: palette.divider,
        );
    return ThemeData(
      useMaterial3: true,
      brightness: palette.systemBrightness,
      colorScheme: scheme,
      fontFamily: _preferences.font == ReaderFontPreset.system
          ? readerPackageFontFamily
          : readerFontFamily(_preferences.font),
      fontFamilyFallback: readerFontFallback(_preferences.font),
      scaffoldBackgroundColor: palette.background,
      dividerColor: palette.divider,
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(minimumSize: const Size.square(48)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      listTileTheme: ListTileThemeData(
        dense: true,
        minTileHeight: 52,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  Widget _buildContent() {
    if (_loading && _content == null) {
      return _CenteredStatus(
        color: _palette.secondaryText,
        child: _ReaderLoadingIndicator(
          message: ReaderStrings.loading,
          indicatorColor: _palette.accent,
          textColor: _palette.secondaryText,
        ),
      );
    }
    if (_failure != null && _content == null) {
      return _CenteredStatus(
        color: _palette.secondaryText,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.refresh_rounded, size: 34, color: _palette.accent),
            const SizedBox(height: 10),
            Text(
              _failure?.message ?? ReaderStrings.loadFailed,
              key: const Key('text-reader-status-message'),
              textAlign: TextAlign.center,
            ),
            if (_failure?.location case final String location) ...<Widget>[
              const SizedBox(height: 6),
              Text(
                '发生位置：$location',
                key: const Key('text-reader-status-location'),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: _palette.secondaryText),
              ),
            ],
            if (_failure?.code case final String code) ...<Widget>[
              const SizedBox(height: 3),
              Text(
                '诊断编号：$code',
                key: const Key('text-reader-status-code'),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: _palette.secondaryText),
              ),
            ],
            const SizedBox(height: 10),
            FilledButton.tonal(
              onPressed: _initialize,
              child: const Text(ReaderStrings.retry),
            ),
          ],
        ),
      );
    }
    if (_isBookPreview) return _buildBookPreview();
    if (_content == null) return const SizedBox.shrink();
    return _preferences.navigationMode == ReaderNavigationMode.horizontalPages
        ? _buildHorizontalReader()
        : _buildVerticalReader();
  }

  Widget _buildBookPreview() {
    final ReaderBookInfo? book = _book;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
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
                const SizedBox(height: 8),
                Center(
                  child: Container(
                    width: 108,
                    height: 144,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: <Color>[
                          _palette.accent.withValues(alpha: 0.92),
                          _palette.text.withValues(alpha: 0.78),
                        ],
                      ),
                      boxShadow: <BoxShadow>[
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.18),
                          blurRadius: 18,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.menu_book_rounded,
                      size: 42,
                      color: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  book?.title ?? ReaderStrings.bookPreview,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: _palette.text,
                    fontSize: 25,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (book?.author?.isNotEmpty == true) ...<Widget>[
                  const SizedBox(height: 6),
                  Text(
                    book!.author!,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: _palette.secondaryText),
                  ),
                ],
                const SizedBox(height: 14),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    Icon(
                      Icons.format_list_numbered_rounded,
                      size: 18,
                      color: _palette.secondaryText,
                    ),
                    const SizedBox(width: 7),
                    Text(
                      ReaderStrings.chapterCount(_catalogTotal),
                      style: TextStyle(color: _palette.secondaryText),
                    ),
                  ],
                ),
                if (book?.description?.isNotEmpty == true) ...<Widget>[
                  const SizedBox(height: 20),
                  Container(
                    padding: const EdgeInsets.all(15),
                    decoration: BoxDecoration(
                      color: _palette.panel.withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: _palette.divider),
                    ),
                    child: Text(
                      book!.description!,
                      style: TextStyle(
                        color: _palette.text,
                        fontSize: 15,
                        height: 1.65,
                      ),
                    ),
                  ),
                ],
                if (widget.extensions.commentFeed != null &&
                    _preferences.showBookComments) ...<Widget>[
                  const SizedBox(height: 14),
                  _buildBookCommentSummary(
                    target: ReaderCommentTarget.book(widget.bookId),
                    onPressed: () => _showComments(
                      ReaderCommentTarget.book(widget.bookId),
                      title: ReaderCommentStrings.bookTitle,
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                Center(
                  child: SizedBox(
                    width: 220,
                    child: FilledButton.icon(
                      key: const ValueKey<String>('reader-start-reading'),
                      onPressed: _catalogTotal > 0
                          ? () => unawaited(
                              _nextChapter(showLoadingOverlay: true),
                            )
                          : null,
                      icon: const Icon(Icons.arrow_forward_rounded, size: 19),
                      label: const Text(ReaderStrings.startReading),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHorizontalReader() {
    if (_pages.isEmpty) {
      return Center(
        child: _changingChapter
            ? const CircularProgressIndicator(strokeWidth: 2)
            : Text(
                _content!.paragraphs.isEmpty
                    ? ReaderStrings.emptyChapter
                    : ReaderStrings.loading,
                style: TextStyle(color: _palette.secondaryText),
              ),
      );
    }
    final ScrollBehavior horizontalPageScrollBehavior =
        ScrollConfiguration.of(context).copyWith(
          // Flutter excludes mouse drags from scrollables by default. This
          // restores PageView's native, position-following drag behavior.
          dragDevices: <PointerDeviceKind>{
            ...ScrollConfiguration.of(context).dragDevices,
            PointerDeviceKind.mouse,
          },
        );
    return GestureDetector(
      key: const ValueKey<String>('reader-content-surface'),
      behavior: HitTestBehavior.translucent,
      supportedDevices: const <PointerDeviceKind>{
        PointerDeviceKind.touch,
        PointerDeviceKind.stylus,
        PointerDeviceKind.invertedStylus,
      },
      onTapUp: (TapUpDetails details) =>
          _handleHorizontalTap(details.localPosition),
      onHorizontalDragStart: _usesDirectPageTurns && !_readerInteractionBlocked
          ? (_) {
              _stopAutoReading();
              _directDragDelta = 0;
            }
          : null,
      onHorizontalDragUpdate: _usesDirectPageTurns && !_readerInteractionBlocked
          ? (DragUpdateDetails details) {
              _directDragDelta += details.primaryDelta ?? 0;
            }
          : null,
      onHorizontalDragEnd: _usesDirectPageTurns && !_readerInteractionBlocked
          ? (_) {
              final double delta = _directDragDelta;
              _directDragDelta = 0;
              if (delta.abs() < 36) return;
              if (delta < 0) {
                unawaited(_nextPage());
              } else {
                unawaited(_previousPage());
              }
            }
          : null,
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerSignal: _handlePointerSignal,
        onPointerDown: (PointerDownEvent event) {
          _pauseAdjacentPreparationForInteraction();
          _trackMousePointerDown(event);
        },
        onPointerMove: _trackMousePointerMove,
        onPointerUp: _finishMousePointer,
        onPointerCancel: _finishMousePointer,
        child: ScrollConfiguration(
          behavior: horizontalPageScrollBehavior,
          child: NotificationListener<ScrollNotification>(
            onNotification: (ScrollNotification notification) {
              if (notification is ScrollStartNotification) {
                _horizontalPageScrollActive = true;
                _pauseAdjacentPreparationForInteraction();
              } else if (notification case ScrollUpdateNotification update) {
                if (update.dragDetails != null) _stopAutoReading();
                final double? page = _pageController.hasClients
                    ? _pageController.page
                    : null;
                if (page != null && update.scrollDelta != null) {
                  _pageTurnForward = update.scrollDelta! > 0;
                }
              } else if (notification is ScrollEndNotification) {
                _horizontalPageScrollActive = false;
                _pauseAdjacentPreparationForInteraction();
                _commitHorizontalBoundaryAfterScroll();
              }
              return false;
            },
            child: PageView.builder(
              key: ObjectKey(_pageController),
              controller: _pageController,
              // Keep the immediately adjacent sheets laid out so the first
              // drag toward a new page does not also build its text tree.
              allowImplicitScrolling: true,
              physics: _readerInteractionBlocked || _usesDirectPageTurns
                  ? const NeverScrollableScrollPhysics()
                  : const PageScrollPhysics(),
              itemCount: _pages.length + 2,
              onPageChanged: _onHorizontalPageChanged,
              itemBuilder: (BuildContext context, int index) {
                final Widget page = index == 0
                    ? _chapterBoundary(ReaderStrings.previousChapter)
                    : index == _pages.length + 1
                    ? _buildNextChapterBoundary()
                    : _buildPage(_pages[index - 1], index - 1);
                return _buildPageEffect(index, page);
              },
            ),
          ),
        ),
      ),
    );
  }

  bool get _usesDirectPageTurns =>
      _preferences.pageAnimation == ReaderPageAnimation.none ||
      MediaQuery.disableAnimationsOf(context);

  void _handlePointerSignal(PointerSignalEvent event) {
    _pauseAdjacentPreparationForInteraction();
    if (_readerInteractionBlocked ||
        event is! PointerScrollEvent ||
        _changingChapter) {
      return;
    }
    final double delta =
        event.scrollDelta.dy.abs() >= event.scrollDelta.dx.abs()
        ? event.scrollDelta.dy
        : event.scrollDelta.dx;
    _wheelDelta += delta;
    _wheelResetTimer?.cancel();
    _wheelResetTimer = Timer(const Duration(milliseconds: 140), () {
      _wheelDelta = 0;
    });
    if (_wheelDelta.abs() < 36) return;
    final bool forward = _wheelDelta > 0;
    _wheelDelta = 0;
    if (forward) {
      unawaited(_nextPage());
    } else {
      unawaited(_previousPage());
    }
  }

  Widget _chapterBoundary(String label, {bool loading = false}) {
    return Center(
      child: _changingChapter || loading
          ? const CircularProgressIndicator(strokeWidth: 2)
          : Text(label, style: TextStyle(color: _palette.secondaryText)),
    );
  }

  Widget _buildNextChapterBoundary() {
    final _PreparedHorizontalChapter? prepared =
        _preparedNextHorizontalChapter();
    if (prepared == null) {
      final bool preparing = switch (_adjacentPreparationStage) {
        _AdjacentPreparationStage.contentLoading ||
        _AdjacentPreparationStage.contentReady ||
        _AdjacentPreparationStage.layoutLoading => true,
        _AdjacentPreparationStage.pending ||
        _AdjacentPreparationStage.ready => false,
      };
      return _chapterBoundary(ReaderStrings.nextChapter, loading: preparing);
    }
    return KeyedSubtree(
      key: const ValueKey<String>('reader-next-chapter-page'),
      child: _buildPage(
        prepared.pages.first,
        0,
        pageContent: prepared.content,
        pageCount: prepared.pages.length,
        bookFraction: _catalogTotal <= 0
            ? 0
            : prepared.info.index / _catalogTotal,
      ),
    );
  }

  Widget _buildPage(
    ReaderPage page,
    int index, {
    TextChapterContent? pageContent,
    int? pageCount,
    double? bookFraction,
  }) {
    final TextChapterContent content = pageContent ?? _content!;
    final int resolvedPageCount = pageCount ?? _pages.length;
    final double resolvedBookFraction =
        bookFraction ?? _progress?.bookFraction ?? 0;
    return SafeArea(
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                _preferences.horizontalPadding,
                _preferences.topPadding,
                _preferences.horizontalPadding,
                _preferences.bottomPadding,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  if (page.showsTitle) ...<Widget>[
                    Text(
                      content.title,
                      style: _titleTextStyle,
                      textScaler: _textScaler,
                    ),
                    const SizedBox(height: 28),
                  ],
                  for (final ReaderPageBlock block in page.blocks) ...<Widget>[
                    if (block.text.isNotEmpty || block.hasParagraphTrailing)
                      Text.rich(
                        TextSpan(
                          style: _bodyTextStyle,
                          children: <InlineSpan>[
                            TextSpan(
                              text: block.text.isEmpty
                                  ? ''
                                  : block.isParagraphStart
                                  ? _indented(block.text)
                                  : block.text,
                            ),
                            if (block.hasParagraphTrailing &&
                                _preferences.showParagraphComments)
                              WidgetSpan(
                                alignment: PlaceholderAlignment.middle,
                                child: _inlineParagraphComment(
                                  target: ReaderCommentTarget.paragraph(
                                    widget.bookId,
                                    content.chapterId,
                                    block.paragraphId,
                                  ),
                                  onPressed: () => _showComments(
                                    ReaderCommentTarget.paragraph(
                                      widget.bookId,
                                      content.chapterId,
                                      block.paragraphId,
                                    ),
                                    title: ReaderCommentStrings.paragraphTitle,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        textScaler: _textScaler,
                      ),
                    if (block.isParagraphEnd)
                      SizedBox(height: _preferences.paragraphSpacing),
                  ],
                  if (page.showsChapterTrailing)
                    _buildChapterCommentSummary(
                      height: page.chapterTrailingHeight,
                      chapterContent: content,
                    ),
                ],
              ),
            ),
          ),
          Positioned(
            key: const ValueKey<String>('reader-page-footer'),
            left: _preferences.horizontalPadding,
            right: _preferences.horizontalPadding,
            bottom: _TextReaderViewState._pageFooterBottomInset,
            child: IgnorePointer(
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      content.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: _palette.secondaryText,
                        fontSize: 11,
                      ),
                    ),
                  ),
                  Text(
                    '${(resolvedBookFraction * 100).toStringAsFixed(1)}% · ${index + 1}/$resolvedPageCount',
                    style: TextStyle(
                      color: _palette.secondaryText,
                      fontSize: 11,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    _clockLabel,
                    style: TextStyle(
                      color: _palette.secondaryText,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChapterCommentSummary({
    double height = 168,
    TextChapterContent? chapterContent,
  }) {
    final TextChapterContent? content = chapterContent ?? _content;
    if (content == null || widget.extensions.commentFeed == null) {
      return const SizedBox.shrink();
    }
    final ReaderCommentTarget target = ReaderCommentTarget.chapter(
      widget.bookId,
      content.chapterId,
    );
    final ReaderCommentSummary summary = _commentSummary(target);
    final bool loading = _commentSummariesLoading;
    final bool failed = _commentSummariesFailed;
    final double resolvedHeight = height.clamp(0, 168).toDouble();
    return SizedBox(
      height: resolvedHeight,
      child: Material(
        color: _palette.panel.withValues(alpha: .82),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: _palette.divider),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: loading
              ? null
              : failed
              ? () => unawaited(_refreshCommentSummaries())
              : () => _showComments(
                  target,
                  title: ReaderCommentStrings.chapterTitle,
                ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Icon(
                      Icons.chat_bubble_outline_rounded,
                      size: 17,
                      color: _palette.accent,
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        loading
                            ? ReaderCommentStrings.chapterLoading
                            : failed
                            ? ReaderCommentStrings.chapterLoadFailed
                            : ReaderCommentStrings.chapterSummary(
                                summary.total,
                              ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    const Icon(Icons.chevron_right_rounded, size: 19),
                  ],
                ),
                const SizedBox(height: 8),
                if (!loading && !failed && summary.topComments.isEmpty)
                  Text(
                    ReaderCommentStrings.empty,
                    style: TextStyle(color: _palette.secondaryText),
                  )
                else if (!loading && !failed)
                  for (final ReaderComment comment in summary.topComments.take(
                    3,
                  ))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 5),
                      child: Text(
                        '${comment.authorName}：${comment.content}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: _palette.secondaryText,
                          fontSize: 12,
                        ),
                      ),
                    ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
