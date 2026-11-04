import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/content_library/content_library.dart';

void main() {
  late Directory root;
  late ContentLibrary library;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mgread-local-capacity-');
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

  test('open reading sessions pin the custom cover across cover edits and GC', () async {
    final staged = await prepare('cover.txt', '正文');
    final committed = await library.commitLocalImport(staged.id);
    final id = committed.itemId!;
    const first = [137, 80, 78, 71, 13, 10, 26, 10, 1];
    const second = [137, 80, 78, 71, 13, 10, 26, 10, 2];
    await library.updateLocalDocumentCover(id, bytes: first);
    final session = (await library.openLocalDocumentSession(id))!;
    try {
      await library.updateLocalDocumentCover(id, bytes: second);
      await library.collectLocalDocumentGarbage();
      expect(await session.readCover(), first);
      expect(await library.readLocalDocumentCover(id), second);
    } finally {
      await session.close();
    }
    await library.collectLocalDocumentGarbage();
  });

  test('100-item cap permits duplicate and replacement without another slot; leases protect GC', () async {
    final remoteItems = <LibraryItemId>[];
    for (var i = 0; i < bookshelfMaxItemCount; i++) {
      final item = await library.addLibraryItem(
        BookshelfAddRequest(
          title: 'Remote $i',
          author: null,
          kind: ContentKind.novel,
          pluginId: 'capacity-source',
          pluginVersion: '1.0.0',
          remoteContentId: 'remote-$i',
        ),
      );
      remoteItems.add(item.id);
    }
    expect((await library.listLibrary(const LibraryQuery())).items, hasLength(bookshelfMaxItemCount));

    const initialText = '第一章\n\n容量上限仍允许稍后重试。';
    final initial = await prepare('capacity.txt', initialText);
    final blocked = await library.commitLocalImport(initial.id);
    expect(blocked.status, LocalImportStatus.needsAction);
    expect(blocked.errorCode, 'bookshelf_full');
    expect(await library.loadShelfProjection(), hasLength(bookshelfMaxItemCount));

    await library.close();
    library = await ContentLibrary.open(dataRoot: root);
    await library.removeLibraryItem(remoteItems.last, LibraryRemovalPolicy.removeIncludingUnreferencedContent);
    final added = await library.commitLocalImport(initial.id);
    expect(added.status, LocalImportStatus.succeeded, reason: added.errorCode);
    final localId = added.itemId!;
    expect(await library.loadShelfProjection(), hasLength(bookshelfMaxItemCount));

    final duplicate = await prepare('duplicate.txt', initialText);
    expect(duplicate.isDuplicate, isTrue);
    final deduplicated = await library.commitLocalImport(duplicate.id);
    expect(deduplicated.status, LocalImportStatus.succeeded, reason: deduplicated.errorCode);
    expect(deduplicated.itemId?.value, localId.value);
    expect(await library.loadShelfProjection(), hasLength(bookshelfMaxItemCount));

    final replacement = await library.reparseLocalDocument(localId, const LocalDocumentParseOptions(chapterRule: 'none'));
    expect(replacement.status, LocalImportStatus.awaitingConfirmation, reason: replacement.errorCode);
    final replaced = await library.commitLocalImport(replacement.id);
    expect(replaced.status, LocalImportStatus.succeeded, reason: replaced.errorCode);
    expect(replaced.itemId?.value, localId.value);
    expect(await library.loadShelfProjection(), hasLength(bookshelfMaxItemCount));

    final session = (await library.openLocalDocumentSession(localId))!;
    await library.removeLibraryItem(localId, LibraryRemovalPolicy.removeFromShelfKeepContent);
    expect((await library.getLibraryItem(localId))?.state, 'retained');
    final redownload = await prepare('reactivate.txt', initialText);
    expect(redownload.isDuplicate, isTrue);
    final reactivated = await library.commitLocalImport(redownload.id);
    expect(reactivated.status, LocalImportStatus.succeeded, reason: reactivated.errorCode);
    expect(reactivated.itemId?.value, localId.value);
    expect(await library.loadShelfProjection(), hasLength(bookshelfMaxItemCount));

    final bytesBeforeDelete = await library.localDocumentUsageBytes();
    await library.removeLibraryItem(localId, LibraryRemovalPolicy.removeIncludingUnreferencedContent);
    final bytesWithLease = await library.localDocumentUsageBytes();
    expect(bytesWithLease, greaterThan(0));
    expect(await session.readChapter(session.chapterAt(0)!.id), isNotEmpty);
    await session.close();
    await library.collectLocalDocumentGarbage();
    final bytesAfterRelease = await library.localDocumentUsageBytes();
    expect(bytesAfterRelease, lessThan(bytesBeforeDelete));
  });
}
