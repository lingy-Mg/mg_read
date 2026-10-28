/// Comic progress, bookmarks and preferences mapped to app-owned persistence.
///
/// Content Library owns durable reading state; AppSettingsManager owns reader
/// preferences. This adapter validates book identity and owns no HTTP client or
/// reader-session cache. Preference updates flush before returning.
library;

import 'package:novel_reader_ui/novel_reader_ui.dart';

import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/core/settings/settings.dart';

/// Comic reader state adapter backed by Content Library and app settings.
final class ContentLibraryComicReaderStateStore implements ComicReaderStateStore {
  ContentLibraryComicReaderStateStore(this.library, {required this.itemId, this.settings});
  final ContentLibrary library;
  final LibraryItemId itemId;
  final AppSettingsManager? settings;
  @override
  Future<ComicReaderProgress?> loadProgress(String bookId) async {
    _check(bookId);
    final stored = await library.loadProgress(itemId);
    final p = stored is LibraryMangaReadingProgress ? stored : null;
    return p == null
        ? null
        : ComicReaderProgress(
            chapterId: p.chapterId,
            imageId: p.imageId,
            imageFraction: p.imageFraction,
            chapterIndex: p.chapterIndex,
            bookFraction: p.bookFraction,
          );
  }

  @override
  Future<void> saveProgress(String bookId, ComicReaderProgress p) {
    _check(bookId);
    return library.saveProgress(
      LibraryMangaReadingProgress(
        itemId: itemId,
        chapterId: p.chapterId,
        imageId: p.imageId,
        imageFraction: p.imageFraction,
        chapterIndex: p.chapterIndex,
        bookFraction: p.bookFraction,
        updatedAtUtc: DateTime.now().toUtc(),
      ),
    );
  }

  @override
  Future<ComicReaderPreferences?> loadPreferences() async {
    final raw = settings?.get(AppSettingKeys.comicReaderPreferences) ?? const <String, Object?>{};
    return raw.isEmpty
        ? null
        : ComicReaderPreferences(
            brightness: (raw['brightness'] as num?)?.toDouble() ?? 1,
            keepScreenOn: raw['keepScreenOn'] as bool? ?? true,
            immersiveMode: raw['immersiveMode'] as bool? ?? false,
            pageTurnShortcuts: raw['pageTurnShortcuts'] as bool? ?? true,
            pageTurnFraction: (raw['pageTurnFraction'] as num?)?.toDouble() ?? .9,
            pageTurnLayout: raw['pageTurnLayout'] == 'horizontal' ? ComicPageTurnLayout.horizontal : ComicPageTurnLayout.vertical,
            singleHandMode: raw['singleHandMode'] as bool? ?? false,
            imageSpacing: (raw['imageSpacing'] as num?)?.toDouble() ?? 0,
          ).normalized();
  }

  @override
  Future<void> savePreferences(ComicReaderPreferences p) async {
    final s = settings;
    if (s == null) return;
    await s.set(AppSettingKeys.comicReaderPreferences, <String, Object?>{
      'brightness': p.brightness,
      'keepScreenOn': p.keepScreenOn,
      'immersiveMode': p.immersiveMode,
      'pageTurnShortcuts': p.pageTurnShortcuts,
      'pageTurnFraction': p.pageTurnFraction,
      'pageTurnLayout': p.pageTurnLayout.name,
      'singleHandMode': p.singleHandMode,
      'imageSpacing': p.imageSpacing,
    });
    await s.flush();
  }

  @override
  Future<List<ComicReaderBookmark>> loadBookmarks(String bookId) async {
    _check(bookId);
    return [
      for (final b in await library.loadBookmarks(itemId, ContentKind.manga))
        if (b is LibraryMangaBookmark)
          ComicReaderBookmark(
            id: b.id,
            bookId: b.itemId.value,
            chapterId: b.chapterId,
            imageId: b.imageId,
            imageFraction: b.imageFraction,
            chapterTitle: '',
            createdAt: b.createdAtUtc,
          ),
    ];
  }

  @override
  Future<void> addBookmark(ComicReaderBookmark b) {
    _check(b.bookId);
    return library.saveBookmark(
      LibraryMangaBookmark(
        id: b.id,
        itemId: itemId,
        chapterId: b.chapterId,
        imageId: b.imageId,
        imageFraction: b.imageFraction,
        createdAtUtc: b.createdAt.toUtc(),
      ),
    );
  }

  @override
  Future<void> removeBookmark(String bookId, String id) {
    _check(bookId);
    return library.deleteBookmark(itemId, id);
  }

  void _check(String bookId) {
    if (bookId != itemId.value) throw ArgumentError.value(bookId, 'bookId');
  }
}
