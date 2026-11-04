import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/content_library/content_library.dart';

void main() {
  late Directory root;
  late ContentLibrary library;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mgread-local-recovery-');
    library = await ContentLibrary.open(dataRoot: root);
  });

  tearDown(() async {
    await library.close();
    await root.delete(recursive: true);
  });

  Future<LocalImportSnapshot> prepare(String name, String text) {
    final bytes = utf8.encode(text);
    return library.prepareLocalImport(LocalImportInput(fileName: name, bytes: bytes.length, openRead: () => Stream.value(bytes)));
  }

  test('one failed acquisition does not prevent a later import or publish a shell', () async {
    final bad = await library.prepareLocalImport(
      LocalImportInput(
        fileName: 'partial.txt',
        bytes: 40,
        openRead: () async* {
          yield utf8.encode('partial bytes');
          throw const FileSystemException('simulated source read failure');
        },
      ),
    );
    expect(bad.status, LocalImportStatus.failed);
    expect(bad.errorCode, 'import_failed');
    expect(await library.loadShelfProjection(), isEmpty);

    final good = await prepare('later.txt', '第一章\n\n正文可读。');
    expect(good.status, LocalImportStatus.awaitingConfirmation, reason: good.errorCode);
    final committed = await library.commitLocalImport(good.id);
    expect(committed.status, LocalImportStatus.succeeded, reason: committed.errorCode);
    expect(await library.loadShelfProjection(), hasLength(1));
    final jobs = await library.localImportJobs();
    expect(jobs.map((job) => job.status), containsAll([LocalImportStatus.failed, LocalImportStatus.succeeded]));
  });

  test('cancel during a blocked source stream closes the stream and leaves no shelf item', () async {
    final controller = StreamController<List<int>>();
    var sourceClosed = false;
    controller.onCancel = () => sourceClosed = true;
    final acquiring = Completer<LocalImportSnapshot>();
    final subscription = library.localImportEvents.listen((snapshot) {
      if (snapshot.status == LocalImportStatus.acquiring && !acquiring.isCompleted) acquiring.complete(snapshot);
    });
    final prepare = library.prepareLocalImport(LocalImportInput(fileName: 'slow.txt', openRead: () => controller.stream));
    try {
      final job = await acquiring.future.timeout(const Duration(seconds: 5));
      controller.add(utf8.encode('第一章'));
      await library.cancelLocalImport(job.id).timeout(const Duration(seconds: 5));
      final snapshot = await prepare.timeout(const Duration(seconds: 5));
      expect(snapshot.status, LocalImportStatus.cancelled);
      expect(sourceClosed, isTrue);
      expect(await library.loadShelfProjection(), isEmpty);
    } finally {
      await subscription.cancel();
      if (!controller.isClosed) await controller.close();
    }
  });

  test('prepared draft survives reopen, and reparse carries progress and bookmarks forward', () async {
    final initial = await prepare('saved.txt', '第一章\n\n第一段定位文本。\n\n第二章\n\n后续正文。');
    final committed = await library.commitLocalImport(initial.id);
    expect(committed.status, LocalImportStatus.succeeded, reason: committed.errorCode);
    final itemId = committed.itemId!;
    final session = (await library.openLocalDocumentSession(itemId))!;
    final firstChapter = session.chapterAt(0)!;
    final firstBody = await session.readChapter(firstChapter.id);
    final paragraph = (firstBody['blocks'] as List).cast<Map>().firstWhere((block) => (block['text'] as String).contains('定位文本'));
    final progress = LibraryReadingProgress(
      itemId: itemId,
      chapterId: firstChapter.id,
      paragraphId: paragraph['id'] as String,
      characterOffset: 3,
      chapterIndex: firstChapter.index,
      chapterFraction: .25,
      bookFraction: .2,
      updatedAtUtc: DateTime.utc(2026, 11, 4),
      totalReadingSeconds: 67,
    );
    final bookmark = LibraryBookmark(
      id: 'reparse-bookmark',
      itemId: itemId,
      chapterId: firstChapter.id,
      paragraphId: paragraph['id'] as String,
      characterOffset: 4,
      chapterTitle: firstChapter.title,
      excerpt: '定位文本',
      createdAtUtc: DateTime.utc(2026, 11, 4),
    );
    await library.saveLocalReadingProgress(progress, session.generation);
    await library.saveLocalReadingBookmark(bookmark, session.generation);
    await session.close();

    final draft = await prepare('kept.txt', '草稿内容也应跨重启保留。');
    await library.close();
    library = await ContentLibrary.open(dataRoot: root);
    final jobs = await library.localImportJobs();
    expect(jobs.any((job) => job.id == draft.id && job.status == LocalImportStatus.awaitingConfirmation), isTrue);
    final draftCommit = await library.commitLocalImport(draft.id);
    expect(draftCommit.status, LocalImportStatus.succeeded, reason: draftCommit.errorCode);

    final reparsed = await library.reparseLocalDocument(itemId, const LocalDocumentParseOptions(chapterRule: 'none'));
    expect(reparsed.status, LocalImportStatus.awaitingConfirmation, reason: reparsed.errorCode);
    final replaced = await library.commitLocalImport(reparsed.id);
    expect(replaced.status, LocalImportStatus.succeeded, reason: replaced.errorCode);
    final restoredProgress = await library.loadProgress(itemId) as LibraryReadingProgress;
    expect(restoredProgress.totalReadingSeconds, 67);
    expect(restoredProgress.bookFraction, .2);
    expect(restoredProgress.characterOffset, greaterThanOrEqualTo(0));
    final restoredBookmarks = (await library.loadBookmarks(itemId, ContentKind.novel)).whereType<LibraryBookmark>();
    expect(restoredBookmarks, hasLength(1));
    expect(restoredBookmarks.single.excerpt, '定位文本');

    final corrupt = await library.prepareLocalImport(
      LocalImportInput(fileName: 'corrupted.txt', openRead: () => Stream.value([0xff, 0xfe, 0x41])),
      options: const LocalDocumentParseOptions(encoding: 'utf-16le'),
    );
    expect(corrupt.status, LocalImportStatus.failed);
    expect(await library.getLibraryItem(corrupt.itemId ?? const LibraryItemId('absent')), isNull);
    expect((await library.loadShelfProjection()).length, 2);
  });
}
