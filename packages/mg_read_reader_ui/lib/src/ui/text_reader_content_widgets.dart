part of 'text_reader_view.dart';

// ignore_for_file: invalid_use_of_protected_member

extension _TextReaderContentWidgets on _TextReaderViewState {
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
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox.square(
              dimension: 30,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(height: 12),
            Text(ReaderStrings.loading),
          ],
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
            const Text(ReaderStrings.loadFailed),
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
                  child: IconButton(
                    key: const ValueKey<String>('reader-back-action'),
                    tooltip: ReaderStrings.back,
                    onPressed: _requestExit,
                    icon: const Icon(Icons.arrow_back_ios_new_rounded),
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
                      onPressed: _catalogTotal > 0 ? _nextChapter : null,
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
        child: Text(
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
      onHorizontalDragStart: _usesDirectPageTurns && !_readerSettingsVisible
          ? (_) {
              _stopAutoReading();
              _directDragDelta = 0;
            }
          : null,
      onHorizontalDragUpdate: _usesDirectPageTurns && !_readerSettingsVisible
          ? (DragUpdateDetails details) {
              _directDragDelta += details.primaryDelta ?? 0;
            }
          : null,
      onHorizontalDragEnd: _usesDirectPageTurns && !_readerSettingsVisible
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
        onPointerDown: _trackMousePointerDown,
        onPointerMove: _trackMousePointerMove,
        onPointerUp: _finishMousePointer,
        onPointerCancel: _finishMousePointer,
        child: ScrollConfiguration(
          behavior: horizontalPageScrollBehavior,
          child: NotificationListener<ScrollUpdateNotification>(
            onNotification: (ScrollUpdateNotification notification) {
              if (notification.dragDetails != null) _stopAutoReading();
              final double? page = _pageController.hasClients
                  ? _pageController.page
                  : null;
              if (page != null && notification.scrollDelta != null) {
                _pageTurnForward = notification.scrollDelta! > 0;
              }
              return false;
            },
            child: PageView.builder(
              controller: _pageController,
              physics: _readerSettingsVisible || _usesDirectPageTurns
                  ? const NeverScrollableScrollPhysics()
                  : const PageScrollPhysics(),
              itemCount: _pages.length + 2,
              onPageChanged: _onHorizontalPageChanged,
              itemBuilder: (BuildContext context, int index) {
                final Widget page = index == 0
                    ? _chapterBoundary(ReaderStrings.previousChapter)
                    : index == _pages.length + 1
                    ? _chapterBoundary(ReaderStrings.nextChapter)
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
    if (_readerSettingsVisible ||
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

  Widget _chapterBoundary(String label) {
    return Center(
      child: _changingChapter
          ? const CircularProgressIndicator(strokeWidth: 2)
          : Text(label, style: TextStyle(color: _palette.secondaryText)),
    );
  }

  Widget _buildPageEffect(int rawIndex, Widget child) {
    if (_preferences.pageAnimation == ReaderPageAnimation.slide) return child;
    final Widget effectChild =
        _preferences.pageAnimation == ReaderPageAnimation.cover
        ? ReaderBackgroundSurface(
            preset: _preferences.background,
            palette: _palette,
            child: child,
          )
        : child;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return AnimatedBuilder(
          animation: _pageController,
          child: effectChild,
          builder: (BuildContext context, Widget? child) {
            final double page = _pageController.hasClients
                ? (_pageController.page ??
                      _pageController.initialPage.toDouble())
                : _pageController.initialPage.toDouble();
            final double distance = (rawIndex - page)
                .abs()
                .clamp(0, 1)
                .toDouble();
            final bool entering = _pageTurnForward
                ? rawIndex > page
                : rawIndex < page;
            return Transform.translate(
              offset: Offset((page - rawIndex) * constraints.maxWidth, 0),
              child: ReaderPageEffect(
                animation: _preferences.pageAnimation,
                progress: entering ? 1 - distance : distance,
                entering: entering,
                forward: _pageTurnForward,
                reduceMotion: MediaQuery.disableAnimationsOf(context),
                child: child!,
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildPage(ReaderPage page, int index) {
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
                      _content!.title,
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
                                    _content!.chapterId,
                                    block.paragraphId,
                                  ),
                                  onPressed: () => _showComments(
                                    ReaderCommentTarget.paragraph(
                                      widget.bookId,
                                      _content!.chapterId,
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
                      _content!.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: _palette.secondaryText,
                        fontSize: 11,
                      ),
                    ),
                  ),
                  Text(
                    '${((_progress?.bookFraction ?? 0) * 100).toStringAsFixed(1)}% · ${index + 1}/${_pages.length}',
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

  Widget _buildChapterCommentSummary({double height = 168}) {
    final TextChapterContent? content = _content;
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

  Widget _buildVerticalReader() {
    final List<TextParagraph> paragraphs = _content!.paragraphs;
    final bool showChapterComments =
        widget.extensions.commentFeed != null &&
        _preferences.showChapterComments;
    final bool showParagraphComments =
        widget.extensions.commentFeed != null &&
        _preferences.showParagraphComments;
    final int chapterSummaryIndex = paragraphs.length + 1;
    final int nextChapterIndex =
        chapterSummaryIndex + (showChapterComments ? 1 : 0);
    return GestureDetector(
      key: const ValueKey<String>('reader-content-surface'),
      behavior: HitTestBehavior.translucent,
      onTapUp: (_) {
        if (_readerSettingsVisible) {
          _dismissReaderSettingsFromReader();
          return;
        }
        _stopAutoReading();
        _setControlsVisible(!_controlsVisible);
      },
      child: SafeArea(
        child: NotificationListener<UserScrollNotification>(
          onNotification: (UserScrollNotification notification) {
            if (!_autoScrolling &&
                notification.direction != ScrollDirection.idle) {
              _stopAutoReading();
            }
            return false;
          },
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final double contentWidth =
                  (constraints.maxWidth - _preferences.horizontalPadding * 2)
                      .clamp(1, constraints.maxWidth.clamp(1, double.infinity));
              _prepareVerticalItemExtents(
                width: contentWidth,
                textDirection: Directionality.of(context),
                itemCount: nextChapterIndex + 1,
                hasParagraphComments: showParagraphComments,
                hasChapterComments: showChapterComments,
              );
              return ListView.builder(
                controller: _verticalController,
                physics: _readerSettingsVisible
                    ? const NeverScrollableScrollPhysics()
                    : null,
                padding: EdgeInsets.fromLTRB(
                  _preferences.horizontalPadding,
                  _preferences.topPadding,
                  _preferences.horizontalPadding,
                  _preferences.bottomPadding,
                ),
                itemCount: nextChapterIndex + 1,
                itemExtentBuilder: (int index, _) => _verticalItemExtent(index),
                itemBuilder: (BuildContext context, int index) {
                  if (index == 0) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 28),
                      child: Text(
                        _content!.title,
                        style: _titleTextStyle,
                        textScaler: _textScaler,
                      ),
                    );
                  }
                  if (index <= paragraphs.length) {
                    final TextParagraph paragraph = paragraphs[index - 1];
                    final ReaderCommentTarget target =
                        ReaderCommentTarget.paragraph(
                          widget.bookId,
                          _content!.chapterId,
                          paragraph.id,
                        );
                    return Column(
                      key: _paragraphKey(paragraph.id),
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Padding(
                          padding: EdgeInsets.only(
                            bottom: _preferences.paragraphSpacing,
                          ),
                          child: Text.rich(
                            TextSpan(
                              style: _bodyTextStyle,
                              children: <InlineSpan>[
                                TextSpan(text: _indented(paragraph.text)),
                                if (showParagraphComments)
                                  WidgetSpan(
                                    alignment: PlaceholderAlignment.middle,
                                    child: _inlineParagraphComment(
                                      target: target,
                                      onPressed: () => _showComments(
                                        target,
                                        title:
                                            ReaderCommentStrings.paragraphTitle,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            textScaler: _textScaler,
                          ),
                        ),
                      ],
                    );
                  }
                  if (showChapterComments && index == chapterSummaryIndex) {
                    return _buildChapterCommentSummary();
                  }
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: OutlinedButton(
                      onPressed: _nextChapter,
                      child: const Text(ReaderStrings.nextChapter),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }
}
