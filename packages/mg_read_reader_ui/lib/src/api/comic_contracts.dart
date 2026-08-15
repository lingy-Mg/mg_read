import 'dart:async';
import 'dart:typed_data';

import 'comic_models.dart';
import 'models.dart';

/// Supplies comic metadata and progressively loaded image bytes.
///
/// Implementations own all networking, authentication, files, retries, and
/// persistent caching. The reader requests only visible and nearby images and
/// never constructs URLs or opens host storage directly.
abstract interface class ComicReaderDataSource {
  /// Loads lightweight metadata for [bookId].
  Future<ComicBookInfo> loadBookInfo(String bookId);

  /// Loads one cursor-based page of ordered comic chapters.
  Future<ComicChapterCatalogPage> loadChapterCatalog(
    String bookId, {
    String? cursor,
    int pageSize = 50,
  });

  /// Resolves one chapter by its zero-based full-book [index].
  Future<ComicChapterInfo> loadChapterAtIndex(String bookId, int index);

  /// Loads ordered image metadata for [chapterId].
  ///
  /// This does not require all image bytes to be ready. A remote host may wait
  /// only for the metadata/cache manifest needed for progressive loading.
  Future<ComicChapterContent> loadChapterContent(
    String bookId,
    String chapterId,
  );

  /// Loads encoded bytes for one stable image.
  ///
  /// The host may download and cache the image before completing this future.
  /// Calls may overlap and may be abandoned by a newer reader generation, so
  /// implementations must tolerate duplicate requests and late completion.
  Future<Uint8List> loadImageBytes(
    String bookId,
    String chapterId,
    String imageId,
  );
}

/// Persists comic-specific state without reusing text position models.
abstract interface class ComicReaderStateStore {
  /// Loads the latest semantic comic progress, or null when none exists.
  Future<ComicReaderProgress?> loadProgress(String bookId);

  /// Persists semantic comic [progress].
  Future<void> saveProgress(String bookId, ComicReaderProgress progress);

  /// Loads comic presentation preferences, or null when none exist.
  Future<ComicReaderPreferences?> loadPreferences();

  /// Persists normalized comic [preferences].
  Future<void> savePreferences(ComicReaderPreferences preferences);

  /// Loads comic bookmarks for [bookId].
  Future<List<ComicReaderBookmark>> loadBookmarks(String bookId);

  /// Persists a comic [bookmark].
  Future<void> addBookmark(ComicReaderBookmark bookmark);

  /// Removes [bookmarkId] when it exists.
  Future<void> removeBookmark(String bookId, String bookmarkId);
}

/// Optional notifications emitted by a comic reader session.
///
/// Comic sessions reuse lifecycle and failure categories while keeping their
/// book, chapter, progress, and bookmark models independent from text readers.
class ComicReaderObserver {
  /// Creates an observer whose callbacks are no-ops by default.
  const ComicReaderObserver();

  /// Called after a comic session successfully starts.
  FutureOr<void> onSessionStarted(String bookId) {}

  /// Called as the session ends with its latest semantic [progress].
  FutureOr<void> onSessionEnded(String bookId, ComicReaderProgress? progress) {}

  /// Called once for each normalized application lifecycle transition.
  FutureOr<void> onLifecycleChanged(
    ReaderLifecycleState state,
    ComicReaderProgress? progress,
  ) {}

  /// Called after the current comic [chapter] changes.
  FutureOr<void> onChapterChanged(ComicChapterInfo chapter) {}

  /// Called for a recoverable [failure].
  FutureOr<void> onFailure(ReaderFailure failure) {}

  /// Requests that the host close or otherwise leave the comic reader.
  FutureOr<void> onExitRequested(ComicReaderProgress? progress) {}
}
