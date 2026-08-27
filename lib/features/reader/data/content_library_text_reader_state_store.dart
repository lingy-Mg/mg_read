import 'package:novel_reader_ui/novel_reader_ui.dart';

import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/core/settings/settings.dart';

/// Text-reader state adapter backed by the app's shared persistence owners.
///
/// Preferences are global and owned by [AppSettingsManager]; progress and
/// bookmarks are book-scoped and owned by [ContentLibrary]. This adapter never
/// opens a database or creates a second persistence owner.
final class ContentLibraryTextReaderStateStore implements TextReaderStateStore {
  ContentLibraryTextReaderStateStore(
    this._library, {
    required this.itemId,
    this.settings,
    LibraryReadingProgress? initialProgress,
    bool progressAlreadyLoaded = false,
  }) {
    if (progressAlreadyLoaded) {
      _durableProgress = Future<LibraryReadingProgress?>.value(initialProgress);
      _initialReadingSeconds = initialProgress?.totalReadingSeconds ?? 0;
    }
  }

  final ContentLibrary _library;
  final LibraryItemId itemId;
  final AppSettingsManager? settings;
  TextReaderPreferences? _preferences;
  final Map<String, ReaderBookmark> _bookmarks = <String, ReaderBookmark>{};
  Future<void>? _bookmarksLoaded;
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
        totalReadingSeconds: _initialReadingSeconds + _foregroundReading.elapsed.inSeconds,
      ),
    );
  }

  /// Counts only time while the reader is in the foreground.
  void startSession() => _foregroundReading.start();

  void onLifecycleChanged(ReaderLifecycleState state) {
    if (state == ReaderLifecycleState.foreground) {
      _foregroundReading.start();
    } else {
      _foregroundReading.stop();
    }
  }

  void finishSession() => _foregroundReading.stop();

  @override
  Future<TextReaderPreferences?> loadPreferences() async {
    final current = _preferences;
    if (current != null) return current;
    final manager = settings;
    if (manager == null) return null;
    final raw = manager.get(AppSettingKeys.readerPreferences);
    if (raw.isEmpty) return null;
    return _preferences = _preferencesFromMap(raw);
  }

  @override
  Future<void> savePreferences(TextReaderPreferences preferences) async {
    final normalized = preferences.normalized();
    _preferences = normalized;
    final manager = settings;
    if (manager == null) return;
    await manager.set(AppSettingKeys.readerPreferences, _preferencesToMap(normalized));
    await manager.flush();
  }

  @override
  Future<List<ReaderBookmark>> loadBookmarks(String bookId) async {
    _requireBook(bookId);
    await (_bookmarksLoaded ??= _loadBookmarks());
    return List<ReaderBookmark>.unmodifiable(_bookmarks.values);
  }

  @override
  Future<void> addBookmark(ReaderBookmark bookmark) async {
    _requireBook(bookmark.bookId);
    await (_bookmarksLoaded ??= _loadBookmarks());
    await _library.bookmarks.save(_toLibraryBookmark(bookmark));
    _bookmarks[bookmark.id] = bookmark;
  }

  @override
  Future<void> removeBookmark(String bookId, String bookmarkId) async {
    _requireBook(bookId);
    await (_bookmarksLoaded ??= _loadBookmarks());
    await _library.bookmarks.remove(itemId, bookmarkId);
    _bookmarks.remove(bookmarkId);
  }

  Future<void> _loadBookmarks() async {
    for (final bookmark in await _library.bookmarks.load(itemId)) {
      _bookmarks[bookmark.id] = _toReaderBookmark(bookmark);
    }
  }

  void _requireBook(String bookId) {
    if (bookId != itemId.value) {
      throw ArgumentError.value(bookId, 'bookId', 'Unexpected reader book ID.');
    }
  }

  Future<LibraryReadingProgress?> _loadDurableProgress() {
    return _durableProgress ??= _library.readingProgress.load(itemId).then((progress) {
      _initialReadingSeconds = progress?.totalReadingSeconds ?? 0;
      return progress;
    });
  }
}

LibraryBookmark _toLibraryBookmark(ReaderBookmark bookmark) => LibraryBookmark(
  id: bookmark.id,
  itemId: LibraryItemId(bookmark.bookId),
  chapterId: bookmark.chapterId,
  paragraphId: bookmark.paragraphId,
  characterOffset: bookmark.characterOffset,
  chapterTitle: bookmark.chapterTitle,
  excerpt: bookmark.excerpt,
  createdAtUtc: bookmark.createdAt.toUtc(),
);

ReaderBookmark _toReaderBookmark(LibraryBookmark bookmark) => ReaderBookmark(
  id: bookmark.id,
  bookId: bookmark.itemId.value,
  chapterId: bookmark.chapterId,
  paragraphId: bookmark.paragraphId,
  characterOffset: bookmark.characterOffset,
  chapterTitle: bookmark.chapterTitle,
  excerpt: bookmark.excerpt,
  createdAt: bookmark.createdAtUtc,
);

Map<String, Object?> _preferencesToMap(TextReaderPreferences value) => <String, Object?>{
  'theme': value.theme.name,
  'lastNonNightTheme': value.lastNonNightTheme.name,
  'background': value.background.name,
  'font': value.font.name,
  'customFontId': value.customFontId,
  'fontSize': value.fontSize,
  'fontWeight': value.fontWeight,
  'letterSpacing': value.letterSpacing,
  'lineHeight': value.lineHeight,
  'paragraphSpacing': value.paragraphSpacing,
  'firstLineIndent': value.firstLineIndent,
  'horizontalPadding': value.horizontalPadding,
  'topPadding': value.topPadding,
  'bottomPadding': value.bottomPadding,
  'brightness': value.brightness,
  'navigationMode': value.navigationMode.name,
  'singleHandMode': value.singleHandMode,
  'keepScreenOn': value.keepScreenOn,
  'pageAnimation': value.pageAnimation.name,
  'immersiveMode': value.immersiveMode,
  'showBookComments': value.showBookComments,
  'showChapterComments': value.showChapterComments,
  'showParagraphComments': value.showParagraphComments,
};

TextReaderPreferences _preferencesFromMap(Map<String, Object?> raw) {
  final defaults = TextReaderPreferences.defaults;
  T enumValue<T extends Enum>(List<T> values, Object? value, T fallback) {
    for (final candidate in values) {
      if (candidate.name == value) return candidate;
    }
    return fallback;
  }

  num number(String key, num fallback) => raw[key] is num ? raw[key]! as num : fallback;
  bool boolean(String key, bool fallback) => raw[key] is bool ? raw[key]! as bool : fallback;
  final customFontId = raw['customFontId'];
  return TextReaderPreferences(
    theme: enumValue(ReaderThemePreset.values, raw['theme'], defaults.theme),
    lastNonNightTheme: enumValue(ReaderThemePreset.values, raw['lastNonNightTheme'], defaults.lastNonNightTheme),
    background: enumValue(ReaderBackgroundPreset.values, raw['background'], defaults.background),
    font: enumValue(ReaderFontPreset.values, raw['font'], defaults.font),
    customFontId: customFontId is String ? customFontId : null,
    fontSize: number('fontSize', defaults.fontSize).toDouble(),
    fontWeight: number('fontWeight', defaults.fontWeight).toInt(),
    letterSpacing: number('letterSpacing', defaults.letterSpacing).toDouble(),
    lineHeight: number('lineHeight', defaults.lineHeight).toDouble(),
    paragraphSpacing: number('paragraphSpacing', defaults.paragraphSpacing).toDouble(),
    firstLineIndent: number('firstLineIndent', defaults.firstLineIndent).toInt(),
    horizontalPadding: number('horizontalPadding', defaults.horizontalPadding).toDouble(),
    topPadding: number('topPadding', defaults.topPadding).toDouble(),
    bottomPadding: number('bottomPadding', defaults.bottomPadding).toDouble(),
    brightness: number('brightness', defaults.brightness).toDouble(),
    navigationMode: enumValue(ReaderNavigationMode.values, raw['navigationMode'], defaults.navigationMode),
    singleHandMode: boolean('singleHandMode', defaults.singleHandMode),
    keepScreenOn: boolean('keepScreenOn', defaults.keepScreenOn),
    pageAnimation: enumValue(ReaderPageAnimation.values, raw['pageAnimation'], defaults.pageAnimation),
    immersiveMode: boolean('immersiveMode', defaults.immersiveMode),
    showBookComments: boolean('showBookComments', defaults.showBookComments),
    showChapterComments: boolean('showChapterComments', defaults.showChapterComments),
    showParagraphComments: boolean('showParagraphComments', defaults.showParagraphComments),
  ).normalized();
}
