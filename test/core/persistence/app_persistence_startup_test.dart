import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/persistence/persistence.dart';

import 'persistence_testkit.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mg-read-app-persistence-');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('starts metadata, content, and file stores concurrently', () async {
    final started = List<Completer<void>>.generate(3, (_) => Completer<void>());
    final release = List<Completer<void>>.generate(3, (_) => Completer<void>());
    var openerCount = 0;

    Future<T> gated<T>(int index, Future<T> Function() open) async {
      openerCount++;
      started[index].complete();
      await release[index].future;
      return open();
    }

    final opening = AppPersistence.openForTesting(
      dataRoot: root,
      registry: defaultRegistry,
      metadataOpener: () => gated(0, () => PersistenceRecordStore.open(dataRoot: root, registry: defaultRegistry)),
      contentOpener: () => gated(1, () => ContentObjectStore.open(root)),
      fileOpener: () => gated(2, () => FileObjectStore.open(root)),
    );

    await Future.wait(started.map((completer) => completer.future));
    expect(openerCount, 3);
    for (final completer in release) {
      completer.complete();
    }

    final persistence = await opening;
    await persistence.close();
  });

  test('waits for all started stores and closes successful partial opens', () async {
    PersistenceRecordStore? metadata;
    ContentObjectStore? content;
    final initiatingError = StateError('file opener failed');

    final opening = AppPersistence.openForTesting(
      dataRoot: root,
      registry: defaultRegistry,
      metadataOpener: () async {
        metadata = await PersistenceRecordStore.open(dataRoot: root, registry: defaultRegistry);
        return metadata!;
      },
      contentOpener: () async {
        content = await ContentObjectStore.open(root);
        return content!;
      },
      fileOpener: () => Future<FileObjectStore>.error(initiatingError),
    );

    await expectLater(opening, throwsA(same(initiatingError)));
    expect(metadata, isNotNull);
    expect(content, isNotNull);
    await expectLater(metadata!.read(id: 'missing', scope: localScope), throwsA(isA<PersistenceClosedError>()));
    await expectLater(content!.read('missing'), throwsA(isA<StateError>()));
  });

  test('normal open and close retain the public lifecycle boundary', () async {
    final persistence = await AppPersistence.open(dataRoot: root, registry: defaultRegistry);
    expect(persistence.metadataRecords.usesBackgroundExecutor, isTrue);
    expect(persistence.contentObjects.usesBackgroundExecutor, isTrue);
    expect(persistence.fileObjects.usesBackgroundExecutor, isTrue);
    expect(await persistence.metadataRecords.debugPragmaForTest('journal_mode'), 'wal');
    expect(await persistence.metadataRecords.debugPragmaForTest('synchronous'), 1);
    expect(await persistence.contentObjects.debugPragmaForTest('journal_mode'), 'wal');
    expect(await persistence.contentObjects.debugPragmaForTest('synchronous'), 1);

    await persistence.close();
    await persistence.close();
    await expectLater(persistence.metadataRecords.read(id: 'missing', scope: localScope), throwsA(isA<PersistenceClosedError>()));
  });

  test('content object inventory, bounded delete, and explicit compaction reclaim storage', () async {
    final store = await ContentObjectStore.open(root);
    addTearDown(store.close);
    for (var index = 0; index < 6; index++) {
      await store.put(
        objectId: 'object-$index',
        contentKind: 'novel',
        objectType: 'text',
        generation: 1,
        payload: List<String>.filled(64 * 1024, String.fromCharCode(65 + index)).join(),
      );
    }
    final page = await store.listInfo(limit: 10);
    expect(page.objects, hasLength(6));
    expect(await store.deleteMany(page.objects.map((object) => object.objectId)), 6);
    final before = await store.storageStats();
    expect(before.reclaimableBytes, greaterThan(0));

    await store.compact();

    final after = await store.storageStats();
    expect(after.allocatedBytes, lessThan(before.allocatedBytes));
    expect(after.reclaimableBytes, 0);
  });

  test('global cover reads return while the mtime touch is gated', () async {
    final touchEntered = Completer<void>();
    final releaseTouch = Completer<void>();
    final store = await FileObjectStore.open(
      root,
      touchFileMtime: (file, modified) async {
        touchEntered.complete();
        await releaseTouch.future;
        await file.setLastModified(modified);
      },
    );
    addTearDown(store.close);
    const key = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    const bytes = <int>[1, 2, 3, 4];
    await store.commitGlobalCoverBytes(coverKey: key, bytes: bytes, mimeType: 'image/png', maxBytes: 100);

    final read = store.readGlobalCoverBytes(key);
    await touchEntered.future;
    expect(await read.timeout(const Duration(seconds: 1)), bytes);
    releaseTouch.complete();
  });

  test('global cover touches coalesce per key while one touch is pending', () async {
    final touchEntered = Completer<void>();
    final releaseTouch = Completer<void>();
    var touchCount = 0;
    final store = await FileObjectStore.open(
      root,
      touchFileMtime: (file, modified) async {
        touchCount++;
        touchEntered.complete();
        await releaseTouch.future;
        await file.setLastModified(modified);
      },
    );
    addTearDown(store.close);
    const key = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    const bytes = <int>[5, 6];
    await store.commitGlobalCoverBytes(coverKey: key, bytes: bytes, mimeType: 'image/png', maxBytes: 100);

    final reads = List<Future<List<int>?>>.generate(8, (_) => store.readGlobalCoverBytes(key));
    await touchEntered.future;
    expect(await Future.wait(reads), everyElement(bytes));
    expect(touchCount, 1);
    releaseTouch.complete();
    await Future<void>.delayed(Duration.zero);
    expect(touchCount, 1);
  });

  test('global cover touch backlog stays bounded', () async {
    final releaseTouches = Completer<void>();
    var touchCount = 0;
    final store = await FileObjectStore.open(
      root,
      touchFileMtime: (file, modified) async {
        touchCount++;
        await releaseTouches.future;
        await file.setLastModified(modified);
      },
    );
    addTearDown(store.close);
    const bytes = <int>[1];
    final keys = <String>[];
    for (var index = 0; index < 33; index += 1) {
      final key = index.toRadixString(16).padLeft(64, '0');
      keys.add(key);
      await store.commitGlobalCoverBytes(coverKey: key, bytes: bytes, mimeType: 'image/png', maxBytes: 100);
    }

    expect(await Future.wait(keys.map(store.readGlobalCoverBytes)), everyElement(bytes));
    expect(touchCount, 32);
    releaseTouches.complete();
  });

  test('mtime touch failures do not fail valid cover reads', () async {
    final store = await FileObjectStore.open(root, touchFileMtime: (file, modified) => Future<void>.error(StateError('touch failed')));
    addTearDown(store.close);
    const key = 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
    const bytes = <int>[7, 8, 9];
    await store.commitGlobalCoverBytes(coverKey: key, bytes: bytes, mimeType: 'image/png', maxBytes: 100);

    expect(await store.readGlobalCoverBytes(key), bytes);
    await Future<void>.delayed(Duration.zero);
  });
}
