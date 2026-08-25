part of 'text_reader_view.dart';

// ignore_for_file: invalid_use_of_protected_member

extension _TextReaderPagination on _TextReaderViewState {
  void _ensurePagination(Size size) {
    if (_content == null ||
        _preferences.navigationMode != ReaderNavigationMode.horizontalPages ||
        size.isEmpty) {
      return;
    }
    final ReaderLayoutFingerprint fingerprint = _layoutFingerprintFor(size);
    if (_layoutFingerprint == fingerprint) return;
    _paginateFirstPage(size, fingerprint);
  }

  ReaderLayoutFingerprint _layoutFingerprintFor(Size size) {
    final EdgeInsets safe = MediaQuery.paddingOf(context);
    final bool paragraphComments =
        widget.extensions.commentFeed != null &&
        _preferences.showParagraphComments;
    final bool chapterComments =
        widget.extensions.commentFeed != null &&
        _preferences.showChapterComments;
    return ReaderLayoutFingerprint(
      chapterId: _content!.chapterId,
      contentVersion: _content!.contentVersion,
      sessionId: _content!.contentVersion == null
          ? _contentLayoutIdentity(_content!)
          : 0,
      viewport: size,
      safeArea: safe,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      textScale: _textScaler.scale(1),
      fontVersion:
          '${_preferences.font.name}:${_preferences.customFontId ?? ''}:${_runtimeFontDescriptor?.version ?? ''}:${_runtimeFontFamily ?? ''}',
      layoutSettings:
          '${_preferences.navigationMode.name}:${_preferences.pageAnimation.name}:${_preferences.firstLineIndent}:${_preferences.horizontalPadding}:${_preferences.topPadding}:${_preferences.bottomPadding}',
      textDirection: Directionality.of(context),
      fontSize: _preferences.fontSize,
      fontWeight: _preferences.fontWeight,
      letterSpacing: _preferences.letterSpacing,
      lineHeight: _preferences.lineHeight,
      paragraphSpacing: _preferences.paragraphSpacing,
      firstLineIndent: _preferences.firstLineIndent,
      horizontalPadding: _preferences.horizontalPadding,
      topPadding: _preferences.topPadding,
      bottomPadding: _preferences.bottomPadding,
      paragraphCommentPlaceholder: paragraphComments
          ? _TextReaderViewState._inlineCommentHitSize
          : 0,
      chapterCommentPlaceholder: chapterComments ? 168 : 0,
    );
  }

  int _contentLayoutIdentity(TextChapterContent content) {
    final int? existing =
        _TextReaderViewState._contentLayoutIdentities[content];
    if (existing != null) return existing;
    final int identity = _TextReaderViewState._nextContentLayoutIdentity++;
    _TextReaderViewState._contentLayoutIdentities[content] = identity;
    return identity;
  }

  double _paginationWidth(Size size) => size.width <= 1
      ? size.width
      : (size.width -
                (_preferences.horizontalPadding * 2).clamp(0, size.width - 1))
            .clamp(1, size.width);

  double _paginationHeight(Size size) {
    final EdgeInsets safe = MediaQuery.paddingOf(context);
    final double rawHeight =
        size.height -
        safe.top -
        safe.bottom -
        _preferences.topPadding -
        _preferences.bottomPadding -
        _TextReaderViewState._horizontalPageLayoutSafety;
    return size.height <= 1 ? size.height : rawHeight.clamp(1, size.height);
  }

  void _paginateFirstPage(Size size, ReaderLayoutFingerprint fingerprint) {
    final TextChapterContent? content = _content;
    if (content == null) return;
    final Stopwatch stopwatch = Stopwatch()..start();
    final List<ReaderPage>? cached = _TextReaderViewState._layoutCache.take(
      fingerprint,
    );
    if (cached != null) {
      _layoutFingerprint = fingerprint;
      _pages = cached;
      _currentPaginationComplete = true;
      _pageIndex = _pageIndexForAnchor(
        cached,
      ).clamp(0, cached.isEmpty ? 0 : cached.length - 1);
      _firstContentPreparation = ReaderPaginationPreparation.cachedFirstPage;
      _firstContentLayoutDuration = stopwatch.elapsed;
      _finishHorizontalPagination();
      return;
    }
    final ReaderProgress? anchor = _progress;
    final int anchorIndex = anchor == null
        ? 0
        : content.paragraphs
              .indexWhere(
                (TextParagraph paragraph) => paragraph.id == anchor.paragraphId,
              )
              .clamp(
                0,
                content.paragraphs.isEmpty ? 0 : content.paragraphs.length - 1,
              );
    final int anchorOffset = anchor == null || content.paragraphs.isEmpty
        ? 0
        : anchor.characterOffset.clamp(
            0,
            content.paragraphs[anchorIndex].text.length,
          );
    final int viewEnd =
        (anchorIndex + _TextReaderViewState._progressiveParagraphBatchSize + 1)
            .clamp(0, content.paragraphs.length);
    final List<TextParagraph> firstView = <TextParagraph>[];
    for (var index = anchorIndex; index < viewEnd; index++) {
      final TextParagraph paragraph = content.paragraphs[index];
      firstView.add(
        index == anchorIndex && anchorOffset > 0
            ? TextParagraph(
                id: paragraph.id,
                text: paragraph.text.substring(anchorOffset),
              )
            : paragraph,
      );
    }
    final List<ReaderPage> pages = _paginateContent(
      size,
      TextChapterContent(
        chapterId: content.chapterId,
        title: content.title,
        paragraphs: firstView,
        contentVersion: content.contentVersion,
      ),
      fingerprint,
      stopAtAnchor: false,
      maximumPages: 1,
      paragraphBaseOffset: anchorOffset,
      includeChapterTitle: anchorIndex == 0 && anchorOffset == 0,
    );
    _layoutFingerprint = fingerprint;
    _pages = pages;
    _currentPaginationComplete = false;
    _pageIndex = _pageIndexForAnchor(
      pages,
    ).clamp(0, pages.isEmpty ? 0 : pages.length - 1);
    _firstContentPreparation = ReaderPaginationPreparation.firstPage;
    _firstContentLayoutDuration = stopwatch.elapsed;
    _restoreHorizontalPageLater();
    final int generation = ++_paginationGeneration;
    _progressiveParagraphCursor = 0;
    _progressivePages = const <ReaderPage>[];
    _progressiveContinuation = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _paginationGeneration) return;
      _paginateRemaining(size, fingerprint, generation);
    });
  }

  int _pageIndexForAnchor(List<ReaderPage> pages) {
    final ReaderProgress? anchor = _progress;
    return anchor == null
        ? 0
        : _paginator.pageIndexForAnchor(
            pages,
            anchor.paragraphId,
            anchor.characterOffset,
          );
  }

  List<ReaderPage> _paginateContent(
    Size size,
    TextChapterContent content,
    ReaderLayoutFingerprint fingerprint, {
    required bool stopAtAnchor,
    int? maximumPages,
    int paragraphBaseOffset = 0,
    bool includeChapterTitle = true,
  }) {
    final double width = _paginationWidth(size);
    final double height = _paginationHeight(size);
    final TextStyle bodyStyle = _bodyTextStyle;
    try {
      return _paginator.paginate(
        chapter: content,
        width: width,
        height: height,
        titleStyle: _titleTextStyle,
        bodyStyle: bodyStyle,
        paragraphSpacing: _preferences.paragraphSpacing,
        firstLineIndent: _preferences.firstLineIndent,
        textDirection: Directionality.of(context),
        textScaler: _textScaler,
        maximumPages: maximumPages,
        paragraphBaseOffset: paragraphBaseOffset,
        includeChapterTitle: includeChapterTitle,
        paragraphTrailingWidth:
            widget.extensions.commentFeed != null &&
                _preferences.showParagraphComments
            ? _TextReaderViewState._inlineCommentHitSize
            : 0,
        paragraphTrailingHeight:
            widget.extensions.commentFeed != null &&
                _preferences.showParagraphComments
            ? _TextReaderViewState._inlineCommentHitSize
            : 0,
        chapterTrailingHeight:
            widget.extensions.commentFeed != null &&
                _preferences.showChapterComments
            ? 168
            : 0,
        stopAfterParagraphId: stopAtAnchor ? _progress?.paragraphId : null,
        stopAfterCharacterOffset: _progress?.characterOffset ?? 0,
      );
    } catch (error) {
      final ReaderFailure failure = _asFailure(error, ReaderFailureKind.layout);
      if (mounted) setState(() => _failure = failure);
      unawaited(_reportFailure(failure));
      return const <ReaderPage>[];
    }
  }

  void _paginateRemaining(
    Size size,
    ReaderLayoutFingerprint fingerprint,
    int generation,
  ) {
    if (!mounted ||
        generation != _paginationGeneration ||
        _layoutFingerprint != fingerprint) {
      return;
    }
    final TextChapterContent content = _content!;
    final int paragraphCount = content.paragraphs.length;
    final int start = _progressiveParagraphCursor;
    final int end =
        (start + _TextReaderViewState._progressiveParagraphBatchSize).clamp(
          0,
          paragraphCount,
        );
    if (start < end || paragraphCount == 0) {
      final bool hasParagraphComments =
          widget.extensions.commentFeed != null &&
          _preferences.showParagraphComments;
      final bool hasChapterComments =
          widget.extensions.commentFeed != null &&
          _preferences.showChapterComments;
      final ReaderPaginationBatch batch = _paginator.paginateBatch(
        chapter: TextChapterContent(
          chapterId: content.chapterId,
          title: content.title,
          paragraphs: content.paragraphs.sublist(start, end),
          contentVersion: content.contentVersion,
        ),
        width: _paginationWidth(size),
        height: _paginationHeight(size),
        titleStyle: _titleTextStyle,
        bodyStyle: _bodyTextStyle,
        paragraphSpacing: _preferences.paragraphSpacing,
        firstLineIndent: _preferences.firstLineIndent,
        textDirection: Directionality.of(context),
        textScaler: _textScaler,
        includeChapterTitle: start == 0,
        paragraphTrailingWidth: hasParagraphComments
            ? _TextReaderViewState._inlineCommentHitSize
            : 0,
        paragraphTrailingHeight: hasParagraphComments
            ? _TextReaderViewState._inlineCommentHitSize
            : 0,
        chapterTrailingHeight: hasChapterComments && end == paragraphCount
            ? 168
            : 0,
        continuation: _progressiveContinuation,
        finish: end == paragraphCount,
      );
      _progressivePages = List<ReaderPage>.unmodifiable(<ReaderPage>[
        ..._progressivePages,
        ...batch.pages,
      ]);
      _progressiveContinuation = batch.continuation;
      _progressiveParagraphCursor = paragraphCount == 0 ? 0 : end;
    }
    if (_progressiveParagraphCursor < paragraphCount) {
      WidgetsBinding.instance.scheduleFrameCallback((_) {
        if (mounted && generation == _paginationGeneration) {
          _paginateRemaining(size, fingerprint, generation);
        }
      });
      WidgetsBinding.instance.scheduleFrame();
      return;
    }
    final List<ReaderPage> pages = _progressivePages;
    if (generation != _paginationGeneration ||
        _layoutFingerprint != fingerprint) {
      return;
    }
    _TextReaderViewState._layoutCache.put(fingerprint, pages);
    _pages = pages;
    _currentPaginationComplete = true;
    _pageIndex = _pageIndexForAnchor(
      pages,
    ).clamp(0, pages.isEmpty ? 0 : pages.length - 1);
    _finishHorizontalPagination();
    _scheduleAdjacentPreparation();
    if (mounted) setState(() {});
    _publishSnapshot();
  }

  /// Moves the page view only after the completed layout has resolved the
  /// semantic end anchor. This prevents a previous-chapter turn from exposing
  /// that chapter's first page while its tail is still being calculated.
  void _finishHorizontalPagination() {
    _restoreHorizontalPageLater();
    if (!_awaitingPreviousChapterTail) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _completeChapterTransition(
          ReaderChapterPerformanceOutcome.success,
          pageCount: _pages.length,
          paragraphCount: _content?.paragraphs.length ?? 0,
        );
      });
      WidgetsBinding.instance.scheduleFrame();
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_awaitingPreviousChapterTail) return;
      setState(() => _awaitingPreviousChapterTail = false);
      _completeChapterTransition(
        ReaderChapterPerformanceOutcome.success,
        pageCount: _pages.length,
        paragraphCount: _content?.paragraphs.length ?? 0,
      );
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  void _restoreHorizontalPageLater() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_pageController.hasClients) return;
      _restoreHorizontalPageWithoutProgress(_pageIndex + 1);
      _publishSnapshot();
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  TextStyle get _bodyTextStyle => TextStyle(
    color: _palette.text,
    fontFamily: _activeRuntimeFontFamily ?? readerFontFamily(_preferences.font),
    fontFamilyFallback: readerFontFallback(_preferences.font),
    package: _activeRuntimeFontFamily == null
        ? readerFontPackageFor(_preferences.font)
        : null,
    fontSize: _preferences.fontSize,
    fontWeight: FontWeight(_preferences.fontWeight),
    height: _preferences.lineHeight,
    letterSpacing: _preferences.letterSpacing,
  );

  TextStyle get _titleTextStyle => TextStyle(
    color: _palette.text,
    fontFamily: _activeRuntimeFontFamily ?? readerFontFamily(_preferences.font),
    fontFamilyFallback: readerFontFallback(_preferences.font),
    package: _activeRuntimeFontFamily == null
        ? readerFontPackageFor(_preferences.font)
        : null,
    fontSize: _preferences.fontSize + 7,
    fontWeight: FontWeight.w700,
    height: 1.35,
  );

  String? get _activeRuntimeFontFamily =>
      _runtimeFontDescriptor?.id == _preferences.customFontId
      ? _runtimeFontFamily
      : null;

  Future<void> _nextPage({bool userInitiated = true}) async {
    if (_readerSettingsVisible && userInitiated) return;
    if (userInitiated) _stopAutoReading();
    if (_preferences.navigationMode == ReaderNavigationMode.verticalScroll) {
      if (_verticalController.hasClients) {
        await _verticalController.animateTo(
          (_verticalController.offset +
                  _verticalController.position.viewportDimension * 0.85)
              .clamp(0, _verticalController.position.maxScrollExtent),
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      }
      return;
    }
    if (_pageIndex + 1 < _pages.length) {
      await _animateToPage(_pageIndex + 1);
    } else {
      await _nextChapter();
    }
  }

  Future<void> _previousPage({bool userInitiated = true}) async {
    if (_readerSettingsVisible && userInitiated) return;
    if (userInitiated) _stopAutoReading();
    if (_preferences.navigationMode == ReaderNavigationMode.verticalScroll) {
      if (_verticalController.hasClients) {
        await _verticalController.animateTo(
          (_verticalController.offset -
                  _verticalController.position.viewportDimension * 0.85)
              .clamp(0, _verticalController.position.maxScrollExtent),
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      }
      return;
    }
    if (_pageIndex > 0) {
      await _animateToPage(_pageIndex - 1);
    } else {
      await _previousChapter();
    }
  }

  void _handleHorizontalTap(Offset localPosition) {
    if (_readerSettingsVisible) {
      _dismissReaderSettingsFromReader();
      return;
    }
    _stopAutoReading();
    final Size? size = context.size;
    if (size == null || size.width <= 0) return;
    final double fraction = localPosition.dx / size.width;
    if (_preferences.singleHandMode && (fraction < 0.3 || fraction > 0.7)) {
      _pageTurnForward = true;
      unawaited(_nextPage());
    } else if (fraction < 0.3) {
      _pageTurnForward = false;
      unawaited(_previousPage());
    } else if (fraction > 0.7) {
      _pageTurnForward = true;
      unawaited(_nextPage());
    } else {
      _setControlsVisible(!_controlsVisible);
    }
  }

  void _trackMousePointerDown(PointerDownEvent event) {
    if (_readerSettingsVisible) return;
    if (event.kind != PointerDeviceKind.mouse ||
        event.buttons != _TextReaderViewState._primaryMouseButton) {
      return;
    }
    _stopAutoReading();
    _mouseTapPointer = event.pointer;
    _mouseTapDownPosition = event.localPosition;
    _mouseTapMoved = false;
  }

  void _trackMousePointerMove(PointerMoveEvent event) {
    if (event.pointer != _mouseTapPointer || _mouseTapMoved) return;
    final Offset? downPosition = _mouseTapDownPosition;
    if (downPosition != null &&
        (event.localPosition - downPosition).distance >
            _TextReaderViewState._mouseTapSlop) {
      _mouseTapMoved = true;
    }
  }

  void _finishMousePointer(PointerEvent event) {
    if (event.pointer != _mouseTapPointer) return;
    final bool isTap = !_mouseTapMoved;
    final Offset? downPosition = _mouseTapDownPosition;
    _mouseTapPointer = null;
    _mouseTapDownPosition = null;
    _mouseTapMoved = false;
    if (_readerSettingsVisible) return;
    if (isTap && event is PointerUpEvent) {
      _handleHorizontalTap(event.localPosition);
    } else if (_usesDirectPageTurns &&
        event is PointerUpEvent &&
        downPosition != null) {
      final double delta = event.localPosition.dx - downPosition.dx;
      if (delta.abs() >= 36) {
        unawaited(delta < 0 ? _nextPage() : _previousPage());
      }
    }
  }

  Future<void> _animateToPage(int page) async {
    if (!_pageController.hasClients || _pageTurnAnimating) return;
    _pageTurnAnimating = true;
    _pageTurnForward = page > _pageIndex;
    try {
      if (_preferences.pageAnimation == ReaderPageAnimation.none ||
          MediaQuery.disableAnimationsOf(context)) {
        _pageController.jumpToPage(page + 1);
      } else {
        await _pageController.animateToPage(
          page + 1,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
        );
      }
    } finally {
      _pageTurnAnimating = false;
    }
  }

  Future<void> _nextChapter() async {
    _stopAutoReading();
    await _nextChapterInternal();
  }

  Future<bool> _nextChapterInternal() async {
    _completeChapterTransition(ReaderChapterPerformanceOutcome.cancelled);
    final int navigation = ++_navigationGeneration;
    final int nextIndex = _chapterIndex + 1;
    final int total = _catalogTotal > 0 ? _catalogTotal : _catalog.length;
    if (nextIndex >= total) {
      _restoreCurrentHorizontalPage();
      _showNotice(ReaderStrings.noNextChapter);
      return false;
    }
    final int operationId = ++_chapterTransitionOperationId;
    final Stopwatch transitionStopwatch = Stopwatch()..start();
    _pendingChapterTransitionOperation = operationId;
    _chapterTransitionStopwatch = transitionStopwatch;
    _notifyChapterPerformance(
      ReaderChapterPerformanceEvent.started(
        phase: ReaderChapterPerformancePhase.chapterTransition,
        operationId: operationId,
        preparationKind: ReaderChapterPreparationKind.pending,
      ),
    );
    try {
      final ReaderChapterInfo next = await _chapterInfoAtIndex(nextIndex);
      if (navigation != _navigationGeneration) {
        _completeChapterTransition(
          ReaderChapterPerformanceOutcome.cancelled,
          expectedOperationId: operationId,
        );
        return false;
      }
      await _openChapter(next.id, preserveAutoReading: true);
      final bool success = _content?.chapterId == next.id && _failure == null;
      if (!success) {
        _completeChapterTransition(
          ReaderChapterPerformanceOutcome.error,
          expectedOperationId: operationId,
        );
      }
      return success;
    } catch (error) {
      if (navigation != _navigationGeneration) {
        _completeChapterTransition(
          ReaderChapterPerformanceOutcome.cancelled,
          expectedOperationId: operationId,
        );
        return false;
      }
      _restoreCurrentHorizontalPage();
      await _reportFailure(_asFailure(error, ReaderFailureKind.data));
      _completeChapterTransition(
        ReaderChapterPerformanceOutcome.error,
        expectedOperationId: operationId,
      );
      return false;
    }
  }

  Future<void> _previousChapter() async {
    _stopAutoReading();
    _completeChapterTransition(ReaderChapterPerformanceOutcome.cancelled);
    final int navigation = ++_navigationGeneration;
    if (_chapterIndex < 0) {
      _showNotice(ReaderStrings.noPreviousChapter);
      return;
    }
    final int operationId = ++_chapterTransitionOperationId;
    final Stopwatch transitionStopwatch = Stopwatch()..start();
    _pendingChapterTransitionOperation = operationId;
    _chapterTransitionStopwatch = transitionStopwatch;
    _notifyChapterPerformance(
      ReaderChapterPerformanceEvent.started(
        phase: ReaderChapterPerformancePhase.chapterTransition,
        operationId: operationId,
        preparationKind: ReaderChapterPreparationKind.pending,
      ),
    );
    if (_chapterIndex == 0) {
      _showNotice(ReaderStrings.noPreviousChapter);
      _completeChapterTransition(
        ReaderChapterPerformanceOutcome.cancelled,
        expectedOperationId: operationId,
      );
      return;
    }
    try {
      final ReaderChapterInfo previous = await _chapterInfoAtIndex(
        _chapterIndex - 1,
      );
      if (navigation != _navigationGeneration) {
        _completeChapterTransition(
          ReaderChapterPerformanceOutcome.cancelled,
          expectedOperationId: operationId,
        );
        return;
      }
      await _openChapter(previous.id, openAtEnd: true);
      if (_content?.chapterId != previous.id || _failure != null) {
        _completeChapterTransition(
          ReaderChapterPerformanceOutcome.error,
          expectedOperationId: operationId,
        );
      }
    } catch (error) {
      if (navigation != _navigationGeneration) {
        _completeChapterTransition(
          ReaderChapterPerformanceOutcome.cancelled,
          expectedOperationId: operationId,
        );
        return;
      }
      _restoreCurrentHorizontalPage();
      await _reportFailure(_asFailure(error, ReaderFailureKind.data));
      _completeChapterTransition(
        ReaderChapterPerformanceOutcome.error,
        expectedOperationId: operationId,
      );
    }
  }

  Future<void> _showBookPreview() async {
    _stopAutoReading();
    final int navigation = ++_navigationGeneration;
    final int generation = ++_requestGeneration;
    final int session = _sessionGeneration;
    _saveTimer?.cancel();
    await _flushProgress();
    if (!_isCurrent(generation) ||
        session != _sessionGeneration ||
        navigation != _navigationGeneration) {
      return;
    }
    _content = null;
    _chapterCache.clear();
    _currentChapterInfo = null;
    _chapterIndex = -1;
    _pageIndex = 0;
    _pages = const <ReaderPage>[];
    _awaitingPreviousChapterTail = false;
    _paragraphKeys.clear();
    _progress = const ReaderProgress.bookPreview();
    _changingChapter = false;
    _failure = null;
    if (mounted) setState(() {});
    await _releaseAwake();
    _scheduleProgressSave(immediate: true);
    _publishSnapshot();
  }

  void _restoreCurrentHorizontalPage() {
    if (_preferences.navigationMode != ReaderNavigationMode.horizontalPages) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_pageController.hasClients) return;
      _restoreHorizontalPageWithoutProgress(_pageIndex + 1);
    });
  }

  void _restoreHorizontalPageWithoutProgress(int rawIndex) {
    _restoringHorizontalAnchor = true;
    _pageController.jumpToPage(rawIndex);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _restoringHorizontalAnchor = false;
    });
  }
}
