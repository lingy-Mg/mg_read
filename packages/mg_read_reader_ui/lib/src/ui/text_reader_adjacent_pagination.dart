part of 'text_reader_view.dart';

// ignore_for_file: invalid_use_of_protected_member

/// 相邻章节准备的内部阶段。内容和布局共享同一个目标，取消后回到
/// [pending]，只能由下一次真实阅读事件重新推进。
enum _AdjacentPreparationStage {
  pending,
  contentLoading,
  contentReady,
  layoutLoading,
  ready,
}

final class _AdjacentPreparationTarget {
  const _AdjacentPreparationTarget({
    required this.sessionGeneration,
    required this.chapterIndex,
    required this.nextChapterId,
    required this.layoutFingerprint,
    required this.layoutGeneration,
    required this.contentEpoch,
  });

  final int sessionGeneration;
  final int chapterIndex;
  final String nextChapterId;
  final ReaderLayoutFingerprint layoutFingerprint;
  final int layoutGeneration;
  final int contentEpoch;

  bool matches({
    required int session,
    required int index,
    required String chapterId,
    required ReaderLayoutFingerprint fingerprint,
    required int layoutGeneration,
    required int contentEpoch,
  }) =>
      sessionGeneration == session &&
      chapterIndex == index &&
      nextChapterId == chapterId &&
      layoutFingerprint == fingerprint &&
      this.layoutGeneration == layoutGeneration &&
      this.contentEpoch == contentEpoch;
}

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
    _adjacentPreparationGeneration++;
    _adjacentLayoutGeneration++;
    _completeAdjacentPreparation(ReaderChapterPerformanceOutcome.cancelled);
    _adjacentPreparationStage = _AdjacentPreparationStage.pending;
    _adjacentPreparationTarget = null;
    _adjacentSuppressedTarget = null;
  }

  void _completeAdjacentPreparation(
    ReaderChapterPerformanceOutcome outcome, {
    int pageCount = 0,
    int paragraphCount = 0,
  }) {
    if (!_adjacentPreparationActive) return;
    final int operationId = _adjacentActiveOperation;
    final Stopwatch? stopwatch = _adjacentPreparationStopwatch;
    _adjacentPreparationActive = false;
    _adjacentPreparationStopwatch = null;
    _adjacentPreparationStage =
        outcome == ReaderChapterPerformanceOutcome.success
        ? _AdjacentPreparationStage.ready
        : _AdjacentPreparationStage.pending;
    final Duration duration = stopwatch?.elapsed ?? Duration.zero;
    final ReaderChapterPerformanceEvent event = switch (outcome) {
      ReaderChapterPerformanceOutcome.success =>
        ReaderChapterPerformanceEvent.success(
          phase: ReaderChapterPerformancePhase.adjacentPreparation,
          operationId: operationId,
          duration: duration,
          pageCount: pageCount,
          paragraphCount: paragraphCount,
          preparationKind: ReaderChapterPreparationKind.adjacentIdle,
        ),
      ReaderChapterPerformanceOutcome.error =>
        ReaderChapterPerformanceEvent.error(
          phase: ReaderChapterPerformancePhase.adjacentPreparation,
          operationId: operationId,
          duration: duration,
          paragraphCount: paragraphCount,
          preparationKind: ReaderChapterPreparationKind.adjacentIdle,
        ),
      ReaderChapterPerformanceOutcome.cancelled =>
        ReaderChapterPerformanceEvent.cancelled(
          phase: ReaderChapterPerformancePhase.adjacentPreparation,
          operationId: operationId,
          duration: duration,
          preparationKind: ReaderChapterPreparationKind.adjacentIdle,
        ),
      ReaderChapterPerformanceOutcome.started => throw StateError(
        'Adjacent preparation cannot finish as started.',
      ),
    };
    _notifyChapterPerformance(event);
  }

  /// Reconciles content and layout preparation from one target state machine.
  /// The method is intentionally called only by real reader events or by the
  /// completion of one of its two operations; failures never call it again.
  void _reconcileAdjacentPreparation() {
    if (_disposed ||
        !_foreground ||
        !_currentPaginationComplete ||
        _content == null ||
        _layoutFingerprint == null ||
        _pages.isEmpty ||
        _preferences.navigationMode != ReaderNavigationMode.horizontalPages) {
      _adjacentPreparationTarget = null;
      _adjacentPreparationStage = _AdjacentPreparationStage.pending;
      return;
    }
    final int nextIndex = _chapterIndex + 1;
    if (_catalogTotal > 0 && nextIndex >= _catalogTotal) {
      _adjacentPreparationTarget = null;
      _adjacentPreparationStage = _AdjacentPreparationStage.pending;
      return;
    }
    final Size? size = context.size;
    if (size == null || size.isEmpty) return;
    final ReaderChapterInfo? next = _catalogByIndex[nextIndex];
    if (next == null) {
      final _AdjacentPreparationTarget metadataTarget =
          _AdjacentPreparationTarget(
            sessionGeneration: _sessionGeneration,
            chapterIndex: _chapterIndex,
            nextChapterId: '',
            layoutFingerprint: _layoutFingerprintForContent(size, _content!),
            layoutGeneration: _adjacentLayoutGeneration,
            contentEpoch: _contentEpoch,
          );
      if (_adjacentPreparationTarget == null ||
          !_adjacentPreparationTarget!.matches(
            session: metadataTarget.sessionGeneration,
            index: metadataTarget.chapterIndex,
            chapterId: '',
            fingerprint: metadataTarget.layoutFingerprint,
            layoutGeneration: metadataTarget.layoutGeneration,
            contentEpoch: metadataTarget.contentEpoch,
          )) {
        _completeAdjacentPreparation(ReaderChapterPerformanceOutcome.cancelled);
        _adjacentPreparationTarget = metadataTarget;
        _adjacentPreparationStage = _AdjacentPreparationStage.contentLoading;
        unawaited(_loadAdjacentContent(metadataTarget));
      }
      return;
    }
    final TextChapterContent? content = _chapterCache[next.id];
    if (content != null && !_fitsAdjacentLayoutBudget(content)) {
      _adjacentPreparationTarget = null;
      _adjacentPreparationStage = _AdjacentPreparationStage.pending;
      return;
    }
    final ReaderLayoutFingerprint fingerprint = _layoutFingerprintForContent(
      size,
      content ?? _content!,
    );
    final _AdjacentPreparationTarget target = _AdjacentPreparationTarget(
      sessionGeneration: _sessionGeneration,
      chapterIndex: _chapterIndex,
      nextChapterId: next.id,
      layoutFingerprint: fingerprint,
      layoutGeneration: _adjacentLayoutGeneration,
      contentEpoch: _contentEpoch,
    );
    if (_adjacentPreparationTarget == null ||
        !_adjacentPreparationTarget!.matches(
          session: target.sessionGeneration,
          index: target.chapterIndex,
          chapterId: target.nextChapterId,
          fingerprint: target.layoutFingerprint,
          layoutGeneration: target.layoutGeneration,
          contentEpoch: _contentEpoch,
        )) {
      _completeAdjacentPreparation(ReaderChapterPerformanceOutcome.cancelled);
      _adjacentPreparationTarget = target;
      _adjacentPreparationStage = _AdjacentPreparationStage.pending;
    }
    if (_adjacentSuppressedTarget != null &&
        !_adjacentSuppressedTarget!.matches(
          session: target.sessionGeneration,
          index: target.chapterIndex,
          chapterId: target.nextChapterId,
          fingerprint: target.layoutFingerprint,
          layoutGeneration: target.layoutGeneration,
          contentEpoch: target.contentEpoch,
        )) {
      _adjacentSuppressedTarget = null;
    }
    if (content == null) {
      if (_adjacentPreparationStage ==
          _AdjacentPreparationStage.contentLoading) {
        return;
      }
      _adjacentPreparationStage = _AdjacentPreparationStage.contentLoading;
      unawaited(_loadAdjacentContent(target));
      return;
    }
    // Content may have arrived while the target was pending after an earlier
    // failure. Rebind its exact content-version fingerprint before layout.
    if (_adjacentPreparationTarget!.layoutFingerprint != fingerprint) {
      _adjacentPreparationTarget = target;
      _adjacentPreparationStage = _AdjacentPreparationStage.pending;
    }
    if (_TextReaderViewState._layoutCache.contains(fingerprint)) {
      _adjacentPreparationStage = _AdjacentPreparationStage.ready;
      return;
    }
    if (_adjacentSuppressedTarget?.matches(
          session: target.sessionGeneration,
          index: target.chapterIndex,
          chapterId: target.nextChapterId,
          fingerprint: target.layoutFingerprint,
          layoutGeneration: target.layoutGeneration,
          contentEpoch: target.contentEpoch,
        ) ==
        true) {
      return;
    }
    if (_adjacentPreparationStage == _AdjacentPreparationStage.layoutLoading ||
        _adjacentPreparationActive ||
        _adjacentPreparationStage == _AdjacentPreparationStage.ready) {
      return;
    }
    _adjacentPreparationStage = _AdjacentPreparationStage.contentReady;
    final int generation = ++_adjacentPreparationGeneration;
    final int operationId = ++_adjacentOperationId;
    final Stopwatch preparationStopwatch = Stopwatch()..start();
    _adjacentPreparationStopwatch = preparationStopwatch;
    final int session = _sessionGeneration;
    final int contentEpoch = _contentEpoch;
    _adjacentPreparationActive = true;
    _adjacentActiveOperation = operationId;
    _adjacentPreparationStage = _AdjacentPreparationStage.layoutLoading;
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
          _completeAdjacentPreparation(
            ReaderChapterPerformanceOutcome.cancelled,
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
            _completeAdjacentPreparation(
              ReaderChapterPerformanceOutcome.cancelled,
            );
          }
          return;
        }
        if (!_TextReaderViewState._layoutCache.canStore(pages)) {
          _adjacentSuppressedTarget = _adjacentPreparationTarget;
          _completeAdjacentPreparation(
            ReaderChapterPerformanceOutcome.error,
            paragraphCount: content.paragraphs.length,
          );
          return;
        }
        _TextReaderViewState._layoutCache.put(fingerprint, pages);
        _completeAdjacentPreparation(
          ReaderChapterPerformanceOutcome.success,
          pageCount: pages.length,
          paragraphCount: content.paragraphs.length,
        );
      } catch (_) {
        _completeAdjacentPreparation(
          ReaderChapterPerformanceOutcome.error,
          paragraphCount: content.paragraphs.length,
        );
      }
    }

    WidgetsBinding.instance.scheduleTask<void>(runBatch, Priority.idle);
  }

  Future<void> _loadAdjacentContent(_AdjacentPreparationTarget target) async {
    ReaderChapterInfo? next = _catalogByIndex[target.chapterIndex + 1];
    final int session = target.sessionGeneration;
    final TextReaderDataSource dataSource = widget.dataSource;
    final String bookId = widget.bookId;
    String? resolvedChapterId;
    try {
      next ??= await _chapterInfoAtIndex(target.chapterIndex + 1);
      if (!mounted || _disposed) return;
      resolvedChapterId = next.id;
      if (target.nextChapterId.isNotEmpty && next.id != target.nextChapterId) {
        return;
      }
      if (_adjacentPreparationTarget?.nextChapterId != target.nextChapterId) {
        return;
      }
      if (target.nextChapterId.isEmpty) {
        final Size? size = context.size;
        if (size == null || size.isEmpty) return;
        final ReaderLayoutFingerprint metadataFingerprint =
            _layoutFingerprintForContent(size, _content!);
        _adjacentPreparationTarget = _AdjacentPreparationTarget(
          sessionGeneration: session,
          chapterIndex: target.chapterIndex,
          nextChapterId: next.id,
          layoutFingerprint: metadataFingerprint,
          layoutGeneration: _adjacentLayoutGeneration,
          contentEpoch: _contentEpoch,
        );
      }
      final TextChapterContent content = await _loadChapterContent(
        dataSource,
        bookId,
        next.id,
      );
      if (!_isSessionCurrent(session) ||
          !identical(dataSource, widget.dataSource) ||
          bookId != widget.bookId ||
          _chapterIndex != target.chapterIndex ||
          _adjacentPreparationTarget?.nextChapterId != next.id) {
        return;
      }
      if (content.chapterId != next.id) {
        _adjacentPreparationStage = _AdjacentPreparationStage.pending;
        return;
      }
      _validateChapter(content, expectedChapterId: next.id);
      _cacheChapter(content);
      if (!mounted || _disposed) return;
      final Size? size = context.size;
      if (size == null || size.isEmpty) return;
      final ReaderLayoutFingerprint fingerprint = _layoutFingerprintForContent(
        size,
        content,
      );
      final _AdjacentPreparationTarget exactTarget = _AdjacentPreparationTarget(
        sessionGeneration: session,
        chapterIndex: target.chapterIndex,
        nextChapterId: next.id,
        layoutFingerprint: fingerprint,
        layoutGeneration: _adjacentLayoutGeneration,
        contentEpoch: _contentEpoch,
      );
      _adjacentPreparationTarget = exactTarget;
      _adjacentPreparationStage = _AdjacentPreparationStage.contentReady;
      // The content arrival is itself a real trigger. A failed layout can be
      // retried only by a later reader event because this call is not recursive.
      _reconcileAdjacentPreparation();
    } catch (_) {
      if (_adjacentPreparationTarget?.nextChapterId ==
              (resolvedChapterId ?? target.nextChapterId) &&
          _adjacentPreparationStage ==
              _AdjacentPreparationStage.contentLoading) {
        _adjacentPreparationStage = _AdjacentPreparationStage.pending;
      }
    }
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
      _adjacentPreparationTarget?.matches(
            session: session,
            index: _chapterIndex,
            chapterId: chapterId,
            fingerprint: fingerprint,
            layoutGeneration: _adjacentLayoutGeneration,
            contentEpoch: _contentEpoch,
          ) ==
          true &&
      _preferences.navigationMode == ReaderNavigationMode.horizontalPages &&
      _chapterCache[chapterId] != null &&
      _layoutFingerprintForContent(
            context.size ?? Size.zero,
            _chapterCache[chapterId]!,
          ) ==
          fingerprint &&
      _adjacentPreparationTarget?.layoutGeneration == _adjacentLayoutGeneration;

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
