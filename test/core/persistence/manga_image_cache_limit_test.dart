import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/persistence/persistence.dart';

void main() {
  late Directory root;
  late FileObjectStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mg-read-manga-image-limit-');
  });

  tearDown(() async {
    await store.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('limits each manga independently without a global byte limit', () async {
    store = await FileObjectStore.open(root, mangaImageMaxBytesPerItem: 6);

    await _save(store, itemId: _itemA, pageId: 'a-1', bytes: <int>[1, 2, 3, 4]);
    await _save(store, itemId: _itemA, pageId: 'a-2', bytes: <int>[5, 6, 7, 8]);
    await _save(store, itemId: _itemB, pageId: 'b-1', bytes: <int>[9, 10, 11, 12]);

    expect(await _read(store, itemId: _itemA, pageId: 'a-1'), isNull);
    expect(await _read(store, itemId: _itemA, pageId: 'a-2'), <int>[5, 6, 7, 8]);
    expect(await _read(store, itemId: _itemB, pageId: 'b-1'), <int>[9, 10, 11, 12]);
    expect(await store.mangaImageCacheUsageBytes(), 8, reason: 'two manga may exceed one manga byte limit in aggregate');
  });

  test('allows hysteresis headroom before pruning back to the per-manga target', () async {
    store = await FileObjectStore.open(root, mangaImageMaxBytesPerItem: 10);

    await _save(store, itemId: _itemA, pageId: 'a-1', bytes: <int>[1, 2, 3, 4, 5, 6]);
    await _save(store, itemId: _itemA, pageId: 'a-2', bytes: <int>[7, 8, 9, 10, 11, 12]);
    expect(await store.mangaImageCacheUsageBytes(), 12, reason: 'the soft limit permits bounded overflow without pruning churn');

    await _save(store, itemId: _itemA, pageId: 'a-3', bytes: <int>[13, 14]);
    expect(await _read(store, itemId: _itemA, pageId: 'a-1'), isNull);
    expect(await _read(store, itemId: _itemA, pageId: 'a-2'), <int>[7, 8, 9, 10, 11, 12]);
    expect(await _read(store, itemId: _itemA, pageId: 'a-3'), <int>[13, 14]);
    expect(await store.mangaImageCacheUsageBytes(), 8);
  });

  test('a cache hit refreshes LRU only inside its manga', () async {
    final touched = Completer<void>();
    store = await FileObjectStore.open(
      root,
      mangaImageMaxBytesPerItem: 6,
      touchFileMtime: (file, modified) async {
        await file.setLastModified(modified);
        if (!touched.isCompleted) touched.complete();
      },
    );
    await _save(store, itemId: _itemA, pageId: 'a-1', bytes: <int>[1, 2, 3]);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await _save(store, itemId: _itemA, pageId: 'a-2', bytes: <int>[4, 5, 6]);

    expect(await _read(store, itemId: _itemA, pageId: 'a-1'), <int>[1, 2, 3]);
    await touched.future;
    await _save(store, itemId: _itemA, pageId: 'a-3', bytes: <int>[7, 8, 9]);

    expect(await _read(store, itemId: _itemA, pageId: 'a-1'), <int>[1, 2, 3]);
    expect(await _read(store, itemId: _itemA, pageId: 'a-2'), isNull);
    expect(await _read(store, itemId: _itemA, pageId: 'a-3'), <int>[7, 8, 9]);
  });

  test('coalesces repeated LRU touches for the same image', () async {
    final firstTouch = Completer<void>();
    var touchCount = 0;
    store = await FileObjectStore.open(
      root,
      mangaImageMaxBytesPerItem: 10,
      touchFileMtime: (file, modified) async {
        touchCount++;
        await file.setLastModified(modified);
        if (!firstTouch.isCompleted) firstTouch.complete();
      },
    );
    await _save(store, itemId: _itemA, pageId: 'a-1', bytes: <int>[1, 2, 3]);

    expect(await _read(store, itemId: _itemA, pageId: 'a-1'), <int>[1, 2, 3]);
    await firstTouch.future;
    expect(await _read(store, itemId: _itemA, pageId: 'a-1'), <int>[1, 2, 3]);
    await Future<void>.delayed(Duration.zero);

    expect(touchCount, 1);
  });
}

const String _itemA = 'manga-item-alpha-0001';
const String _itemB = 'manga-item-bravo-0002';

Future<void> _save(FileObjectStore store, {required String itemId, required String pageId, required List<int> bytes}) =>
    store.commitMangaImage(itemId: itemId, chapterId: 'chapter-1', pageId: pageId, contentVersion: 1, bytes: bytes, mimeType: 'image/png');

Future<List<int>?> _read(FileObjectStore store, {required String itemId, required String pageId}) =>
    store.readMangaImage(itemId: itemId, chapterId: 'chapter-1', pageId: pageId, contentVersion: 1);
