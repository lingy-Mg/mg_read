/// Larger real payloads must survive the complete application persistence path.
library;

import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/core/persistence/src/local_document_object_store.dart';
import 'package:mg_read/core/content_limits.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_models.dart';

void main() {
  late Directory root;
  late ContentLibrary library;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('mgread-content-capacity-');
    library = await ContentLibrary.open(dataRoot: root);
  });
  tearDown(() async {
    await library.close();
    await root.delete(recursive: true);
  });
  BookshelfAddRequest request(int i) => BookshelfAddRequest(
    author: null,
    title: '书籍 $i',
    kind: ContentKind.manga,
    pluginId: 'fixture',
    pluginVersion: '1.0.0',
    remoteContentId: 'book:$i',
    coverOrientation: CoverOrientation.portrait,
  );
  test('the default shelf accepts more than the old 100 books and sync retains them', () async {
    for (var i = 0; i < 101; i++) {
      await library.addLibraryItem(request(i));
    }
    expect((await library.createSyncSnapshot()).items, hasLength(101));
  });
  test('large covers and manga pages remain readable after reopening the library', () async {
    final item = await library.addLibraryItem(request(0));
    final bytes = Uint8List(50 * 1024 * 1024)..setRange(0, 8, [137, 80, 78, 71, 13, 10, 26, 10]);
    final key = CoverKey(pluginId: 'fixture', remoteContentId: 'book:0', coverUrl: Uri.parse('https://example.test/cover.png'));
    await library.saveCover(key: key, bytes: bytes, mimeType: 'image/png');
    await library.saveMangaImage(
      itemId: item.id,
      chapterId: 'chapter:1',
      pageId: 'page:1',
      contentVersion: 1,
      bytes: bytes,
      mimeType: 'image/png',
    );
    await library.close();
    library = await ContentLibrary.open(dataRoot: root);
    expect((await library.readCover(key))?.length, bytes.length);
    expect(
      (await library.readMangaImage(itemId: item.id, chapterId: 'chapter:1', pageId: 'page:1', contentVersion: 1))?.length,
      bytes.length,
    );
    final local = LocalDocumentObjectStore(root);
    final hash = 'a' * 64;
    await local.commitSmallOriginal(hash, bytes);
    expect((await local.readSmallOriginal(hash)).length, bytes.length);
    final text = utf8.encode('第一章\n\n正文');
    final staged = await library.prepareLocalImport(
      LocalImportInput(fileName: 'cover.txt', bytes: text.length, openRead: () => Stream.value(text)),
    );
    final imported = await library.commitLocalImport(staged.id, coverBytes: bytes);
    expect(imported.status, LocalImportStatus.succeeded, reason: imported.errorCode);
    await library.updateLocalDocumentCover(imported.itemId!, bytes: bytes);
    expect((await library.readLocalDocumentCover(imported.itemId!))?.length, bytes.length);
    expect(lanSyncMaxLocalCoverBytes, bytes.length);
    final oversized = Uint8List(ContentLimits.imageBytes + 1);
    await expectLater(library.saveCover(key: key, bytes: oversized), throwsArgumentError);
    await expectLater(
      library.saveMangaImage(
        itemId: item.id,
        chapterId: 'chapter:1',
        pageId: 'too-large',
        contentVersion: 1,
        bytes: oversized,
        mimeType: 'image/png',
      ),
      throwsArgumentError,
    );
    await expectLater(
      library.updateLocalDocumentCover(imported.itemId!, bytes: oversized),
      throwsA(isA<LocalDocumentException>().having((e) => e.code, 'code', 'cover_too_large')),
    );
  });
}
