import 'dart:async';

import 'package:flutter/foundation.dart';

import 'models.dart';

/// Supplies book metadata, catalog pages, and chapter content asynchronously.
abstract interface class TextReaderDataSource {
  /// Loads lightweight metadata for [bookId].
  Future<ReaderBookInfo> loadBookInfo(String bookId);

  /// Loads one cursor-based catalog page for [bookId].
  ///
  /// [cursor] is the opaque continuation token returned by the previous page.
  /// [pageSize] is a request hint and defaults to 100. Returned chapter IDs
  /// and indexes must remain unique across pages, [ChapterCatalogPage.total]
  /// must remain stable, and a page with more data must advance its cursor.
  Future<ChapterCatalogPage> loadChapterCatalog(
    String bookId, {
    String? cursor,
    int pageSize = 100,
  });

  /// Resolves one chapter without scanning catalog pages from the beginning.
  ///
  /// [index] is zero-based and must match [ReaderChapterInfo.index] in the
  /// returned value. This is used for whole-book progress jumps and adjacent
  /// chapter navigation.
  Future<ReaderChapterInfo> loadChapterAtIndex(String bookId, int index);

  /// Loads the complete plain-text content for [chapterId] in [bookId].
  ///
  /// For a remote chapter that is not downloaded, this future is the host's
  /// opportunity to download and cache it before returning. The plugin never
  /// performs network or persistent-cache I/O itself.
  Future<TextChapterContent> loadChapterContent(
    String bookId,
    String chapterId,
  );
}

/// Optional host capability for refreshing mutable text chapter state.
abstract interface class ReaderChapterStateCapability {
  /// Loads current states for the requested stable [chapterIds].
  ///
  /// The returned map may omit unknown chapters. Every key must equal its
  /// value's [ReaderChapterState.chapterId]. Network and cache access belong
  /// entirely to the host.
  Future<Map<String, ReaderChapterState>> loadChapterStates(
    String bookId,
    List<String> chapterIds,
  );

  /// Marks [chapterId] as read in host-owned state.
  ///
  /// This is a semantic notification and must be safe to repeat.
  Future<void> markRead(String bookId, String chapterId);
}

/// Optional host repository for external reader fonts.
///
/// The plugin never opens descriptor URLs. Implementations own networking,
/// licensing, integrity checks, persistent files, and cache eviction.
abstract interface class ReaderFontRepository {
  /// Loads the descriptors available to the current user and session.
  Future<List<ReaderFontDescriptor>> loadCatalog();

  /// Returns cached font bytes, or null when this font is not installed.
  ///
  /// After [install] completes, every weight declared by the descriptor must
  /// be available through this method. Returned lists may be copied or retained
  /// by the reader and must not be mutated by the repository afterward.
  Future<Uint8List?> loadCachedFontBytes(
    String fontId, {
    String? version,
    int? weight,
  });

  /// Returns cached preview-image bytes, or null when unavailable.
  Future<Uint8List?> loadCachedPreviewBytes(String fontId, {String? version});

  /// Performs any host-owned download, validation, and persistent install.
  Future<void> install(ReaderFontDescriptor descriptor);

  /// Removes host-owned cached files and hides the installed entry.
  ///
  /// Flutter engine fonts already registered in the current process cannot be
  /// unloaded; removing files affects future loads, not existing engine state.
  Future<void> remove(String fontId);
}

/// Persists user-specific reader state without constraining the host database.
abstract interface class TextReaderStateStore {
  /// Loads the last semantic progress for [bookId], or null when none exists.
  Future<ReaderProgress?> loadProgress(String bookId);

  /// Persists the latest semantic [progress] for [bookId].
  Future<void> saveProgress(String bookId, ReaderProgress progress);

  /// Loads reader-owned preferences, or null when none have been saved.
  Future<TextReaderPreferences?> loadPreferences();

  /// Persists reader-owned [preferences] without changing their values.
  Future<void> savePreferences(TextReaderPreferences preferences);

  /// Loads all bookmarks currently available for [bookId].
  Future<List<ReaderBookmark>> loadBookmarks(String bookId);

  /// Persists a reader-generated [bookmark].
  Future<void> addBookmark(ReaderBookmark bookmark);

  /// Removes [bookmarkId] from [bookId] when it exists.
  Future<void> removeBookmark(String bookId, String bookmarkId);
}

/// Optional host notifications for reader session and lifecycle events.
class ReaderObserver {
  /// Creates an observer whose callbacks are no-ops by default.
  const ReaderObserver();

  /// Called after a reading session for [bookId] successfully starts.
  FutureOr<void> onSessionStarted(String bookId) {}

  /// Called as the session ends with its latest semantic [progress].
  FutureOr<void> onSessionEnded(String bookId, ReaderProgress? progress) {}

  /// Called once for each normalized lifecycle [state] transition.
  FutureOr<void> onLifecycleChanged(
    ReaderLifecycleState state,
    ReaderProgress? progress,
  ) {}

  /// Called after the reader commits a change to [chapter].
  FutureOr<void> onChapterChanged(ReaderChapterInfo chapter) {}

  /// Called for a recoverable [failure] that did not crash the reader.
  FutureOr<void> onFailure(ReaderFailure failure) {}

  /// Requests that the host close or otherwise leave the reader.
  ///
  /// The reader never pops the host navigator itself.
  FutureOr<void> onExitRequested(ReaderProgress? progress) {}
}

@immutable
/// Optional capabilities that can be registered without changing core data APIs.
class ReaderExtensions {
  /// Creates a set of independently optional reader extensions.
  const ReaderExtensions({
    this.commentFeed,
    this.chapterStateCapability,
    this.fontRepository,
    @Deprecated('Use commentFeed for the reader-owned read-only comment UI.')
    this.comments,
  });

  /// Optional read-only comment data source used by reader-owned comment UI.
  final ReaderCommentFeed? commentFeed;

  /// Optional source of mutable download/read state for text chapters.
  final ReaderChapterStateCapability? chapterStateCapability;

  /// Optional host-owned catalog, installer, and cache for external fonts.
  final ReaderFontRepository? fontRepository;

  /// Legacy host-owned comment entry point.
  @Deprecated('Use commentFeed for the reader-owned read-only comment UI.')
  final ReaderCommentsCapability? comments;
}

/// Legacy host-owned entry point for an external comments experience.
@Deprecated('Use ReaderCommentFeed for reader-owned read-only comment UI.')
abstract interface class ReaderCommentsCapability {
  /// Opens the host-owned experience for [target].
  Future<void> open(ReaderCommentTarget target);
}

/// Supplies optional, read-only comments independently from book content APIs.
///
/// Implementations must not mutate comment state in response to these methods.
/// Errors may be thrown and are converted by the reader into recoverable
/// failures without interrupting reading.
abstract interface class ReaderCommentFeed {
  /// Loads compact summaries for multiple [targets] in one host request.
  ///
  /// The returned map may omit targets that have no comments. Each summary's
  /// [ReaderCommentSummary.topComments] should contain at most [previewLimit]
  /// entries. [previewLimit] defaults to 3 and must be treated as non-negative.
  /// Every map key must equal its summary's [ReaderCommentSummary.target], and
  /// every preview comment must match that same target.
  Future<Map<ReaderCommentTarget, ReaderCommentSummary>> loadSummaries(
    List<ReaderCommentTarget> targets, {
    int previewLimit = 3,
  });

  /// Loads one cursor-based page of comments for [target].
  ///
  /// [sort] defaults to [ReaderCommentSort.hot]. [cursor] is a host-owned
  /// opaque continuation token. [pageSize] defaults to 20 and is a request
  /// hint; the host may return fewer entries.
  ///
  /// Every returned [ReaderComment.target] must equal [target], totals must be
  /// non-negative, and identifiers must be stable and unique within a page.
  /// When [ReaderCommentPage.hasMore] is true, its next cursor must be non-empty
  /// and different from [cursor]; when false, the next cursor must be null.
  Future<ReaderCommentPage> loadComments(
    ReaderCommentTarget target, {
    ReaderCommentSort sort = ReaderCommentSort.hot,
    String? cursor,
    int pageSize = 20,
  });
}
