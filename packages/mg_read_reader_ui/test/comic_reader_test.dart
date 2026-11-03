import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';
import 'package:novel_reader_ui/src/ui/comic/comic_image_cache.dart';
import 'package:novel_reader_ui/src/ui/comic/comic_image_tile.dart';
import 'package:novel_reader_ui/src/ui/comic/comic_chapter_preloader.dart';
import 'package:novel_reader_ui/src/ui/comic/comic_image_retry_coordinator.dart';
import 'package:novel_reader_ui/src/ui/reader_theme.dart';

part 'comic_reader_cache_part.dart';
part 'comic_reader_preferences_part.dart';
part 'comic_reader_width_part.dart';
part 'comic_reader_widgets_part.dart';

void main() {
  _registerComicCacheTests();
  _registerComicPreferencesTests();
  _registerComicWidthTests();
  _registerComicWidgetTests();
}

ComicImageInfo _image(String id, int? size) =>
    ComicImageInfo(id: id, index: 0, width: 1, height: 1, byteLength: size);

class _FakeComicSource implements ComicReaderDataSource {
  int imageCalls = 0;

  @override
  Future<ComicBookInfo> loadBookInfo(String bookId) async => ComicBookInfo(
    id: 'book',
    title: '漫画',
    sourceName: '测试漫画源',
    sourceUrl: Uri.parse('https://source.example/comics/book'),
  );

  @override
  Future<ComicChapterCatalogPage> loadChapterCatalog(
    String bookId, {
    String? cursor,
    int pageSize = 50,
  }) async => ComicChapterCatalogPage(
    items: const <ComicChapterInfo>[
      ComicChapterInfo(id: 'chapter-1', title: '第一章', index: 0, imageCount: 1),
    ],
    total: 1,
    hasMore: false,
  );

  @override
  Future<ComicChapterInfo> loadChapterAtIndex(String bookId, int index) async =>
      const ComicChapterInfo(
        id: 'chapter-1',
        title: '第一章',
        index: 0,
        imageCount: 1,
      );

  @override
  Future<ComicChapterContent> loadChapterContent(
    String bookId,
    String chapterId,
  ) async => ComicChapterContent(
    chapterId: chapterId,
    title: '第一章',
    images: <ComicImageInfo>[_image('image-1', null)],
  );

  @override
  Future<Uint8List> loadImageBytes(
    String bookId,
    String chapterId,
    String imageId,
  ) async {
    imageCalls++;
    final int size = switch (imageId) {
      'one' || 'two' => 2,
      'three' => 8,
      'too-large' => 8 * 1024 * 1024 + 1,
      _ => 1,
    };
    if (imageId == 'image-1') {
      return Uint8List.fromList(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
        ),
      );
    }
    return Uint8List(size);
  }
}

class _RetryingComicSource extends _FakeComicSource {
  _RetryingComicSource({required this.failures});

  final int failures;

  @override
  Future<Uint8List> loadImageBytes(
    String bookId,
    String chapterId,
    String imageId,
  ) async {
    imageCalls++;
    if (imageCalls <= failures) {
      throw StateError('temporary comic image failure');
    }
    return Uint8List.fromList(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      ),
    );
  }
}

class _BlockingComicSource extends _FakeComicSource {
  final List<String> started = <String>[];
  final Map<String, Completer<Uint8List>> _pending =
      <String, Completer<Uint8List>>{};
  int _active = 0;
  int peakActive = 0;

  @override
  Future<Uint8List> loadImageBytes(
    String bookId,
    String chapterId,
    String imageId,
  ) async {
    started.add(imageId);
    _active++;
    if (_active > peakActive) peakActive = _active;
    try {
      return await (_pending[imageId] ??= Completer<Uint8List>()).future;
    } finally {
      _active--;
    }
  }

  void complete(String imageId) {
    final Completer<Uint8List>? pending = _pending[imageId];
    if (pending != null && !pending.isCompleted) {
      pending.complete(Uint8List.fromList(<int>[1]));
    }
  }
}

class _DelayedChapterInfoComicSource extends _FakeComicSource {
  final Completer<ComicChapterInfo> _nextChapter =
      Completer<ComicChapterInfo>();

  void completeNextChapter() {
    if (_nextChapter.isCompleted) return;
    _nextChapter.complete(
      const ComicChapterInfo(
        id: 'chapter-2',
        title: '第二章',
        index: 1,
        imageCount: 1,
      ),
    );
  }

  @override
  Future<ComicChapterCatalogPage> loadChapterCatalog(
    String bookId, {
    String? cursor,
    int pageSize = 50,
  }) async => ComicChapterCatalogPage(
    items: const <ComicChapterInfo>[
      ComicChapterInfo(id: 'chapter-1', title: '第一章', index: 0, imageCount: 1),
    ],
    total: 2,
    nextCursor: 'remaining',
    hasMore: true,
  );

  @override
  Future<ComicChapterInfo> loadChapterAtIndex(String bookId, int index) =>
      index == 1
      ? _nextChapter.future
      : super.loadChapterAtIndex(bookId, index);
}

class _FailingNextChapterComicSource extends _FakeComicSource {
  int chapter2Calls = 0;

  @override
  Future<ComicChapterCatalogPage> loadChapterCatalog(
    String bookId, {
    String? cursor,
    int pageSize = 50,
  }) async => ComicChapterCatalogPage(
    items: const <ComicChapterInfo>[
      ComicChapterInfo(id: 'chapter-1', title: '第一章', index: 0, imageCount: 1),
      ComicChapterInfo(id: 'chapter-2', title: '第二章', index: 1, imageCount: 1),
    ],
    total: 2,
    hasMore: false,
  );

  @override
  Future<ComicChapterInfo> loadChapterAtIndex(String bookId, int index) async =>
      ComicChapterInfo(
        id: 'chapter-${index + 1}',
        title: '第${index + 1}章',
        index: index,
        imageCount: 1,
      );

  @override
  Future<ComicChapterContent> loadChapterContent(
    String bookId,
    String chapterId,
  ) async {
    if (chapterId == 'chapter-2') {
      chapter2Calls++;
      if (chapter2Calls < 3) throw StateError('temporary next chapter failure');
    }
    return ComicChapterContent(
      chapterId: chapterId,
      title: chapterId,
      images: <ComicImageInfo>[
        ComicImageInfo(id: '$chapterId-image-1', index: 0, width: 1, height: 1),
      ],
    );
  }
}

class _GatedFirstImageComicSource extends _FakeComicSource {
  final Completer<void> _firstImageRelease = Completer<void>();
  final List<String> requestedImages = <String>[];

  void releaseFirstImage() => _firstImageRelease.complete();

  @override
  Future<ComicChapterCatalogPage> loadChapterCatalog(
    String bookId, {
    String? cursor,
    int pageSize = 50,
  }) async => ComicChapterCatalogPage(
    items: const <ComicChapterInfo>[
      ComicChapterInfo(id: 'chapter-1', title: '第一章', index: 0, imageCount: 9),
    ],
    total: 1,
    hasMore: false,
  );

  @override
  Future<ComicChapterContent> loadChapterContent(
    String bookId,
    String chapterId,
  ) async => ComicChapterContent(
    chapterId: chapterId,
    title: '第一章',
    images: <ComicImageInfo>[
      for (var index = 0; index < 9; index++)
        ComicImageInfo(
          id: 'image-${index + 1}',
          index: index,
          width: 100,
          height: 1000,
        ),
    ],
  );

  @override
  Future<Uint8List> loadImageBytes(
    String bookId,
    String chapterId,
    String imageId,
  ) async {
    requestedImages.add(imageId);
    if (imageId == 'image-1') await _firstImageRelease.future;
    return Uint8List.fromList(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      ),
    );
  }
}

class _MultiChapterPreloadComicSource extends _FakeComicSource {
  final List<String> requestedContent = <String>[];
  final List<String> requestedImages = <String>[];

  @override
  Future<ComicChapterCatalogPage> loadChapterCatalog(
    String bookId, {
    String? cursor,
    int pageSize = 50,
  }) async => ComicChapterCatalogPage(
    items: <ComicChapterInfo>[
      for (var index = 0; index < 4; index++)
        ComicChapterInfo(
          id: 'chapter-${index + 1}',
          title: '第 ${index + 1} 章',
          index: index,
          imageCount: 1,
        ),
    ],
    total: 4,
    hasMore: false,
  );

  @override
  Future<ComicChapterInfo> loadChapterAtIndex(String bookId, int index) async =>
      ComicChapterInfo(
        id: 'chapter-${index + 1}',
        title: '第 ${index + 1} 章',
        index: index,
        imageCount: 1,
      );

  @override
  Future<ComicChapterContent> loadChapterContent(
    String bookId,
    String chapterId,
  ) async {
    requestedContent.add(chapterId);
    final int chapterNumber = int.parse(chapterId.split('-').last);
    return ComicChapterContent(
      chapterId: chapterId,
      title: chapterId,
      images: <ComicImageInfo>[
        ComicImageInfo(
          id: 'image-$chapterNumber',
          index: 0,
          width: 1,
          height: 1,
        ),
      ],
    );
  }

  @override
  Future<Uint8List> loadImageBytes(
    String bookId,
    String chapterId,
    String imageId,
  ) async {
    requestedImages.add('$chapterId/$imageId');
    return Uint8List.fromList(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      ),
    );
  }
}

class _MismatchedAspectComicSource extends _FakeComicSource {
  _MismatchedAspectComicSource(this._bytes);

  final Uint8List _bytes;

  @override
  Future<ComicChapterCatalogPage> loadChapterCatalog(
    String bookId, {
    String? cursor,
    int pageSize = 50,
  }) async => ComicChapterCatalogPage(
    items: <ComicChapterInfo>[
      ComicChapterInfo(id: 'chapter-1', title: '第一章', index: 0, imageCount: 2),
    ],
    total: 1,
    hasMore: false,
  );

  @override
  Future<ComicChapterContent> loadChapterContent(
    String bookId,
    String chapterId,
  ) async => ComicChapterContent(
    chapterId: 'chapter-1',
    title: '第一章',
    images: <ComicImageInfo>[
      ComicImageInfo(id: 'one', index: 0, width: 1, height: 1),
      ComicImageInfo(id: 'two', index: 1, width: 1, height: 1),
    ],
  );

  @override
  Future<Uint8List> loadImageBytes(
    String bookId,
    String chapterId,
    String imageId,
  ) async => _bytes;
}

class _TrackedAdjacentComicSource extends _FakeComicSource {
  final List<String> requestedChapters = <String>[];

  @override
  Future<ComicChapterCatalogPage> loadChapterCatalog(
    String bookId, {
    String? cursor,
    int pageSize = 50,
  }) async => ComicChapterCatalogPage(
    items: List<ComicChapterInfo>.generate(
      5,
      (int index) => ComicChapterInfo(
        id: 'chapter-${index + 1}',
        title: '第${index + 1}章',
        index: index,
        imageCount: 4,
      ),
    ),
    total: 5,
    hasMore: false,
  );

  @override
  Future<ComicChapterInfo> loadChapterAtIndex(String bookId, int index) async =>
      ComicChapterInfo(
        id: 'chapter-${index + 1}',
        title: '第${index + 1}章',
        index: index,
        imageCount: 4,
      );

  @override
  Future<ComicChapterContent> loadChapterContent(
    String bookId,
    String chapterId,
  ) {
    requestedChapters.add(chapterId);
    return Future<ComicChapterContent>.value(_content(chapterId));
  }

  ComicChapterContent _content(String chapterId) => ComicChapterContent(
    chapterId: chapterId,
    title: chapterId,
    images: List<ComicImageInfo>.generate(
      4,
      (int index) => ComicImageInfo(
        id: '$chapterId-image-${index + 1}',
        index: index,
        width: 1,
        height: 1,
      ),
    ),
  );
}

class _MemoryComicStateStore implements ComicReaderStateStore {
  _MemoryComicStateStore({this.progress});

  final ComicReaderProgress? progress;
  ComicReaderPreferences? preferences;

  @override
  Future<ComicReaderProgress?> loadProgress(String bookId) async => progress;
  @override
  Future<void> saveProgress(
    String bookId,
    ComicReaderProgress progress,
  ) async {}
  @override
  Future<ComicReaderPreferences?> loadPreferences() async => preferences;
  @override
  Future<void> savePreferences(ComicReaderPreferences value) async =>
      preferences = value;
  @override
  Future<List<ComicReaderBookmark>> loadBookmarks(String bookId) async =>
      const <ComicReaderBookmark>[];
  @override
  Future<void> addBookmark(ComicReaderBookmark bookmark) async {}
  @override
  Future<void> removeBookmark(String bookId, String bookmarkId) async {}
}

class _PagedComicCatalogSource extends _FakeComicSource {
  static const int chapterTotal = 120;

  final List<String?> catalogCursors = <String?>[];

  ComicChapterInfo _chapter(int index) => ComicChapterInfo(
    id: 'chapter-${index + 1}',
    title: '第 ${index + 1} 话',
    index: index,
    availability: ReaderChapterAvailability.downloaded,
    imageCount: 1,
    hasBeenRead: index < 75,
  );

  @override
  Future<ComicChapterCatalogPage> loadChapterCatalog(
    String bookId, {
    String? cursor,
    int pageSize = 50,
  }) async {
    catalogCursors.add(cursor);
    final int start = cursor == null ? 0 : int.parse(cursor);
    final int requestedEnd = start + pageSize;
    final int end = requestedEnd < chapterTotal ? requestedEnd : chapterTotal;
    return ComicChapterCatalogPage(
      items: <ComicChapterInfo>[
        for (int index = start; index < end; index++) _chapter(index),
      ],
      total: chapterTotal,
      hasMore: end < chapterTotal,
      nextCursor: end < chapterTotal ? '$end' : null,
    );
  }

  @override
  Future<ComicChapterInfo> loadChapterAtIndex(String bookId, int index) async =>
      _chapter(index);

  @override
  Future<ComicChapterContent> loadChapterContent(
    String bookId,
    String chapterId,
  ) async {
    final int index = int.parse(chapterId.substring('chapter-'.length)) - 1;
    return ComicChapterContent(
      chapterId: chapterId,
      title: _chapter(index).title,
      images: const <ComicImageInfo>[
        ComicImageInfo(id: 'image-1', index: 0, width: 1, height: 1),
      ],
    );
  }
}

class _RecordingComicObserver extends ComicReaderObserver {
  int exitCount = 0;
  int firstContentCount = 0;
  ComicFirstContentPresentation? firstPresentation;

  @override
  Future<void> onFirstContentPresented(
    ComicFirstContentPresentation presentation,
  ) async {
    firstContentCount++;
    firstPresentation = presentation;
  }

  @override
  Future<void> onExitRequested(ComicReaderProgress? progress) async {
    exitCount++;
  }
}

class _LongComicSource extends _FakeComicSource {
  @override
  Future<ComicChapterCatalogPage> loadChapterCatalog(
    String bookId, {
    String? cursor,
    int pageSize = 50,
  }) async => ComicChapterCatalogPage(
    items: const [
      ComicChapterInfo(id: 'chapter-1', title: '第一章', index: 0, imageCount: 40),
    ],
    total: 1,
    hasMore: false,
  );

  @override
  Future<ComicChapterContent> loadChapterContent(
    String bookId,
    String chapterId,
  ) async => ComicChapterContent(
    chapterId: chapterId,
    title: '第一章',
    images: [
      for (var i = 0; i < 40; i++) ComicImageInfo(id: 'image-$i', index: i),
    ],
  );

  @override
  Future<Uint8List> loadImageBytes(
    String bookId,
    String chapterId,
    String imageId,
  ) => super.loadImageBytes(bookId, chapterId, 'image-1');
}
