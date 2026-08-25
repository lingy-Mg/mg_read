part of 'text_reader_view.dart';

// ignore_for_file: invalid_use_of_protected_member

extension _TextReaderComments on _TextReaderViewState {
  void _handleVerticalScroll() {
    if (_restoringVerticalAnchor ||
        !_verticalController.hasClients ||
        _content == null) {
      return;
    }
    final double fraction = _verticalController.position.maxScrollExtent == 0
        ? 0
        : (_verticalController.offset /
                  _verticalController.position.maxScrollExtent)
              .clamp(0, 1);
    String paragraphId = _content!.paragraphs.firstOrNull?.id ?? '';
    var closestBottom = double.infinity;
    for (final MapEntry<String, GlobalKey> entry in _paragraphKeys.entries) {
      final BuildContext? itemContext = entry.value.currentContext;
      if (itemContext == null) continue;
      final RenderBox? box = itemContext.findRenderObject() as RenderBox?;
      if (box != null) {
        final double bottom =
            box.localToGlobal(Offset.zero).dy + box.size.height;
        if (bottom > 0 && bottom < closestBottom) {
          closestBottom = bottom;
          paragraphId = entry.key;
        }
      }
    }
    _progress = _progressForAnchor(paragraphId, 0, chapterFraction: fraction);
    _scheduleProgressSave();
    _publishSnapshot();
  }

  void _scheduleVerticalRestore({String? paragraphId}) {
    final int generation = ++_verticalRestoreGeneration;
    final String? id = paragraphId ?? _progress?.paragraphId;
    if (id == null || id.isEmpty) return;
    _restoringVerticalAnchor = true;
    void restore() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || generation != _verticalRestoreGeneration) return;
        if (_preferences.navigationMode !=
            ReaderNavigationMode.verticalScroll) {
          _restoringVerticalAnchor = false;
          return;
        }
        final BuildContext? target = _paragraphKeys[id]?.currentContext;
        if (target != null) {
          unawaited(
            Scrollable.ensureVisible(target, alignment: 0.05).whenComplete(() {
              if (mounted && generation == _verticalRestoreGeneration) {
                _restoringVerticalAnchor = false;
              }
            }),
          );
          return;
        }
        final TextChapterContent? content = _content;
        if (!_verticalController.hasClients ||
            content == null ||
            _verticalItemExtents.isEmpty) {
          restore();
          return;
        }
        final int index = content.paragraphs.indexWhere(
          (TextParagraph paragraph) => paragraph.id == id,
        );
        if (index < 0 || content.paragraphs.isEmpty) {
          _restoringVerticalAnchor = false;
          return;
        }
        _measureVerticalPrefixAndRestore(
          paragraphIndex: index,
          paragraphId: id,
          generation: generation,
        );
      });
    }

    restore();
  }

  void _measureVerticalPrefixAndRestore({
    required int paragraphIndex,
    required String paragraphId,
    required int generation,
    int nextItem = 0,
    double offset = 0,
  }) {
    if (!mounted || generation != _verticalRestoreGeneration) return;
    final int targetItem = paragraphIndex + 1;
    final int end =
        (nextItem + _TextReaderViewState._verticalRestoreMeasureBatchSize)
            .clamp(0, targetItem);
    var resolvedOffset = offset;
    for (var item = nextItem; item < end; item++) {
      resolvedOffset += _verticalItemExtent(item);
    }
    if (end < targetItem) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _measureVerticalPrefixAndRestore(
          paragraphIndex: paragraphIndex,
          paragraphId: paragraphId,
          generation: generation,
          nextItem: end,
          offset: resolvedOffset,
        );
      });
      return;
    }
    final double desiredOffset =
        _preferences.topPadding +
        resolvedOffset -
        _verticalController.position.viewportDimension * 0.05;
    _verticalController.jumpTo(desiredOffset.clamp(0, double.infinity));
    _ensureVerticalRestoreTarget(
      paragraphId: paragraphId,
      generation: generation,
    );
  }

  void _ensureVerticalRestoreTarget({
    required String paragraphId,
    required int generation,
    int remainingAttempts = 3,
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _verticalRestoreGeneration) return;
      final BuildContext? target = _paragraphKeys[paragraphId]?.currentContext;
      if (target == null) {
        if (remainingAttempts > 0) {
          _ensureVerticalRestoreTarget(
            paragraphId: paragraphId,
            generation: generation,
            remainingAttempts: remainingAttempts - 1,
          );
          return;
        }
        _restoringVerticalAnchor = false;
        unawaited(
          _reportFailure(
            const ReaderFailure(
              ReaderFailureKind.layout,
              ReaderStrings.verticalAnchorRestoreFailed,
            ),
          ),
        );
        return;
      }
      unawaited(
        Scrollable.ensureVisible(target, alignment: 0.05).whenComplete(() {
          if (mounted && generation == _verticalRestoreGeneration) {
            _restoringVerticalAnchor = false;
          }
        }),
      );
    });
  }

  void _prepareVerticalItemExtents({
    required double width,
    required TextDirection textDirection,
    required int itemCount,
    required bool hasParagraphComments,
    required bool hasChapterComments,
  }) {
    if (identical(_verticalExtentContent, _content) &&
        _verticalExtentPreferences == _preferences &&
        _verticalExtentTextScaler == _textScaler &&
        _verticalExtentTextDirection == textDirection &&
        _verticalExtentWidth == width &&
        _verticalExtentHasParagraphComments == hasParagraphComments &&
        _verticalExtentHasChapterComments == hasChapterComments &&
        _verticalItemExtents.length == itemCount) {
      return;
    }
    _verticalExtentContent = _content;
    _verticalExtentPreferences = _preferences;
    _verticalExtentTextScaler = _textScaler;
    _verticalExtentTextDirection = textDirection;
    _verticalExtentWidth = width;
    _verticalExtentHasParagraphComments = hasParagraphComments;
    _verticalExtentHasChapterComments = hasChapterComments;
    _verticalItemExtents = List<double?>.filled(itemCount, null);
  }

  double _verticalItemExtent(int index) {
    final double? cached = _verticalItemExtents[index];
    if (cached != null) return cached;
    final TextChapterContent content = _verticalExtentContent!;
    late final double extent;
    if (index == 0) {
      extent = _measureVerticalText(content.title, _titleTextStyle) + 28;
    } else if (index <= content.paragraphs.length) {
      final String text = _indented(content.paragraphs[index - 1].text);
      extent =
          (_verticalExtentHasParagraphComments
              ? _measureVerticalTextWithTrailing(text, _bodyTextStyle)
              : _measureVerticalText(text, _bodyTextStyle)) +
          _preferences.paragraphSpacing;
    } else if (_verticalExtentHasChapterComments &&
        index == content.paragraphs.length + 1) {
      extent = 168;
    } else {
      extent = 96;
    }
    _verticalItemExtents[index] = extent;
    return extent;
  }

  double _measureVerticalText(String text, TextStyle style) {
    final TextPainter painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: _verticalExtentTextDirection,
      textScaler: _verticalExtentTextScaler ?? TextScaler.noScaling,
    )..layout(maxWidth: _verticalExtentWidth);
    return painter.height;
  }

  double _measureVerticalTextWithTrailing(String text, TextStyle style) {
    final TextPainter painter =
        TextPainter(
          text: TextSpan(
            style: style,
            children: <InlineSpan>[
              TextSpan(text: text),
              const WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: SizedBox.square(
                  dimension: _TextReaderViewState._inlineCommentHitSize,
                ),
              ),
            ],
          ),
          textDirection: _verticalExtentTextDirection,
          textScaler: _verticalExtentTextScaler ?? TextScaler.noScaling,
        )..setPlaceholderDimensions(const <PlaceholderDimensions>[
          PlaceholderDimensions(
            size: Size.square(_TextReaderViewState._inlineCommentHitSize),
            alignment: PlaceholderAlignment.middle,
          ),
        ]);
    painter.layout(maxWidth: _verticalExtentWidth);
    return painter.height;
  }

  GlobalKey _paragraphKey(String paragraphId) {
    final GlobalKey? existing = _paragraphKeys[paragraphId];
    if (existing != null) return existing;
    if (_paragraphKeys.length >= _TextReaderViewState._paragraphKeyCacheLimit) {
      _paragraphKeys.removeWhere(
        (String _, GlobalKey key) => key.currentContext == null,
      );
    }
    return _paragraphKeys.putIfAbsent(paragraphId, GlobalKey.new);
  }

  Future<void> _refreshCommentSummaries() async {
    final ReaderCommentFeed? feed = widget.extensions.commentFeed;
    final int generation = ++_commentGeneration;
    if (feed == null) {
      if (mounted) {
        setState(() {
          _commentSummaries.clear();
          _commentSummariesLoading = false;
          _commentSummariesFailed = false;
        });
      }
      return;
    }
    final List<ReaderCommentTarget> targets = <ReaderCommentTarget>[];
    if (_preferences.showBookComments) {
      targets.add(ReaderCommentTarget.book(widget.bookId));
    }
    final TextChapterContent? content = _content;
    if (_preferences.showChapterComments && content != null) {
      targets.add(
        ReaderCommentTarget.chapter(widget.bookId, content.chapterId),
      );
    }
    if (_preferences.showParagraphComments && content != null) {
      targets.addAll(
        content.paragraphs.map(
          (TextParagraph paragraph) => ReaderCommentTarget.paragraph(
            widget.bookId,
            content.chapterId,
            paragraph.id,
          ),
        ),
      );
    }
    if (targets.isEmpty) {
      if (mounted) {
        setState(() {
          _commentSummaries.clear();
          _commentSummariesLoading = false;
          _commentSummariesFailed = false;
        });
      }
      return;
    }
    for (final ReaderCommentTarget target in targets) {
      if (!_isValidCommentTarget(target)) {
        await _reportFailure(
          const ReaderFailure(
            ReaderFailureKind.data,
            ReaderStrings.invalidCommentTarget,
          ),
        );
        return;
      }
    }
    if (mounted) {
      setState(() {
        _commentSummariesLoading = true;
        _commentSummariesFailed = false;
      });
    }
    try {
      final Map<ReaderCommentTarget, ReaderCommentSummary> loaded =
          <ReaderCommentTarget, ReaderCommentSummary>{};
      var nextBatchStart = 0;
      Future<void> loadWorker() async {
        while (nextBatchStart < targets.length) {
          final int start = nextBatchStart;
          nextBatchStart += _TextReaderViewState._commentSummaryBatchSize;
          final int end =
              (start + _TextReaderViewState._commentSummaryBatchSize).clamp(
                0,
                targets.length,
              );
          final List<ReaderCommentTarget> batch =
              List<ReaderCommentTarget>.unmodifiable(
                targets.sublist(start, end),
              );
          final Map<ReaderCommentTarget, ReaderCommentSummary> response =
              await feed.loadSummaries(batch, previewLimit: 3);
          if (!mounted || generation != _commentGeneration) return;
          final Set<ReaderCommentTarget> requested = batch.toSet();
          for (final MapEntry<ReaderCommentTarget, ReaderCommentSummary> entry
              in response.entries) {
            if (!requested.contains(entry.key) ||
                !_isValidCommentTarget(entry.key) ||
                entry.key != entry.value.target ||
                entry.value.topComments.length > 3 ||
                entry.value.topComments.any(
                  (ReaderComment comment) => comment.target != entry.key,
                )) {
              throw const ReaderFailure(
                ReaderFailureKind.data,
                ReaderStrings.invalidCommentTarget,
              );
            }
          }
          loaded.addAll(response);
        }
      }

      final int batchCount =
          (targets.length +
              _TextReaderViewState._commentSummaryBatchSize -
              1) ~/
          _TextReaderViewState._commentSummaryBatchSize;
      final int workerCount = batchCount.clamp(1, 4);
      await Future.wait<void>(
        List<Future<void>>.generate(workerCount, (_) => loadWorker()),
      );
      if (!mounted || generation != _commentGeneration) return;
      setState(() {
        _commentSummaries
          ..clear()
          ..addEntries(
            targets.map(
              (ReaderCommentTarget target) => MapEntry(
                target,
                loaded[target] ??
                    ReaderCommentSummary(
                      target: target,
                      total: 0,
                      topComments: const <ReaderComment>[],
                    ),
              ),
            ),
          );
        _commentSummariesLoading = false;
        _commentSummariesFailed = false;
      });
    } catch (error) {
      if (!mounted || generation != _commentGeneration) return;
      setState(() {
        _commentSummaries
          ..clear()
          ..addEntries(
            targets.map(
              (ReaderCommentTarget target) => MapEntry(
                target,
                ReaderCommentSummary(
                  target: target,
                  total: 0,
                  topComments: const <ReaderComment>[],
                ),
              ),
            ),
          );
        _commentSummariesLoading = false;
        _commentSummariesFailed = true;
      });
      await _reportFailure(_asFailure(error, ReaderFailureKind.data));
    }
  }

  bool _isValidCommentTarget(ReaderCommentTarget target) {
    if (target.bookId.trim().isEmpty) return false;
    final String? chapterId = target.chapterId;
    final String? paragraphId = target.paragraphId;
    if (paragraphId != null) {
      return paragraphId.trim().isNotEmpty &&
          chapterId != null &&
          chapterId.trim().isNotEmpty;
    }
    return chapterId == null || chapterId.trim().isNotEmpty;
  }

  ReaderCommentSummary _commentSummary(ReaderCommentTarget target) {
    return _commentSummaries[target] ??
        ReaderCommentSummary(
          target: target,
          total: 0,
          topComments: const <ReaderComment>[],
        );
  }

  Widget _inlineParagraphComment({
    required ReaderCommentTarget target,
    required VoidCallback onPressed,
  }) {
    final ReaderCommentSummary summary = _commentSummary(target);
    final bool loading = _commentSummariesLoading;
    final bool failed = _commentSummariesFailed;
    final String semanticsLabel = loading
        ? ReaderCommentStrings.paragraphLoading
        : failed
        ? ReaderCommentStrings.paragraphLoadFailed
        : ReaderCommentStrings.paragraphCount(summary.total);
    final VoidCallback action = failed
        ? () => unawaited(_refreshCommentSummaries())
        : onPressed;
    return Tooltip(
      message: semanticsLabel,
      excludeFromSemantics: true,
      child: Semantics(
        button: true,
        label: semanticsLabel,
        excludeSemantics: true,
        onTap: loading ? null : action,
        child: SizedBox.square(
          dimension: _TextReaderViewState._inlineCommentHitSize,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: loading ? null : action,
              child: Center(
                child: Container(
                  width: _TextReaderViewState._inlineCommentVisualSize,
                  height: _TextReaderViewState._inlineCommentVisualSize,
                  decoration: BoxDecoration(
                    color: _palette.accent.withValues(alpha: .1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Center(
                    child: loading
                        ? SizedBox.square(
                            dimension: 12,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.5,
                              color: _palette.accent,
                            ),
                          )
                        : failed
                        ? Icon(
                            Icons.refresh_rounded,
                            size: 15,
                            color: _palette.accent,
                          )
                        : Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Icon(
                                Icons.chat_bubble_outline_rounded,
                                size: 11,
                                color: _palette.accent,
                              ),
                              const SizedBox(width: 2),
                              Flexible(
                                child: Text(
                                  ReaderCommentStrings.compactCount(
                                    summary.total,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.clip,
                                  style: TextStyle(
                                    color: _palette.accent,
                                    fontSize: 9,
                                    fontWeight: FontWeight.w700,
                                    height: 1,
                                  ),
                                ),
                              ),
                            ],
                          ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBookCommentSummary({
    required ReaderCommentTarget target,
    required VoidCallback onPressed,
  }) {
    final ReaderCommentSummary summary = _commentSummary(target);
    return SizedBox(
      height: 168,
      child: Material(
        color: _palette.panel.withValues(alpha: .82),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: _palette.divider),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: _commentSummariesLoading
              ? null
              : _commentSummariesFailed
              ? () => unawaited(_refreshCommentSummaries())
              : onPressed,
          child: Padding(
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
                        _commentSummariesLoading
                            ? ReaderCommentStrings.loading
                            : _commentSummariesFailed
                            ? ReaderCommentStrings.loadFailed
                            : '${ReaderCommentStrings.bookTitle} · ${summary.total}',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    const Icon(Icons.chevron_right_rounded, size: 19),
                  ],
                ),
                const SizedBox(height: 8),
                if (!_commentSummariesLoading &&
                    !_commentSummariesFailed &&
                    summary.topComments.isEmpty)
                  Text(
                    ReaderCommentStrings.empty,
                    style: TextStyle(color: _palette.secondaryText),
                  )
                else if (!_commentSummariesLoading && !_commentSummariesFailed)
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

  void _showComments(ReaderCommentTarget target, {String? title}) {
    _stopAutoReading();
    final ReaderCommentFeed? feed = widget.extensions.commentFeed;
    final ReaderObserver observer = _observer;
    if (feed == null) return;
    if (!_isValidCommentTarget(target)) {
      unawaited(
        _reportFailure(
          const ReaderFailure(
            ReaderFailureKind.data,
            ReaderStrings.invalidCommentTarget,
          ),
        ),
      );
      return;
    }
    unawaited(
      showReaderCommentsSheet(
        context: context,
        feed: feed,
        target: target,
        palette: _palette,
        title: title ?? ReaderCommentStrings.title,
        onLoadError: (Object error) => unawaited(
          _notify(
            () => observer.onFailure(_asFailure(error, ReaderFailureKind.data)),
          ),
        ),
      ),
    );
  }

  Future<void> _startAutoReading() async {
    if (!_foreground ||
        _content == null ||
        _failure != null ||
        _loading ||
        _changingChapter ||
        (_preferences.navigationMode == ReaderNavigationMode.horizontalPages &&
            _pages.isEmpty)) {
      return;
    }
    _setControlsVisible(false);
    if (_preferences.navigationMode == ReaderNavigationMode.horizontalPages) {
      _autoReadingCoordinator.startHorizontal(pace: _autoReadingPace);
    } else {
      _autoReadingCoordinator.startVertical(pace: _autoReadingPace);
    }
    _publishSnapshot();
  }

  void _stopAutoReading() {
    _autoReadingCoordinator.stop();
  }

  Future<void> _toggleAutoReading() async {
    if (_autoReadingCoordinator.isRunning) {
      _stopAutoReading();
    } else {
      await _startAutoReading();
    }
  }

  Future<bool> _autoAdvancePage() async {
    if (_content == null || _failure != null || _changingChapter) return false;
    if (_pageIndex + 1 < _pages.length) {
      await _animateToPage(_pageIndex + 1);
      return true;
    }
    return _nextChapterInternal();
  }

  Future<bool> _autoScrollBy(double delta) async {
    if (!_verticalController.hasClients || _content == null) return false;
    _autoScrolling = true;
    try {
      final ScrollPosition position = _verticalController.position;
      if (position.pixels + delta < position.maxScrollExtent) {
        _verticalController.jumpTo(position.pixels + delta);
        return true;
      }
      return await _nextChapterInternal();
    } finally {
      _autoScrolling = false;
    }
  }
}
