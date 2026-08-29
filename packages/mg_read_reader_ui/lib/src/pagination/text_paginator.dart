import 'package:flutter/widgets.dart';

import '../api/models.dart';

@immutable
class ReaderPageBlock {
  const ReaderPageBlock({
    required this.paragraphId,
    required this.text,
    required this.startOffset,
    required this.isParagraphStart,
    required this.isParagraphEnd,
    this.paragraphTrailingWidth = 0,
    this.paragraphTrailingHeight = 0,
  });

  final String paragraphId;
  final String text;
  final int startOffset;
  final bool isParagraphStart;
  final bool isParagraphEnd;

  /// Fixed inline width reserved after the paragraph's last character.
  final double paragraphTrailingWidth;

  /// Fixed inline height reserved after the paragraph's last character.
  final double paragraphTrailingHeight;

  bool get hasParagraphTrailing =>
      paragraphTrailingWidth > 0 && paragraphTrailingHeight > 0;

  int get endOffset => startOffset + text.length;
}

@immutable
class ReaderPage {
  ReaderPage({
    required List<ReaderPageBlock> blocks,
    this.showsTitle = false,
    this.showsChapterTrailing = false,
    this.chapterTrailingHeight = 0,
  }) : blocks = List.unmodifiable(blocks);

  final List<ReaderPageBlock> blocks;
  final bool showsTitle;
  final bool showsChapterTrailing;
  final double chapterTrailingHeight;

  String get paragraphId => blocks.isEmpty ? '' : blocks.first.paragraphId;
  int get characterOffset => blocks.isEmpty ? 0 : blocks.first.startOffset;
}

/// Uncommitted page state carried between bounded pagination batches.
///
/// A batch boundary is only a scheduling boundary. It must never become a
/// visible page boundary while there is still room for another line.
@immutable
class ReaderPageContinuation {
  ReaderPageContinuation({
    required List<ReaderPageBlock> blocks,
    required this.usedHeight,
    required this.showsTitle,
  }) : blocks = List.unmodifiable(blocks);

  final List<ReaderPageBlock> blocks;
  final double usedHeight;
  final bool showsTitle;

  bool get isEmpty => blocks.isEmpty && !showsTitle;
}

/// Result of one bounded pagination batch.
@immutable
class ReaderPaginationBatch {
  ReaderPaginationBatch({
    required List<ReaderPage> pages,
    required this.continuation,
    required this.nextParagraphIndex,
    required this.nextCharacterOffset,
    required this.isComplete,
  }) : pages = List.unmodifiable(pages);

  /// Fully filled pages produced by this batch.
  final List<ReaderPage> pages;

  /// The still-fillable final page, if the caller has more text to process.
  final ReaderPageContinuation continuation;

  /// Paragraph index at which a page-bounded caller should resume.
  final int nextParagraphIndex;

  /// Character offset within [nextParagraphIndex] at which work should resume.
  final int nextCharacterOffset;

  /// Whether all supplied paragraphs were consumed.
  final bool isComplete;
}

class TextPaginator {
  const TextPaginator({this.onBatchPaginated, this.onParagraphVisited});

  /// Optional diagnostic hook invoked once for each bounded paginate call.
  final void Function()? onBatchPaginated;

  /// Optional paragraph-visit hook used by bounded layout diagnostics.
  final void Function(String paragraphId)? onParagraphVisited;

  List<ReaderPage> paginate({
    required TextChapterContent chapter,
    required double width,
    required double height,
    required TextStyle titleStyle,
    required TextStyle bodyStyle,
    required double paragraphSpacing,
    int firstLineIndent = 2,
    TextDirection textDirection = TextDirection.ltr,
    TextScaler textScaler = TextScaler.noScaling,
    double paragraphTrailingWidth = 0,
    double paragraphTrailingHeight = 0,
    double chapterTrailingHeight = 0,
    bool includeChapterTitle = true,
    int? maximumPages,
    int paragraphBaseOffset = 0,
    int firstParagraphStartOffset = 0,
    String? stopAfterParagraphId,
    int stopAfterCharacterOffset = 0,
  }) => paginateBatch(
    chapter: chapter,
    width: width,
    height: height,
    titleStyle: titleStyle,
    bodyStyle: bodyStyle,
    paragraphSpacing: paragraphSpacing,
    firstLineIndent: firstLineIndent,
    textDirection: textDirection,
    textScaler: textScaler,
    paragraphTrailingWidth: paragraphTrailingWidth,
    paragraphTrailingHeight: paragraphTrailingHeight,
    chapterTrailingHeight: chapterTrailingHeight,
    includeChapterTitle: includeChapterTitle,
    maximumPages: maximumPages,
    paragraphBaseOffset: paragraphBaseOffset,
    firstParagraphStartOffset: firstParagraphStartOffset,
    stopAfterParagraphId: stopAfterParagraphId,
    stopAfterCharacterOffset: stopAfterCharacterOffset,
    finish: true,
  ).pages;

  /// Paginates one bounded group of paragraphs without turning its end into a
  /// page break. Pass the returned [ReaderPaginationBatch.continuation] to the
  /// next group and set [finish] only for the final group.
  ReaderPaginationBatch paginateBatch({
    required TextChapterContent chapter,
    required double width,
    required double height,
    required TextStyle titleStyle,
    required TextStyle bodyStyle,
    required double paragraphSpacing,
    int firstLineIndent = 2,
    TextDirection textDirection = TextDirection.ltr,
    TextScaler textScaler = TextScaler.noScaling,
    double paragraphTrailingWidth = 0,
    double paragraphTrailingHeight = 0,
    double chapterTrailingHeight = 0,
    bool includeChapterTitle = true,
    int? maximumPages,
    int paragraphBaseOffset = 0,
    int firstParagraphStartOffset = 0,
    String? stopAfterParagraphId,
    int stopAfterCharacterOffset = 0,
    ReaderPageContinuation? continuation,
    bool finish = false,
  }) {
    if (width <= 0 || height <= 0) {
      return ReaderPaginationBatch(
        pages: const <ReaderPage>[],
        continuation: ReaderPageContinuation(
          blocks: const <ReaderPageBlock>[],
          usedHeight: 0,
          showsTitle: false,
        ),
        nextParagraphIndex: chapter.paragraphs.length,
        nextCharacterOffset: 0,
        isComplete: true,
      );
    }

    final List<ReaderPage> pages = <ReaderPage>[];
    List<ReaderPageBlock> blocks =
        continuation?.blocks.toList() ?? <ReaderPageBlock>[];
    var usedHeight =
        continuation?.usedHeight ??
        (includeChapterTitle
            ? _measure(
                    chapter.title,
                    width,
                    titleStyle,
                    textDirection,
                    textScaler,
                  ).height +
                  28
            : 0.0);
    var showsTitle = continuation?.showsTitle ?? includeChapterTitle;
    var reachedAnchor = false;
    var reachedPageLimit = false;
    var nextParagraphIndex = chapter.paragraphs.length;
    var nextCharacterOffset = 0;

    bool containsAnchor(ReaderPageBlock block) =>
        stopAfterParagraphId != null &&
        block.paragraphId == stopAfterParagraphId &&
        stopAfterCharacterOffset >= block.startOffset &&
        stopAfterCharacterOffset <= block.endOffset;

    void commitPage() {
      if (blocks.isEmpty && pages.isNotEmpty) return;
      pages.add(ReaderPage(blocks: blocks, showsTitle: showsTitle));
      if (pages.last.blocks.any(containsAnchor)) reachedAnchor = true;
      if (maximumPages != null && pages.length >= maximumPages) {
        reachedPageLimit = true;
      }
      blocks = <ReaderPageBlock>[];
      usedHeight = 0;
      showsTitle = false;
    }

    for (
      var paragraphIndex = 0;
      paragraphIndex < chapter.paragraphs.length && !reachedPageLimit;
      paragraphIndex++
    ) {
      final TextParagraph paragraph = chapter.paragraphs[paragraphIndex];
      onParagraphVisited?.call(paragraph.id);
      // Never trim source text: offsets are semantic positions in the exact
      // host-provided paragraph, not positions in a display-only copy.
      final int baseOffset = paragraphIndex == 0 ? paragraphBaseOffset : 0;
      final String source = paragraph.text;
      var offset = paragraphIndex == 0
          ? firstParagraphStartOffset.clamp(0, source.length)
          : 0;
      final double trailingWidth = paragraphTrailingWidth
          .clamp(0, width)
          .toDouble();
      final double trailingHeight = paragraphTrailingHeight
          .clamp(0, height)
          .toDouble();
      final bool hasTrailing = trailingWidth > 0 && trailingHeight > 0;
      if (source.isEmpty) {
        if (!hasTrailing) continue;
        final double requiredHeight = paragraphSpacing + trailingHeight;
        if (usedHeight + requiredHeight > height &&
            (blocks.isNotEmpty || showsTitle)) {
          commitPage();
        }
        blocks.add(
          ReaderPageBlock(
            paragraphId: paragraph.id,
            text: '',
            startOffset: baseOffset,
            isParagraphStart: true,
            isParagraphEnd: true,
            paragraphTrailingWidth: trailingWidth,
            paragraphTrailingHeight: trailingHeight,
          ),
        );
        usedHeight += requiredHeight;
        if (containsAnchor(blocks.last)) {
          commitPage();
          break;
        }
        continue;
      }

      while (offset < source.length && !reachedPageLimit) {
        var available = height - usedHeight;
        if (available < _minimumLineHeight(bodyStyle) && blocks.isNotEmpty) {
          commitPage();
          available = height;
        }
        final bool paragraphStart = offset == 0 && baseOffset == 0;
        int end = _largestFittingEnd(
          source: source,
          start: offset,
          availableWidth: width,
          availableHeight: available,
          style: bodyStyle,
          textDirection: textDirection,
          addIndent: paragraphStart,
          firstLineIndent: firstLineIndent,
          textScaler: textScaler,
        );

        // The fixed placeholder follows the last source character. Its size
        // never depends on async comment state, so count changes cannot alter
        // page boundaries. When the final run does not fit, leave at least one
        // code point for the following page and try again there.
        if (end == source.length && hasTrailing) {
          final String remaining = source.substring(offset);
          final String display = paragraphStart
              ? '${'\u3000' * firstLineIndent}$remaining'
              : remaining;
          final double inlineHeight = _measureWithTrailing(
            display,
            width,
            bodyStyle,
            textDirection,
            textScaler,
            trailingWidth,
            trailingHeight,
          ).height;
          if (inlineHeight > available + 0.1) {
            final int lastCharacterStart = _boundaryAtOrBefore(
              source,
              source.length - 1,
            );
            final int splitEnd = _largestFittingEnd(
              source: source,
              start: offset,
              maxEnd: lastCharacterStart,
              availableWidth: width,
              availableHeight: available,
              style: bodyStyle,
              textDirection: textDirection,
              addIndent: paragraphStart,
              firstLineIndent: firstLineIndent,
              textScaler: textScaler,
            );
            if (splitEnd > offset) {
              end = splitEnd;
            } else if (blocks.isNotEmpty || showsTitle) {
              commitPage();
              continue;
            }
          }
        }

        if (end <= offset) {
          if (blocks.isNotEmpty || showsTitle) {
            commitPage();
            continue;
          }
          final int forcedEnd = _nextBoundary(source, offset);
          final bool paragraphEnd = forcedEnd == source.length;
          blocks.add(
            ReaderPageBlock(
              paragraphId: paragraph.id,
              text: source.substring(offset, forcedEnd),
              startOffset: offset + baseOffset,
              isParagraphStart: paragraphStart,
              isParagraphEnd: paragraphEnd,
              paragraphTrailingWidth: paragraphEnd ? trailingWidth : 0,
              paragraphTrailingHeight: paragraphEnd ? trailingHeight : 0,
            ),
          );
          offset = forcedEnd;
          if (containsAnchor(blocks.last)) {
            commitPage();
            reachedAnchor = true;
            break;
          }
          commitPage();
          continue;
        }

        final String chunk = source.substring(offset, end);
        final bool paragraphEnd = end == source.length;
        final String display = paragraphStart
            ? '${'\u3000' * firstLineIndent}$chunk'
            : chunk;
        final double chunkHeight = paragraphEnd && hasTrailing
            ? _measureWithTrailing(
                display,
                width,
                bodyStyle,
                textDirection,
                textScaler,
                trailingWidth,
                trailingHeight,
              ).height
            : _measure(
                display,
                width,
                bodyStyle,
                textDirection,
                textScaler,
              ).height;
        blocks.add(
          ReaderPageBlock(
            paragraphId: paragraph.id,
            text: chunk,
            startOffset: offset + baseOffset,
            isParagraphStart: paragraphStart,
            isParagraphEnd: paragraphEnd,
            paragraphTrailingWidth: paragraphEnd ? trailingWidth : 0,
            paragraphTrailingHeight: paragraphEnd ? trailingHeight : 0,
          ),
        );
        usedHeight += chunkHeight;
        offset = end;

        if (containsAnchor(blocks.last)) {
          commitPage();
          reachedAnchor = true;
          break;
        }

        if (paragraphEnd) {
          usedHeight += paragraphSpacing;
        } else {
          commitPage();
        }
      }
      if (reachedPageLimit) {
        if (offset < source.length) {
          nextParagraphIndex = paragraphIndex;
          nextCharacterOffset = offset;
        } else {
          nextParagraphIndex = paragraphIndex + 1;
          nextCharacterOffset = 0;
        }
      }
      if (reachedAnchor || reachedPageLimit) break;
    }

    if (finish && (blocks.isNotEmpty || pages.isEmpty)) commitPage();
    final double resolvedChapterTrailingHeight = chapterTrailingHeight
        .clamp(0, height)
        .toDouble();
    if (finish &&
        !reachedAnchor &&
        !reachedPageLimit &&
        resolvedChapterTrailingHeight > 0) {
      pages.add(
        ReaderPage(
          blocks: const <ReaderPageBlock>[],
          showsChapterTrailing: true,
          chapterTrailingHeight: resolvedChapterTrailingHeight,
        ),
      );
    }
    onBatchPaginated?.call();
    return ReaderPaginationBatch(
      pages: pages,
      continuation: ReaderPageContinuation(
        blocks: blocks,
        usedHeight: usedHeight,
        showsTitle: showsTitle,
      ),
      nextParagraphIndex: nextParagraphIndex,
      nextCharacterOffset: nextCharacterOffset,
      isComplete: nextParagraphIndex >= chapter.paragraphs.length,
    );
  }

  int pageIndexForAnchor(
    List<ReaderPage> pages,
    String paragraphId,
    int characterOffset,
  ) {
    for (var pageIndex = 0; pageIndex < pages.length; pageIndex++) {
      final ReaderPage page = pages[pageIndex];
      for (final ReaderPageBlock block in page.blocks) {
        if (block.paragraphId == paragraphId &&
            characterOffset >= block.startOffset &&
            characterOffset <= block.endOffset) {
          return pageIndex;
        }
      }
    }
    return 0;
  }

  int _largestFittingEnd({
    required String source,
    required int start,
    int? maxEnd,
    required double availableWidth,
    required double availableHeight,
    required TextStyle style,
    required TextDirection textDirection,
    required bool addIndent,
    required int firstLineIndent,
    required TextScaler textScaler,
  }) {
    final int limit = (maxEnd ?? source.length).clamp(start, source.length);
    if (start >= limit || availableHeight <= 0) return start;

    bool fits(int end) {
      final String chunk = source.substring(start, end);
      final String display = addIndent
          ? '${'\u3000' * firstLineIndent}$chunk'
          : chunk;
      return _measure(
            display,
            availableWidth,
            style,
            textDirection,
            textScaler,
          ).height <=
          availableHeight + 0.1;
    }

    int low = start;
    int span = 1;
    int high = limit;
    while (low < limit) {
      int probe = (start + span).clamp(start + 1, limit);
      probe = _boundaryAtOrBefore(source, probe);
      if (probe <= low) probe = _nextBoundary(source, low).clamp(0, limit);
      if (probe <= low || !fits(probe)) {
        high = probe;
        break;
      }
      low = probe;
      if (low == limit) return low;
      final int remaining = limit - start;
      span = span >= remaining ~/ 2 ? remaining : span * 2;
    }

    while (_nextBoundary(source, low) < high) {
      int mid = low + ((high - low) ~/ 2);
      mid = _boundaryAtOrBefore(source, mid);
      if (mid <= low) mid = _nextBoundary(source, low);
      if (mid >= high) break;
      if (fits(mid)) {
        low = mid;
      } else {
        high = mid;
      }
    }
    return low;
  }

  int _boundaryAtOrBefore(String value, int offset) {
    int result = offset.clamp(0, value.length);
    if (result > 0 &&
        result < value.length &&
        _isLowSurrogate(value.codeUnitAt(result))) {
      result--;
    }
    return result;
  }

  int _nextBoundary(String value, int offset) {
    if (offset >= value.length) return value.length;
    var result = offset + 1;
    if (result < value.length && _isLowSurrogate(value.codeUnitAt(result))) {
      result++;
    }
    return result.clamp(0, value.length);
  }

  bool _isLowSurrogate(int codeUnit) =>
      codeUnit >= 0xDC00 && codeUnit <= 0xDFFF;

  Size _measure(
    String text,
    double width,
    TextStyle style,
    TextDirection textDirection,
    TextScaler textScaler,
  ) {
    final TextPainter painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: textDirection,
      textScaler: textScaler,
    )..layout(maxWidth: width);
    return painter.size;
  }

  Size _measureWithTrailing(
    String text,
    double width,
    TextStyle style,
    TextDirection textDirection,
    TextScaler textScaler,
    double trailingWidth,
    double trailingHeight,
  ) {
    final TextPainter painter =
        TextPainter(
          text: TextSpan(
            style: style,
            children: <InlineSpan>[
              TextSpan(text: text),
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: SizedBox(width: trailingWidth, height: trailingHeight),
              ),
            ],
          ),
          textDirection: textDirection,
          textScaler: textScaler,
        )..setPlaceholderDimensions(<PlaceholderDimensions>[
          PlaceholderDimensions(
            size: Size(trailingWidth, trailingHeight),
            alignment: PlaceholderAlignment.middle,
          ),
        ]);
    painter.layout(maxWidth: width);
    return painter.size;
  }

  double _minimumLineHeight(TextStyle style) {
    return (style.fontSize ?? 16) * (style.height ?? 1.2);
  }
}
