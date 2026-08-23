import 'package:novel_reader_ui/novel_reader_ui.dart';

import 'package:mg_read/core/content_library/content_library.dart';

/// Text-reader state adapter that persists only semantic reading progress.
///
/// Preferences and bookmarks remain session-local until their corresponding
/// user-data contracts are added to Content Library. The progress record is
/// durable and uses the reader's chapter/paragraph/character anchor.
final class ContentLibraryTextReaderStateStore implements TextReaderStateStore {
  ContentLibraryTextReaderStateStore(this._library, {required this.itemId});

  final ContentLibrary _library;
  final LibraryItemId itemId;
  TextReaderPreferences? _preferences;
  final Map<String, ReaderBookmark> _bookmarks = <String, ReaderBookmark>{};
  Future<LibraryReadingProgress?>? _durableProgress;
  final Stopwatch _foregroundReading = Stopwatch();
  var _initialReadingSeconds = 0;

  @override
  Future<ReaderProgress?> loadProgress(String bookId) async {
    _requireBook(bookId);
    final progress = await _loadDurableProgress();
    if (progress == null) return null;
    return ReaderProgress(
      chapterId: progress.chapterId,
      paragraphId: progress.paragraphId,
      characterOffset: progress.characterOffset,
      chapterIndex: progress.chapterIndex,
      chapterFraction: progress.chapterFraction,
      bookFraction: progress.bookFraction,
    );
  }

  @override
  Future<void> saveProgress(String bookId, ReaderProgress progress) async {
    _requireBook(bookId);
    await _loadDurableProgress();
    await _library.readingProgress.save(
      LibraryReadingProgress(
        itemId: itemId,
        chapterId: progress.chapterId,
        paragraphId: progress.paragraphId,
        characterOffset: progress.characterOffset,
        chapterIndex: progress.chapterIndex,
        chapterFraction: progress.chapterFraction,
        bookFraction: progress.bookFraction,
        updatedAtUtc: DateTime.now().toUtc(),
        totalReadingSeconds:
            _initialReadingSeconds + _foregroundReading.elapsed.inSeconds,
      ),
    );
  }

  /// Counts only time while the reader is in the foreground.
  void onLifecycleChanged(ReaderLifecycleState state) {
    if (state == ReaderLifecycleState.foreground) {
      _foregroundReading.start();
    } else {
      _foregroundReading.stop();
    }
  }

  void finishSession() => _foregroundReading.stop();

  @override
  Future<TextReaderPreferences?> loadPreferences() async => _preferences;

  @override
  Future<void> savePreferences(TextReaderPreferences preferences) async {
    _preferences = preferences;
  }

  @override
  Future<List<ReaderBookmark>> loadBookmarks(String bookId) async {
    _requireBook(bookId);
    return List<ReaderBookmark>.unmodifiable(_bookmarks.values);
  }

  @override
  Future<void> addBookmark(ReaderBookmark bookmark) async {
    _requireBook(bookmark.bookId);
    _bookmarks[bookmark.id] = bookmark;
  }

  @override
  Future<void> removeBookmark(String bookId, String bookmarkId) async {
    _requireBook(bookId);
    _bookmarks.remove(bookmarkId);
  }

  void _requireBook(String bookId) {
    if (bookId != itemId.value) {
      throw ArgumentError.value(bookId, 'bookId', 'Unexpected reader book ID.');
    }
  }

  Future<LibraryReadingProgress?> _loadDurableProgress() {
    return _durableProgress ??= _library.readingProgress.load(itemId).then((
      progress,
    ) {
      _initialReadingSeconds = progress?.totalReadingSeconds ?? 0;
      _foregroundReading.start();
      return progress;
    });
  }
}
