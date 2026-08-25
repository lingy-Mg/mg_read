part of 'text_reader_view.dart';

// ignore_for_file: invalid_use_of_protected_member

/// 空闲时为横向阅读器准备相邻下一章的完整分页。
///
/// 只使用现有 TextPainter 排版器和 layout LRU；每次 idle task 最多处理
/// 当前策略的 8 个段落，并以会话、内容和布局世代丢弃过期结果。
extension _TextReaderAdjacentPagination on _TextReaderViewState {
  void _completeChapterTransition(
    ReaderChapterPerformanceOutcome outcome, {
    int pageCount = 0,
    int paragraphCount = 0,
    int? expectedOperationId,
  }) {
    final int? operationId = _pendingChapterTransitionOperation;
    if (operationId == null ||
        (expectedOperationId != null && operationId != expectedOperationId)) {
      return;
    }
    final Stopwatch? stopwatch = _chapterTransitionStopwatch;
    _pendingChapterTransitionOperation = null;
    _chapterTransitionStopwatch = null;
    final Duration duration = stopwatch?.elapsed ?? Duration.zero;
    final bool cacheHit =
        outcome == ReaderChapterPerformanceOutcome.success &&
        _firstContentPreparation == ReaderPaginationPreparation.cachedFirstPage;
    final ReaderChapterPreparationKind preparationKind = cacheHit
        ? ReaderChapterPreparationKind.cachedLayout
        : ReaderChapterPreparationKind.foregroundLayout;
    final ReaderChapterPerformanceEvent event = switch (outcome) {
      ReaderChapterPerformanceOutcome.success =>
        ReaderChapterPerformanceEvent.success(
          phase: ReaderChapterPerformancePhase.chapterTransition,
          operationId: operationId,
          duration: duration,
          pageCount: pageCount,
          paragraphCount: paragraphCount,
          preparationKind: preparationKind,
          cacheHit: cacheHit,
        ),
      ReaderChapterPerformanceOutcome.error =>
        ReaderChapterPerformanceEvent.error(
          phase: ReaderChapterPerformancePhase.chapterTransition,
          operationId: operationId,
          duration: duration,
          preparationKind: preparationKind,
        ),
      ReaderChapterPerformanceOutcome.cancelled =>
        ReaderChapterPerformanceEvent.cancelled(
          phase: ReaderChapterPerformancePhase.chapterTransition,
          operationId: operationId,
          duration: duration,
          preparationKind: preparationKind,
        ),
      ReaderChapterPerformanceOutcome.started => throw StateError(
        'A transition cannot finish as started.',
      ),
    };
    _notifyChapterPerformance(event);
  }

  void _cancelAdjacentPreparation() {
    final bool wasActive = _adjacentPreparationActive;
    _adjacentPreparationGeneration++;
    _adjacentPreparationActive = false;
    final Stopwatch? stopwatch = _adjacentPreparationStopwatch;
    _adjacentPreparationStopwatch = null;
    if (wasActive) {
      _notifyChapterPerformance(
        ReaderChapterPerformanceEvent.cancelled(
          phase: ReaderChapterPerformancePhase.adjacentPreparation,
          operationId: _adjacentActiveOperation,
          duration: stopwatch?.elapsed ?? Duration.zero,
          preparationKind: ReaderChapterPreparationKind.adjacentIdle,
        ),
      );
    }
  }

  void _scheduleAdjacentPreparation() {
    if (_disposed ||
        !_foreground ||
        !_currentPaginationComplete ||
        _content == null ||
        _layoutFingerprint == null ||
        _pages.isEmpty ||
        _preferences.navigationMode != ReaderNavigationMode.horizontalPages) {
      return;
    }
    final int nextIndex = _chapterIndex + 1;
    if (_catalogTotal > 0 && nextIndex >= _catalogTotal) return;
    final ReaderChapterInfo? next = _catalogByIndex[nextIndex];
    if (next == null || _chapterCache[next.id] == null) return;
    if (_adjacentPreparationActive) return;
    final TextChapterContent content = _chapterCache[next.id]!;
    if (!_fitsAdjacentLayoutBudget(content)) return;
    final Size? size = context.size;
    if (size == null || size.isEmpty) return;
    final ReaderLayoutFingerprint fingerprint = _layoutFingerprintForContent(
      size,
      content,
    );
    if (_TextReaderViewState._layoutCache.contains(fingerprint)) return;
    final int generation = ++_adjacentPreparationGeneration;
    final int operationId = ++_adjacentOperationId;
    final Stopwatch preparationStopwatch = Stopwatch()..start();
    _adjacentPreparationStopwatch = preparationStopwatch;
    final int session = _sessionGeneration;
    final int contentEpoch = _contentEpoch;
    _adjacentPreparationActive = true;
    _adjacentActiveOperation = operationId;
    _notifyChapterPerformance(
      ReaderChapterPerformanceEvent.started(
        phase: ReaderChapterPerformancePhase.adjacentPreparation,
        operationId: operationId,
        paragraphCount: content.paragraphs.length,
        preparationKind: ReaderChapterPreparationKind.adjacentIdle,
      ),
    );
    final List<ReaderPage> pages = <ReaderPage>[];
    ReaderPageContinuation? continuation;
    var cursor = 0;
    void runBatch() {
      if (!_isAdjacentPreparationCurrent(
        generation,
        session,
        contentEpoch,
        fingerprint,
        next.id,
      )) {
        if (_adjacentPreparationActive &&
            _adjacentActiveOperation == operationId) {
          _adjacentPreparationActive = false;
          _adjacentPreparationStopwatch = null;
          _notifyChapterPerformance(
            ReaderChapterPerformanceEvent.cancelled(
              phase: ReaderChapterPerformancePhase.adjacentPreparation,
              operationId: operationId,
              duration: preparationStopwatch.elapsed,
              preparationKind: ReaderChapterPreparationKind.adjacentIdle,
            ),
          );
        }
        return;
      }
      final int end =
          (cursor + _TextReaderViewState._progressiveParagraphBatchSize).clamp(
            0,
            content.paragraphs.length,
          );
      try {
        final ReaderPaginationBatch batch = _paginator.paginateBatch(
          chapter: TextChapterContent(
            chapterId: content.chapterId,
            title: content.title,
            paragraphs: content.paragraphs.sublist(cursor, end),
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
          includeChapterTitle: cursor == 0,
          paragraphTrailingWidth: _hasParagraphComments
              ? _TextReaderViewState._inlineCommentHitSize
              : 0,
          paragraphTrailingHeight: _hasParagraphComments
              ? _TextReaderViewState._inlineCommentHitSize
              : 0,
          chapterTrailingHeight:
              _hasChapterComments && end == content.paragraphs.length ? 168 : 0,
          continuation: continuation,
          finish: end == content.paragraphs.length,
        );
        pages.addAll(batch.pages);
        continuation = batch.continuation;
        cursor = end;
        if (cursor < content.paragraphs.length) {
          WidgetsBinding.instance.scheduleTask<void>(runBatch, Priority.idle);
          return;
        }
        if (!_isAdjacentPreparationCurrent(
          generation,
          session,
          contentEpoch,
          fingerprint,
          next.id,
        )) {
          if (_adjacentPreparationActive &&
              _adjacentActiveOperation == operationId) {
            _adjacentPreparationActive = false;
            _adjacentPreparationStopwatch = null;
            _notifyChapterPerformance(
              ReaderChapterPerformanceEvent.cancelled(
                phase: ReaderChapterPerformancePhase.adjacentPreparation,
                operationId: operationId,
                duration: preparationStopwatch.elapsed,
                preparationKind: ReaderChapterPreparationKind.adjacentIdle,
              ),
            );
          }
          return;
        }
        if (!_TextReaderViewState._layoutCache.canStore(pages)) {
          _adjacentPreparationActive = false;
          _adjacentPreparationStopwatch = null;
          _notifyChapterPerformance(
            ReaderChapterPerformanceEvent.error(
              phase: ReaderChapterPerformancePhase.adjacentPreparation,
              operationId: operationId,
              duration: preparationStopwatch.elapsed,
              paragraphCount: content.paragraphs.length,
              preparationKind: ReaderChapterPreparationKind.adjacentIdle,
            ),
          );
          return;
        }
        _TextReaderViewState._layoutCache.put(fingerprint, pages);
        _adjacentPreparationActive = false;
        _adjacentPreparationStopwatch = null;
        _notifyChapterPerformance(
          ReaderChapterPerformanceEvent.success(
            phase: ReaderChapterPerformancePhase.adjacentPreparation,
            operationId: operationId,
            duration: preparationStopwatch.elapsed,
            pageCount: pages.length,
            paragraphCount: content.paragraphs.length,
            preparationKind: ReaderChapterPreparationKind.adjacentIdle,
          ),
        );
      } catch (_) {
        _adjacentPreparationActive = false;
        _adjacentPreparationStopwatch = null;
        _notifyChapterPerformance(
          ReaderChapterPerformanceEvent.error(
            phase: ReaderChapterPerformancePhase.adjacentPreparation,
            operationId: operationId,
            duration: preparationStopwatch.elapsed,
            paragraphCount: content.paragraphs.length,
            preparationKind: ReaderChapterPreparationKind.adjacentIdle,
          ),
        );
      }
    }

    WidgetsBinding.instance.scheduleTask<void>(runBatch, Priority.idle);
  }

  bool _isAdjacentPreparationCurrent(
    int generation,
    int session,
    int contentEpoch,
    ReaderLayoutFingerprint fingerprint,
    String chapterId,
  ) =>
      !_disposed &&
      _foreground &&
      generation == _adjacentPreparationGeneration &&
      session == _sessionGeneration &&
      contentEpoch == _contentEpoch &&
      _currentChapterInfo?.index == _chapterIndex &&
      _preferences.navigationMode == ReaderNavigationMode.horizontalPages &&
      _chapterCache[chapterId] != null &&
      _layoutFingerprintForContent(
            context.size ?? Size.zero,
            _chapterCache[chapterId]!,
          ) ==
          fingerprint;

  bool _fitsAdjacentLayoutBudget(TextChapterContent content) {
    var characters = 0;
    for (final paragraph in content.paragraphs) {
      characters += paragraph.text.length;
      if (characters > _TextReaderViewState._layoutCache.maxCharacters) {
        return false;
      }
    }
    return true;
  }

  ReaderLayoutFingerprint _layoutFingerprintForContent(
    Size size,
    TextChapterContent content,
  ) {
    final ReaderLayoutFingerprint current = _layoutFingerprintFor(size);
    return ReaderLayoutFingerprint(
      chapterId: content.chapterId,
      contentVersion: content.contentVersion,
      sessionId: content.contentVersion == null
          ? _contentLayoutIdentity(content)
          : 0,
      viewport: current.viewport,
      safeArea: current.safeArea,
      devicePixelRatio: current.devicePixelRatio,
      textScale: current.textScale,
      fontVersion: current.fontVersion,
      layoutSettings: current.layoutSettings,
      textDirection: current.textDirection,
      fontSize: current.fontSize,
      fontWeight: current.fontWeight,
      letterSpacing: current.letterSpacing,
      lineHeight: current.lineHeight,
      paragraphSpacing: current.paragraphSpacing,
      firstLineIndent: current.firstLineIndent,
      horizontalPadding: current.horizontalPadding,
      topPadding: current.topPadding,
      bottomPadding: current.bottomPadding,
      paragraphCommentPlaceholder: current.paragraphCommentPlaceholder,
      chapterCommentPlaceholder: current.chapterCommentPlaceholder,
    );
  }

  bool get _hasParagraphComments =>
      widget.extensions.commentFeed != null &&
      _preferences.showParagraphComments;

  bool get _hasChapterComments =>
      widget.extensions.commentFeed != null && _preferences.showChapterComments;

  void _notifyChapterPerformance(ReaderChapterPerformanceEvent event) {
    unawaited(_notify(() => _observer.onChapterPerformance(event)));
  }
}
