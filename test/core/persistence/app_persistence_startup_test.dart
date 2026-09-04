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

  test('returns after metadata while content and file prewarm remain blocked', () async {
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

    await started[0].future;
    expect(openerCount, 1);
    release[0].complete();
    final persistence = await opening;
    await Future.wait(<Future<void>>[started[1].future, started[2].future]);
    expect(openerCount, 3);
    expect(await persistence.metadataRecords.read(id: 'missing', scope: localScope), isNull);
    release[1].complete();
    release[2].complete();
    await persistence.close();
  });

  test('consumes background open failures and retries on foreground use', () async {
    var contentAttempts = 0;
    var fileAttempts = 0;
    final persistence = await AppPersistence.openForTesting(
      dataRoot: root,
      registry: defaultRegistry,
      contentOpener: () async {
        contentAttempts++;
        if (contentAttempts == 1) throw StateError('content prewarm failed');
        return ContentObjectStore.open(root);
      },
      fileOpener: () async {
        fileAttempts++;
        if (fileAttempts == 1) throw StateError('file prewarm failed');
        return FileObjectStore.open(root);
      },
    );
    await Future<void>.delayed(Duration.zero);
    expect(await persistence.contentObjects.read('missing'), isNull);
    expect(await persistence.fileObjects.coverCacheUsageBytes(), 0);
    expect(contentAttempts, 2);
    expect(fileAttempts, 2);
    await persistence.close();
  });

  test('concurrent first content use shares one opener future', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    var attempts = 0;
    final persistence = await AppPersistence.openForTesting(
      dataRoot: root,
      registry: defaultRegistry,
      contentOpener: () async {
        attempts++;
        entered.complete();
        await release.future;
        return ContentObjectStore.open(root);
      },
    );
    await entered.future;
    final reads = List<Future<StoredContentObject?>>.generate(8, (_) => persistence.contentObjects.read('missing'));
    expect(attempts, 1);
    release.complete();
    expect(await Future.wait(reads), everyElement(isNull));
    expect(attempts, 1);
    await persistence.close();
  });

  test('normal open and close retain the public lifecycle boundary', () async {
    final persistence = await AppPersistence.open(dataRoot: root, registry: defaultRegistry);
    expect(persistence.metadataRecords.usesBackgroundExecutor, isTrue);
    expect(persistence.contentObjects.usesBackgroundExecutor, isTrue);
    expect(persistence.fileObjects.usesBackgroundExecutor, isTrue);
    expect(await persistence.metadataRecords.debugPragmaForTest('journal_mode'), 'wal');
    expect(await persistence.metadataRecords.debugPragmaForTest('synchronous'), 1);
    expect(await persistence.metadataRecords.debugPragmaForTest('foreign_keys'), 1);
    expect(await persistence.metadataRecords.debugPragmaForTest('busy_timeout'), 2000);
    expect(await persistence.contentObjects.debugPragmaForTest('journal_mode'), 'wal');
    expect(await persistence.contentObjects.debugPragmaForTest('synchronous'), 1);

    await persistence.close();
    await persistence.close();
    await expectLater(persistence.metadataRecords.read(id: 'missing', scope: localScope), throwsA(isA<PersistenceClosedError>()));
  });

  test('close waits for a started opener and closes its successful store', () async {
    final openerEntered = Completer<void>();
    final releaseOpener = Completer<void>();
    late ContentObjectStore openedStore;
    final persistence = await AppPersistence.openForTesting(
      dataRoot: root,
      registry: defaultRegistry,
      contentOpener: () async {
        openerEntered.complete();
        await releaseOpener.future;
        return openedStore = await ContentObjectStore.open(root);
      },
    );
    await openerEntered.future;

    var closed = false;
    final closing = persistence.close().whenComplete(() => closed = true);
    await Future<void>.delayed(Duration.zero);
    expect(closed, isFalse);

    releaseOpener.complete();
    await closing;
    await expectLater(openedStore.read('missing'), throwsStateError);
  });

  test('close does not retry a failed prewarm opener', () async {
    var attempts = 0;
    final persistence = await AppPersistence.openForTesting(
      dataRoot: root,
      registry: defaultRegistry,
      contentOpener: () {
        attempts++;
        return Future<ContentObjectStore>.error(StateError('prewarm failed'));
      },
    );
    await Future<void>.delayed(Duration.zero);

    await persistence.close();

    expect(attempts, 1);
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
