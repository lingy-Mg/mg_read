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

class TextPaginator {
  const TextPaginator();

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
  }) {
    if (width <= 0 || height <= 0) return const <ReaderPage>[];

    final List<ReaderPage> pages = <ReaderPage>[];
    List<ReaderPageBlock> blocks = <ReaderPageBlock>[];
    var usedHeight = _measure(
      chapter.title,
      width,
      titleStyle,
      textDirection,
      textScaler,
    ).height;
    usedHeight += 28;
    var showsTitle = true;

    void commitPage() {
      if (blocks.isEmpty && pages.isNotEmpty) return;
      pages.add(ReaderPage(blocks: blocks, showsTitle: showsTitle));
      blocks = <ReaderPageBlock>[];
      usedHeight = 0;
      showsTitle = false;
    }

    for (final TextParagraph paragraph in chapter.paragraphs) {
      // Never trim source text: offsets are semantic positions in the exact
      // host-provided paragraph, not positions in a display-only copy.
      final String source = paragraph.text;
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
            startOffset: 0,
            isParagraphStart: true,
            isParagraphEnd: true,
            paragraphTrailingWidth: trailingWidth,
            paragraphTrailingHeight: trailingHeight,
          ),
        );
        usedHeight += requiredHeight;
        continue;
      }

      var offset = 0;
      while (offset < source.length) {
        var available = height - usedHeight;
        if (available < _minimumLineHeight(bodyStyle) && blocks.isNotEmpty) {
          commitPage();
          available = height;
        }
        final bool paragraphStart = offset == 0;
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
              startOffset: offset,
              isParagraphStart: paragraphStart,
              isParagraphEnd: paragraphEnd,
              paragraphTrailingWidth: paragraphEnd ? trailingWidth : 0,
              paragraphTrailingHeight: paragraphEnd ? trailingHeight : 0,
            ),
          );
          offset = forcedEnd;
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
            startOffset: offset,
            isParagraphStart: paragraphStart,
            isParagraphEnd: paragraphEnd,
            paragraphTrailingWidth: paragraphEnd ? trailingWidth : 0,
            paragraphTrailingHeight: paragraphEnd ? trailingHeight : 0,
          ),
        );
        usedHeight += chunkHeight;
        offset = end;

        if (paragraphEnd) {
          usedHeight += paragraphSpacing;
        } else {
          commitPage();
        }
      }
    }

    if (blocks.isNotEmpty || pages.isEmpty) commitPage();
    final double resolvedChapterTrailingHeight = chapterTrailingHeight
        .clamp(0, height)
        .toDouble();
    if (resolvedChapterTrailingHeight > 0) {
      pages.add(
        ReaderPage(
          blocks: const <ReaderPageBlock>[],
          showsChapterTrailing: true,
          chapterTrailingHeight: resolvedChapterTrailingHeight,
        ),
      );
    }
    return List.unmodifiable(pages);
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
