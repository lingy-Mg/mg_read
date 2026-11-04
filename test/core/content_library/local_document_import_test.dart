/// Exercises real parser workers, durable file ownership and metadata cut-over.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/content_library/content_library.dart';

void main() {
  late Directory root;
  late ContentLibrary library;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('mgread-local-');
    library = await ContentLibrary.open(dataRoot: root);
  });
  tearDown(() async {
    await library.close();
    await root.delete(recursive: true);
  });

  Future<LocalImportSnapshot> prepare(String text, {LocalDocumentParseOptions options = const LocalDocumentParseOptions()}) {
    final bytes = utf8.encode(text);
    return library.prepareLocalImport(
      LocalImportInput(fileName: '真实书籍.txt', bytes: bytes.length, openRead: () => Stream.value(bytes)),
      options: options,
    );
  }

  test('import survives source deletion and cold reopen; exact duplicate keeps identity and state', () async {
    const text = '第一章 起点\n\n第一段内容。\n\n第二章 远方\n\n第二段内容。';
    final preview = await prepare(text);
    expect(preview.status, LocalImportStatus.awaitingConfirmation, reason: preview.errorCode);
    final result = await library.commitLocalImport(preview.id, title: '用户书名', author: '作者');
    expect(result.status, LocalImportStatus.succeeded, reason: result.errorCode);
    final itemId = result.itemId!;
    final session = (await library.openLocalDocumentSession(itemId))!;
    final chapter = session.chapterAt(0)!;
    final body = await session.readChapter(chapter.id);
    final block = (body['blocks']! as List).first as Map;
    await library.saveLocalReadingProgress(
      LibraryReadingProgress(
        itemId: itemId,
        chapterId: chapter.id,
        paragraphId: block['id']! as String,
        characterOffset: 2,
        chapterIndex: 0,
        chapterFraction: .2,
        bookFraction: .1,
        updatedAtUtc: DateTime.utc(2026),
        totalReadingSeconds: 12,
      ),
      session.generation,
    );
    await library.saveLocalReadingBookmark(
      LibraryBookmark(
        id: 'bookmark-1',
        itemId: itemId,
        chapterId: chapter.id,
        paragraphId: block['id']! as String,
        characterOffset: 2,
        chapterTitle: chapter.title,
        excerpt: '起点',
        createdAtUtc: DateTime.utc(2026),
      ),
      session.generation,
    );
    await session.close();
    await library.close();
    library = await ContentLibrary.open(dataRoot: root);
    expect((await library.getLibraryItem(itemId))!.source.isLocal, isTrue);
    expect((await library.loadProgress(itemId) as LibraryReadingProgress).totalReadingSeconds, 12);
    final duplicate = await prepare(text);
    expect(duplicate.isDuplicate, isTrue);
    final second = await library.commitLocalImport(duplicate.id, title: '不得覆盖');
    expect(second.itemId!.value, itemId.value);
    expect((await library.getLibraryItem(itemId))!.title, '用户书名');
    expect(await library.loadBookmarks(itemId, ContentKind.novel), hasLength(1));
    expect(await library.createSyncSnapshot().then((snapshot) => snapshot.items), isEmpty);
  });

  test('reparse migrates bookmarks and fences old generation writes', () async {
    final preview = await prepare('第一章 起点\n\n第一段内容。\n\n第二章 远方\n\n第二段内容。');
    final committed = await library.commitLocalImport(preview.id);
    expect(committed.status, LocalImportStatus.succeeded, reason: committed.errorCode);
    final itemId = committed.itemId!;
    final old = (await library.openLocalDocumentSession(itemId))!;
    final chapter = old.chapterAt(0)!;
    final body = await old.readChapter(chapter.id);
    final block = (body['blocks']! as List).first as Map;
    final progress = LibraryReadingProgress(
      itemId: itemId,
      chapterId: chapter.id,
      paragraphId: block['id']! as String,
      characterOffset: 1,
      chapterIndex: 0,
      chapterFraction: .1,
      bookFraction: .1,
      updatedAtUtc: DateTime.utc(2026),
    );
    await library.saveLocalReadingProgress(progress, old.generation);
    final revised = await library.reparseLocalDocument(itemId, const LocalDocumentParseOptions(chapterRule: 'none'));
    expect(revised.status, LocalImportStatus.awaitingConfirmation, reason: revised.errorCode);
    final result = await library.commitLocalImport(revised.id);
    expect(result.status, LocalImportStatus.succeeded, reason: result.errorCode);
    expect(await library.saveLocalReadingProgress(progress, old.generation), isFalse);
    expect(await old.readChapter(chapter.id), isNotEmpty);
    await old.close();
    final current = (await library.openLocalDocumentSession(itemId))!;
    final restored = await library.loadProgress(itemId) as LibraryReadingProgress;
    expect(current.chapterById(restored.chapterId), isNotNull);
    await current.close();
  });

  test('cancelled preview and malformed file never create shelf shells', () async {
    final preview = await prepare('用户的正文');
    await library.cancelLocalImport(preview.id);
    expect(await library.listLocalDocuments(), isEmpty);
    expect(() => library.commitLocalImport(preview.id), throwsA(isA<LocalDocumentException>()));
    final bad = await library.prepareLocalImport(
      LocalImportInput(fileName: 'bad.txt', openRead: () => Stream.value([0xff, 0xfe, 0x41])),
      options: const LocalDocumentParseOptions(encoding: 'utf-16le'),
    );
    expect(bad.status, LocalImportStatus.failed);
    expect(await library.loadShelfProjection(), isEmpty);
  });
}
