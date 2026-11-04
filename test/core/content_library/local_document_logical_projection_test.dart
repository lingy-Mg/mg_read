/// Logical local-document chapter metadata stays separate from physical catalog anchors.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/content_library/content_library.dart';

void main() {
  late Directory root;
  late ContentLibrary library;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mgread-local-logical-');
    library = await ContentLibrary.open(dataRoot: root);
  });

  tearDown(() async {
    await library.close();
    await root.delete(recursive: true);
  });

  test('shelf projects logical chapter count and sequence while progress keeps physical anchor', () async {
    final text = '第一章 起点\n${'甲' * 20000}\n${'乙' * 20000}\n第二章 远方\n结尾内容';
    final bytes = utf8.encode(text);
    final preview = await library.prepareLocalImport(
      LocalImportInput(fileName: '续段测试.txt', bytes: bytes.length, openRead: () => Stream.value(bytes)),
    );
    expect(preview.status, LocalImportStatus.awaitingConfirmation, reason: preview.errorCode);
    final result = await library.commitLocalImport(preview.id);
    expect(result.status, LocalImportStatus.succeeded, reason: result.errorCode);
    final itemId = result.itemId!;

    final session = (await library.openLocalDocumentSession(itemId))!;
    expect(session.chapterCount, 3);
    expect(session.logicalChapterCount, 2);
    final continuation = session.chapterAt(1)!;
    final body = await session.readChapter(continuation.id);
    final block = (body['blocks']! as List).first as Map;
    await library.saveLocalReadingProgress(
      LibraryReadingProgress(
        itemId: itemId,
        chapterId: continuation.id,
        paragraphId: block['id']! as String,
        characterOffset: 10,
        chapterIndex: continuation.index,
        chapterFraction: .5,
        bookFraction: .25,
        updatedAtUtc: DateTime.utc(2026, 11, 4),
      ),
      session.generation,
    );
    await session.close();

    final item = (await library.getLibraryItem(itemId))!;
    expect(item.chapterCount, 2);
    final projection = (await library.loadShelfProjection()).single;
    expect(projection.sourceChapterCount, 2);
    expect(projection.chapterPosition, 0);
    expect(projection.catalogCount, 3);
    final saved = await library.loadProgress(itemId) as LibraryReadingProgress;
    expect(saved.chapterId, continuation.id);
    expect(saved.chapterIndex, 1);
  });
}
