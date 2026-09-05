/// Regression coverage for concurrent global cover commits and cache eviction.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/core/persistence/persistence.dart';

import '../diagnostics/diagnostics_testkit.dart';

void main() {
  late Directory root;
  late FileObjectStore store;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('mg-read-cover-concurrency-');
    store = await FileObjectStore.open(root);
  });
  tearDown(() async {
    await store.close();
    await root.delete(recursive: true);
  });

  test('concurrent commits of the same key preserve a complete file', () async {
    final key = 'a' * 64;
    final bytes = List<int>.filled(4096, 42);
    await Future.wait(
      List.generate(12, (_) => store.commitGlobalCoverBytes(coverKey: key, bytes: bytes, mimeType: 'image/png', maxBytes: 65536)),
    );
    expect(await store.readGlobalCoverBytes(key), bytes);
  });

  test('concurrent commits crossing capacity evict without duplicate deletion', () async {
    await Future.wait(
      List.generate(
        12,
        (index) => store.commitGlobalCoverBytes(
          coverKey: index.toRadixString(16).padLeft(64, '0'),
          bytes: List<int>.filled(4096, index),
          mimeType: 'image/png',
          maxBytes: 8192,
        ),
      ),
    );
    expect(await store.coverCacheUsageBytes(), lessThanOrEqualTo(8192));
  });

  test('clear ordered between commits leaves only the later cover', () async {
    final first = store.commitGlobalCoverBytes(coverKey: 'a' * 64, bytes: [1], mimeType: 'image/png', maxBytes: 100);
    final clear = store.clearCoverCache();
    final last = store.commitGlobalCoverBytes(coverKey: 'b' * 64, bytes: [2], mimeType: 'image/png', maxBytes: 100);
    await Future.wait<Object>([first, clear, last]);
    expect(await store.readGlobalCoverBytes('a' * 64), isNull);
    expect(await store.readGlobalCoverBytes('b' * 64), [2]);
  });

  test('file failure reports original error and stack and does not poison queue', () async {
    await store.close();
    final kit = DiagnosticsTestkit();
    addTearDown(kit.dispose);
    store = await FileObjectStore.open(root, diagnostics: kit.manager);
    final key = 'c' * 64;
    final folder = Directory('${root.path}/files/content-assets/global/$key');
    await folder.create(recursive: true);
    // A directory at the staging-file path deterministically rejects the write.
    final obstruction = Directory('${folder.path}/.cover.part');
    await obstruction.create();
    await expectLater(
      store.commitGlobalCoverBytes(coverKey: key, bytes: [3], mimeType: 'image/png', maxBytes: 100),
      throwsA(isA<FileSystemException>()),
    );
    final event = kit.sink.events.singleWhere((event) => event.eventName == 'persistence.operation.error');
    final console = const DiagnosticConsoleFormatter().format(event);
    expect(console, contains('errorLocation=FileObjectStore.commitGlobalCoverBytes'));
    expect(console, contains('osErrorCode='));
    expect(console, contains('.cover.part'));
    expect(console, contains('file_object_store.dart'));
    expect(console, contains('errorText='));
    await obstruction.delete();
    await store.commitGlobalCoverBytes(coverKey: key, bytes: [3], mimeType: 'image/png', maxBytes: 100);
    expect(await store.readGlobalCoverBytes(key), [3]);
  });
}
