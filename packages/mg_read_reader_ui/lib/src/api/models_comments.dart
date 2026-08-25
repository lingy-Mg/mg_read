part of 'models.dart';

/// Stable target for book, chapter, paragraph, or comic-image comments.
@immutable
class ReaderCommentTarget {
  /// Creates a target for comments about the whole book.
  ///
  /// Hosts must supply a non-empty, non-whitespace identifier.
  const ReaderCommentTarget.book(this.bookId)
    : chapterId = null,
      paragraphId = null,
      imageId = null;

  /// Creates a target for comments about one chapter.
  ///
  /// Invalid targets are rejected before the reader invokes a feed.
  const ReaderCommentTarget.chapter(this.bookId, this.chapterId)
    : paragraphId = null,
      imageId = null;

  /// Creates a target for comments about one stable paragraph.
  const ReaderCommentTarget.paragraph(
    this.bookId,
    this.chapterId,
    this.paragraphId,
  ) : imageId = null;

  /// Creates a target for one stable comic image.
  const ReaderCommentTarget.comicImage(
    this.bookId,
    this.chapterId,
    this.imageId,
  ) : paragraphId = null;

  /// Stable identifier of the target book.
  final String bookId;

  /// Stable chapter identifier, or null for a book-level target.
  final String? chapterId;

  /// Stable paragraph identifier, or null for a broader target.
  final String? paragraphId;

  /// Stable comic image identifier, or null for text and broader targets.
  final String? imageId;

  @override
  bool operator ==(Object other) =>
      other is ReaderCommentTarget &&
      bookId == other.bookId &&
      chapterId == other.chapterId &&
      paragraphId == other.paragraphId &&
      imageId == other.imageId;

  @override
  int get hashCode => Object.hash(bookId, chapterId, paragraphId, imageId);
}

/// One immutable, read-only comment supplied by a host comment feed.
@immutable
class ReaderComment {
  /// Creates a comment suitable for direct display by the reader.
  factory ReaderComment({
    required String id,
    required ReaderCommentTarget target,
    required String authorName,
    required String content,
    required DateTime createdAt,
    required int likeCount,
  }) {
    if (likeCount < 0) {
      throw RangeError.value(likeCount, 'likeCount', 'Must not be negative.');
    }
    return ReaderComment._(
      id: _requireIdentifier(id, 'id'),
      target: target,
      authorName: _requireDisplayText(authorName, 'authorName'),
      content: _requireDisplayText(content, 'content'),
      createdAt: createdAt,
      likeCount: likeCount,
    );
  }

  const ReaderComment._({
    required this.id,
    required this.target,
    required this.authorName,
    required this.content,
    required this.createdAt,
    required this.likeCount,
  });

  /// Stable comment identifier supplied by the host.
  final String id;

  /// Book, chapter, paragraph, or comic-image target for this comment.
  final ReaderCommentTarget target;

  /// Display name for the comment author.
  final String authorName;

  /// Plain-text, read-only comment body.
  final String content;

  /// Host-supplied creation time.
  final DateTime createdAt;

  /// Non-negative, read-only number of likes reported by the host.
  final int likeCount;
}

/// A compact comment summary used to decorate reader entry points.
@immutable
class ReaderCommentSummary {
  /// Creates a summary for [target].
  factory ReaderCommentSummary({
    required ReaderCommentTarget target,
    required int total,
    required List<ReaderComment> topComments,
  }) {
    if (total < 0) {
      throw RangeError.value(total, 'total', 'Must not be negative.');
    }
    if (topComments.length > total) {
      throw ArgumentError.value(
        topComments.length,
        'topComments',
        'Cannot contain more entries than total.',
      );
    }
    if (topComments.any((ReaderComment comment) => comment.target != target)) {
      throw ArgumentError.value(
        topComments,
        'topComments',
        'Every preview comment must match the summary target.',
      );
    }
    return ReaderCommentSummary._(
      target: target,
      total: total,
      topComments: List.unmodifiable(topComments),
    );
  }

  const ReaderCommentSummary._({
    required this.target,
    required this.total,
    required this.topComments,
  });

  /// Target represented by this summary.
  final ReaderCommentTarget target;

  /// Non-negative total number of comments available for [target].
  final int total;

  /// Host-selected preview comments, in display order.
  final List<ReaderComment> topComments;
}

/// One cursor-based page of read-only comments.
@immutable
class ReaderCommentPage {
  /// Creates a page returned by a comment feed.
  factory ReaderCommentPage({
    required List<ReaderComment> items,
    required int total,
    required bool hasMore,
    String? nextCursor,
  }) {
    if (total < 0) {
      throw RangeError.value(total, 'total', 'Must not be negative.');
    }
    if (items.length > total) {
      throw ArgumentError.value(
        items.length,
        'items',
        'Cannot contain more entries than total.',
      );
    }
    final String? normalizedCursor = nextCursor?.trim();
    if (hasMore && (normalizedCursor == null || normalizedCursor.isEmpty)) {
      throw ArgumentError.value(
        nextCursor,
        'nextCursor',
        'A non-empty advancing cursor is required when hasMore is true.',
      );
    }
    if (hasMore && items.isEmpty) {
      throw ArgumentError.value(
        items,
        'items',
        'A page with more data must make item progress.',
      );
    }
    if (!hasMore && nextCursor != null) {
      throw ArgumentError.value(
        nextCursor,
        'nextCursor',
        'Must be null when hasMore is false.',
      );
    }
    final Set<String> ids = <String>{};
    if (items.any((ReaderComment comment) => !ids.add(comment.id))) {
      throw ArgumentError.value(
        items,
        'items',
        'Comment identifiers must be unique within a page.',
      );
    }
    return ReaderCommentPage._(
      items: List.unmodifiable(items),
      nextCursor: nextCursor,
      total: total,
      hasMore: hasMore,
    );
  }

  const ReaderCommentPage._({
    required this.items,
    required this.nextCursor,
    required this.total,
    required this.hasMore,
  });

  /// Comments in the requested host-defined order.
  final List<ReaderComment> items;

  /// Cursor to pass to the next request, or null when none is available.
  final String? nextCursor;

  /// Non-negative total number of comments available for the requested target.
  final int total;

  /// Whether another page can be requested with [nextCursor].
  final bool hasMore;
}

/// Read-only state published by [TextReaderController].
@immutable
class TextReaderSnapshot {
  /// Creates a controller snapshot.
  const TextReaderSnapshot({
    required this.isReady,
    required this.isLoading,
    required this.controlsVisible,
    this.isAutoReading = false,
    this.book,
    this.chapter,
    this.progress,
    this.failure,
  });

  const TextReaderSnapshot.initial()
    : isReady = false,
      isLoading = true,
      controlsVisible = false,
      isAutoReading = false,
      book = null,
      chapter = null,
      progress = null,
      failure = null;

  /// Whether the reader has usable content or a usable book preview.
  final bool isReady;

  /// Whether initialization or a reader command is currently loading.
  final bool isLoading;

  /// Whether the reader's toolbar chrome is visible.
  final bool controlsVisible;

  /// Whether session-scoped automatic reading is currently active.
  final bool isAutoReading;

  /// Currently loaded book metadata, when available.
  final ReaderBookInfo? book;

  /// Currently opened chapter metadata, when reading chapter content.
  final ReaderChapterInfo? chapter;

  /// Latest semantic reading position, when available.
  final ReaderProgress? progress;

  /// Latest recoverable reader failure, when present.
  final ReaderFailure? failure;
}
