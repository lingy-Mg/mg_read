/// Adapts a generation-pinned image-only EPUB to the existing comic reader.
/// The source owns one lease and a three-chapter metadata LRU, opens no paths
/// or network clients, and reads encoded pages only through ContentLibrary.
/// Immutable local image IDs opt into precise image-position persistence.
library;

import 'dart:collection';
import 'dart:typed_data';

import 'package:novel_reader_ui/novel_reader_ui.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/reader/application/reader_launch_request.dart';
import 'content_library_comic_reader_state_store.dart';
import 'local_comic_image_bytes.dart';

ComicReaderLaunchRequest createLocalComicReaderRequest(
  LocalDocumentReadingSession session,
  ContentLibrary library,
  AppSettingsManager? settings,
  List<int>? cover,
) {
  final store = ContentLibraryComicReaderStateStore(
    library,
    itemId: session.item.id,
    settings: settings,
    localGeneration: session.generation,
    localChapterTitle: (chapterId) => session.chapterById(chapterId)?.title ?? '',
  );
  return ComicReaderLaunchRequest(
    bookId: session.item.id.value,
    dataSource: _LocalComicSource(session),
    stateStore: store,
    observer: _LocalComicObserver(store),
    entryCoverBytes: cover,
    preparationKind: ReaderLaunchPreparationKind.persistent,
  );
}

final class _LocalComicObserver extends ComicReaderObserver {
  _LocalComicObserver(this.store);
  final ContentLibraryComicReaderStateStore store;
  @override
  void onSessionStarted(String bookId) => store.startLocalSession();
  @override
  void onSessionEnded(String bookId, ComicReaderProgress? progress) => store.finishLocalSession();
  @override
  void onLifecycleChanged(ReaderLifecycleState state, ComicReaderProgress? progress) => store.onLocalLifecycle(state);
}

final class _LocalComicSource
    implements
        ComicReaderDataSource,
        ComicReaderImageCacheStateDataSource,
        ComicReaderPreciseProgressDataSource,
        DisposableReaderDataSource {
  _LocalComicSource(this._session);
  final LocalDocumentReadingSession _session;
  final LinkedHashMap<String, List<({String id, String resource})>> _chapters = LinkedHashMap();
  Future<void>? _disposing;

  void _check(String bookId) {
    if (bookId != _session.item.id.value) throw ArgumentError.value(bookId, 'bookId');
    if (_disposing != null) throw StateError('Local comic session is closed.');
  }

  @override
  Future<ComicBookInfo> loadBookInfo(String bookId) async {
    _check(bookId);
    final item = _session.item;
    return ComicBookInfo(
      id: bookId,
      title: item.title,
      author: item.author,
      description: item.description,
      sourceName: '本地导入',
      sourceKind: ReaderBookSourceKind.local,
    );
  }

  ComicChapterInfo _info(int index) {
    final chapter = _session.chapterAt(index);
    if (chapter == null) throw RangeError.range(index, 0, _session.chapterCount - 1);
    final cached = _chapters[chapter.id];
    return ComicChapterInfo(
      id: chapter.id,
      title: chapter.title,
      index: index,
      availability: ReaderChapterAvailability.downloaded,
      manifestCached: true,
      imageCount: cached?.length,
      cachedImageCount: cached?.length,
    );
  }

  @override
  Future<ComicChapterCatalogPage> loadChapterCatalog(String bookId, {String? cursor, int pageSize = 50}) async {
    _check(bookId);
    final after = cursor == null ? -1 : int.tryParse(cursor);
    if (after == null || after < -1) throw ArgumentError.value(cursor, 'cursor');
    final chapters = _session.chapters(afterIndex: after, limit: pageSize);
    final hasMore = chapters.isNotEmpty && chapters.last.index + 1 < _session.chapterCount;
    return ComicChapterCatalogPage(
      items: [for (final chapter in chapters) _info(chapter.index)],
      total: _session.chapterCount,
      hasMore: hasMore,
      nextCursor: hasMore ? '${chapters.last.index}' : null,
    );
  }

  @override
  Future<ComicChapterInfo> loadChapterAtIndex(String bookId, int index) async {
    _check(bookId);
    return _info(index);
  }

  Future<List<({String id, String resource})>> _images(String chapterId) async {
    final cached = _chapters.remove(chapterId);
    if (cached != null) {
      _chapters[chapterId] = cached;
      return cached;
    }
    final chapter = await _session.readChapter(chapterId);
    final images = <({String id, String resource})>[];
    void visit(Object? nodes) {
      if (nodes is! List) return;
      for (final node in nodes.whereType<Map>()) {
        if (node['type'] == 'image' && node['id'] is String && node['resourceId'] is String) {
          images.add((id: node['id'] as String, resource: node['resourceId'] as String));
        }
        visit(node['children']);
      }
    }

    visit(chapter['blocks']);
    if (images.isEmpty) throw const LocalDocumentException('epub_no_images');
    if (_disposing != null) throw StateError('Local comic session is closed.');
    _chapters[chapterId] = images;
    while (_chapters.length > 3) {
      _chapters.remove(_chapters.keys.first);
    }
    return images;
  }

  @override
  Future<ComicChapterContent> loadChapterContent(String bookId, String chapterId) async {
    _check(bookId);
    final images = await _images(chapterId);
    return ComicChapterContent(
      chapterId: chapterId,
      title: _session.chapterById(chapterId)?.title ?? '',
      contentVersion: _session.generation,
      images: [for (var i = 0; i < images.length; i++) ComicImageInfo(id: images[i].id, index: i, contentVersion: _session.generation)],
    );
  }

  @override
  Future<Uint8List> loadImageBytes(String bookId, String chapterId, String imageId) async {
    _check(bookId);
    final image = (await _images(chapterId)).where((entry) => entry.id == imageId).firstOrNull;
    if (image == null) throw const LocalDocumentException('image_missing');
    final bytes = await _session.readResource(image.resource);
    if (bytes == null || bytes.isEmpty) throw const LocalDocumentException('image_missing');
    return prepareLocalComicImageBytes(Uint8List.fromList(bytes), mimeType: _session.resourceMimeType(image.resource));
  }

  @override
  Future<bool> isImagePersistentlyCached(String bookId, String chapterId, String imageId) async {
    _check(bookId);
    return (await _images(chapterId)).any((entry) => entry.id == imageId);
  }

  @override
  Future<void> dispose() => _disposing ??= _close();

  Future<void> _close() async {
    _chapters.clear();
    await _session.close();
  }
}
