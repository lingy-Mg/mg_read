import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/contracts.dart';
import '../../api/models.dart';
import '../reader_theme.dart';
import 'reader_comment_strings.dart';

class ReaderParagraphCommentButton extends StatelessWidget {
  const ReaderParagraphCommentButton({
    required this.summary,
    required this.palette,
    required this.onPressed,
    this.loading = false,
    this.hasError = false,
    this.onRetry,
    super.key,
  });

  final ReaderCommentSummary summary;
  final ReaderPalette palette;
  final VoidCallback onPressed;
  final bool loading;
  final bool hasError;
  final VoidCallback? onRetry;

  /// Stable height that the text paginator can reserve before build.
  static const double reservedHeight = 48;

  @override
  Widget build(BuildContext context) {
    final VoidCallback action = hasError && onRetry != null
        ? onRetry!
        : onPressed;
    final String semanticLabel = loading
        ? ReaderCommentStrings.paragraphLoading
        : hasError
        ? ReaderCommentStrings.paragraphLoadFailed
        : ReaderCommentStrings.paragraphCount(summary.total);
    return SizedBox(
      width: double.infinity,
      height: reservedHeight,
      child: Align(
        alignment: Alignment.centerRight,
        child: Tooltip(
          message: semanticLabel,
          excludeFromSemantics: true,
          child: Semantics(
            button: true,
            enabled: !loading,
            label: semanticLabel,
            onTap: loading ? null : action,
            excludeSemantics: true,
            child: Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(24),
              child: InkWell(
                borderRadius: BorderRadius.circular(24),
                onTap: loading ? null : action,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    minWidth: reservedHeight,
                    minHeight: reservedHeight,
                  ),
                  child: Center(
                    child: SizedBox.square(
                      dimension: 30,
                      child: Stack(
                        alignment: Alignment.center,
                        children: <Widget>[
                          Icon(
                            Icons.chat_bubble_outline_rounded,
                            size: 28,
                            color: hasError
                                ? palette.accent
                                : palette.secondaryText,
                          ),
                          Positioned(
                            left: 6,
                            right: 6,
                            top: 6,
                            height: 10,
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                loading
                                    ? '…'
                                    : hasError
                                    ? '!'
                                    : ReaderCommentStrings.compactCount(
                                        summary.total,
                                      ),
                                maxLines: 1,
                                style: TextStyle(
                                  color: hasError
                                      ? palette.accent
                                      : palette.secondaryText,
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.w700,
                                  height: 1,
                                ),
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
      ),
    );
  }
}

Future<void> showReaderCommentsSheet({
  required BuildContext context,
  required ReaderCommentFeed feed,
  required ReaderCommentTarget target,
  required ReaderPalette palette,
  String title = ReaderCommentStrings.title,
  ValueChanged<Object>? onLoadError,
  ValueChanged<BuildContext>? onSheetBuilt,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (BuildContext context) {
      onSheetBuilt?.call(context);
      return ReaderCommentsSheet(
        feed: feed,
        target: target,
        palette: palette,
        title: title,
        onLoadError: onLoadError,
      );
    },
  );
}

class ReaderCommentsSheet extends StatefulWidget {
  const ReaderCommentsSheet({
    required this.feed,
    required this.target,
    required this.palette,
    this.title = ReaderCommentStrings.title,
    this.pageSize = 20,
    this.onLoadError,
    super.key,
  });

  final ReaderCommentFeed feed;
  final ReaderCommentTarget target;
  final ReaderPalette palette;
  final String title;
  final int pageSize;
  final ValueChanged<Object>? onLoadError;

  @override
  State<ReaderCommentsSheet> createState() => _ReaderCommentsSheetState();
}

class _ReaderCommentsSheetState extends State<ReaderCommentsSheet> {
  ReaderCommentSort _sort = ReaderCommentSort.hot;
  List<ReaderComment> _comments = const <ReaderComment>[];
  String? _nextCursor;
  int _total = 0;
  int _generation = 0;
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;
  Object? _error;

  int get _requestPageSize => widget.pageSize.clamp(1, 100);

  @override
  void initState() {
    super.initState();
    unawaited(_loadFirstPage());
  }

  @override
  void didUpdateWidget(covariant ReaderCommentsSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.feed != widget.feed || oldWidget.target != widget.target) {
      unawaited(_loadFirstPage());
    }
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  Future<void> _loadFirstPage() async {
    final int generation = ++_generation;
    setState(() {
      _loading = true;
      _loadingMore = false;
      _comments = const <ReaderComment>[];
      _nextCursor = null;
      _hasMore = false;
      _total = 0;
      _error = null;
    });
    try {
      final ReaderCommentPage page = await widget.feed.loadComments(
        widget.target,
        sort: _sort,
        pageSize: _requestPageSize,
      );
      if (!mounted || generation != _generation) return;
      final List<ReaderComment> items = _validatedItems(page.items);
      if (page.total < items.length ||
          (page.hasMore && (page.nextCursor == null || items.isEmpty))) {
        throw StateError(ReaderCommentStrings.invalidPage);
      }
      setState(() {
        _comments = List<ReaderComment>.unmodifiable(items);
        _nextCursor = page.nextCursor;
        _hasMore = page.hasMore && page.nextCursor != null;
        _total = page.total;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      _reportLoadError(error);
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !_hasMore) return;
    final int generation = _generation;
    setState(() {
      _loadingMore = true;
      _error = null;
    });
    try {
      final ReaderCommentPage page = await widget.feed.loadComments(
        widget.target,
        sort: _sort,
        cursor: _nextCursor,
        pageSize: _requestPageSize,
      );
      if (!mounted || generation != _generation) return;
      final List<ReaderComment> items = _validatedItems(page.items);
      final Set<String> knownIds = _comments
          .map((ReaderComment comment) => comment.id)
          .toSet();
      final List<ReaderComment> newItems = items
          .where((ReaderComment comment) => knownIds.add(comment.id))
          .toList(growable: false);
      final bool cursorAdvanced =
          page.nextCursor != null && page.nextCursor != _nextCursor;
      if (page.total != _total ||
          page.total < _comments.length + newItems.length ||
          (items.isNotEmpty && newItems.isEmpty) ||
          (page.hasMore && (!cursorAdvanced || newItems.isEmpty))) {
        throw StateError(ReaderCommentStrings.invalidPage);
      }
      setState(() {
        _comments = List<ReaderComment>.unmodifiable(<ReaderComment>[
          ..._comments,
          ...newItems,
        ]);
        _nextCursor = page.nextCursor;
        _hasMore = page.hasMore && cursorAdvanced && newItems.isNotEmpty;
        _total = page.total;
        _loadingMore = false;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      _reportLoadError(error);
      setState(() {
        _error = error;
        _loadingMore = false;
      });
    }
  }

  void _selectSort(ReaderCommentSort sort) {
    if (sort == _sort) return;
    setState(() => _sort = sort);
    unawaited(_loadFirstPage());
  }

  List<ReaderComment> _validatedItems(List<ReaderComment> items) {
    if (!_isValidTarget(widget.target)) {
      throw StateError(ReaderCommentStrings.invalidPage);
    }
    for (final ReaderComment comment in items) {
      if (comment.target != widget.target) {
        throw StateError('Comment feed returned an item for another target.');
      }
    }
    final Set<String> ids = <String>{};
    if (items.any((ReaderComment comment) => !ids.add(comment.id))) {
      throw StateError(ReaderCommentStrings.invalidPage);
    }
    return List<ReaderComment>.unmodifiable(items);
  }

  bool _isValidTarget(ReaderCommentTarget target) {
    if (target.bookId.trim().isEmpty) return false;
    final String? chapterId = target.chapterId;
    final String? paragraphId = target.paragraphId;
    final String? imageId = target.imageId;
    if (paragraphId != null && imageId != null) return false;
    if (imageId != null) {
      return imageId.trim().isNotEmpty &&
          chapterId != null &&
          chapterId.trim().isNotEmpty;
    }
    if (paragraphId != null) {
      return paragraphId.trim().isNotEmpty &&
          chapterId != null &&
          chapterId.trim().isNotEmpty;
    }
    return chapterId == null || chapterId.trim().isNotEmpty;
  }

  void _reportLoadError(Object error) {
    try {
      widget.onLoadError?.call(error);
    } catch (callbackError, stackTrace) {
      debugPrint(
        'novel_reader_ui comment error callback failed: '
        '$callbackError\n$stackTrace',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final ReaderPalette palette = widget.palette;
    final MediaQueryData mediaQuery = MediaQuery.of(context);
    return MediaQuery(
      data: mediaQuery.copyWith(
        textScaler: mediaQuery.textScaler.clamp(maxScaleFactor: 1.3),
      ),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640, maxHeight: 620),
          child: ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            child: Material(
              color: palette.panel,
              child: SafeArea(
                top: false,
                child: SizedBox(
                  height: MediaQuery.sizeOf(context).height * .78,
                  child: Column(
                    children: <Widget>[
                      const SizedBox(height: 8),
                      Container(
                        width: 34,
                        height: 4,
                        decoration: BoxDecoration(
                          color: palette.divider,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 8, 2),
                        child: Row(
                          children: <Widget>[
                            Expanded(
                              child: Text(
                                _total > 0
                                    ? '${widget.title} · ${ReaderCommentStrings.compactCount(_total)}'
                                    : widget.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: palette.text,
                                  fontSize: 17,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: ReaderCommentStrings.close,
                              onPressed: () => Navigator.of(context).pop(),
                              icon: const Icon(Icons.close_rounded, size: 20),
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: SegmentedButton<ReaderCommentSort>(
                            style: ButtonStyle(
                              minimumSize: const WidgetStatePropertyAll<Size>(
                                Size(76, 48),
                              ),
                              textStyle:
                                  const WidgetStatePropertyAll<TextStyle>(
                                    TextStyle(fontSize: 13),
                                  ),
                            ),
                            segments: const <ButtonSegment<ReaderCommentSort>>[
                              ButtonSegment<ReaderCommentSort>(
                                value: ReaderCommentSort.hot,
                                label: Text(ReaderCommentStrings.hot),
                              ),
                              ButtonSegment<ReaderCommentSort>(
                                value: ReaderCommentSort.newest,
                                label: Text(ReaderCommentStrings.newest),
                              ),
                            ],
                            selected: <ReaderCommentSort>{_sort},
                            showSelectedIcon: false,
                            onSelectionChanged:
                                (Set<ReaderCommentSort> value) =>
                                    _selectSort(value.single),
                          ),
                        ),
                      ),
                      Divider(height: 1, color: palette.divider),
                      Expanded(child: _buildBody()),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox.square(
              dimension: 30,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: widget.palette.accent,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              ReaderCommentStrings.loading,
              style: TextStyle(color: widget.palette.secondaryText),
            ),
          ],
        ),
      );
    }
    if (_error != null && _comments.isEmpty) {
      return _ReaderCommentError(onRetry: _loadFirstPage);
    }
    if (_comments.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.chat_bubble_outline_rounded,
              size: 32,
              color: widget.palette.secondaryText,
            ),
            const SizedBox(height: 10),
            Text(
              ReaderCommentStrings.empty,
              style: TextStyle(color: widget.palette.secondaryText),
            ),
          ],
        ),
      );
    }
    final int footerCount = _hasMore || _error != null ? 1 : 0;
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 20),
      itemCount: _comments.length + footerCount,
      separatorBuilder: (_, _) => Divider(color: widget.palette.divider),
      itemBuilder: (BuildContext context, int index) {
        if (index == _comments.length) return _buildFooter();
        return _ReaderCommentTile(
          comment: _comments[index],
          palette: widget.palette,
        );
      },
    );
  }

  Widget _buildFooter() {
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: OutlinedButton(
          onPressed: _loadMore,
          child: const Text(ReaderCommentStrings.retry),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: OutlinedButton(
        onPressed: _loadingMore ? null : _loadMore,
        child: Text(
          _loadingMore
              ? ReaderCommentStrings.loadingMore
              : ReaderCommentStrings.loadMore,
        ),
      ),
    );
  }
}

class _ReaderCommentTile extends StatelessWidget {
  const _ReaderCommentTile({required this.comment, required this.palette});

  final ReaderComment comment;
  final ReaderPalette palette;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  comment.authorName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: palette.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                _dateLabel(comment.createdAt),
                style: TextStyle(color: palette.secondaryText, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            comment.content,
            style: TextStyle(color: palette.text, fontSize: 14, height: 1.5),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.thumb_up_outlined,
                size: 15,
                color: palette.secondaryText,
              ),
              const SizedBox(width: 4),
              Text(
                '${ReaderCommentStrings.compactCount(comment.likeCount)} ${ReaderCommentStrings.likes}',
                style: TextStyle(color: palette.secondaryText, fontSize: 12),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _dateLabel(DateTime value) {
    final DateTime local = value.toLocal();
    final String month = local.month.toString().padLeft(2, '0');
    final String day = local.day.toString().padLeft(2, '0');
    return '${local.year}-$month-$day';
  }
}

class _ReaderCommentError extends StatelessWidget {
  const _ReaderCommentError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.refresh_rounded,
            size: 32,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 10),
          const Text(ReaderCommentStrings.loadFailed),
          const SizedBox(height: 10),
          FilledButton.tonal(
            onPressed: onRetry,
            child: const Text(ReaderCommentStrings.retry),
          ),
        ],
      ),
    );
  }
}
