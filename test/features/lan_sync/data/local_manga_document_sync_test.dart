import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/lan_sync/data/mg_read_lan_sync_gateway.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('manga backup preserves image progress and bookmarks through retained keepLocal/useSender', () async {
    const runtimeChannel = MethodChannel('mgread_plugin_runtime/android');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(runtimeChannel, (call) async {
      if (call.method == 'dispose') return null;
      expect(call.method, 'invoke');
      return jsonEncode(<String, Object?>{'ok': true, 'result': <Object?>[]});
    });
    final runtime = PluginRuntime.androidForTesting();
    addTearDown(() async {
      await runtime.debugDispose();
      messenger.setMockMethodCallHandler(runtimeChannel, null);
    });

    final root = await Directory.systemTemp.createTemp('mgread-local-manga-sync-');
    final senderLibrary = await ContentLibrary.open(dataRoot: Directory('${root.path}/sender'));
    final receiverLibrary = await ContentLibrary.open(dataRoot: Directory('${root.path}/receiver'));
    addTearDown(() async {
      await senderLibrary.close();
      await receiverLibrary.close();
      await root.delete(recursive: true);
    });

    final bytes = _comicEpubBytes();
    final senderItem = await _importComic(senderLibrary, bytes, title: '备份漫画');
    final receiverItem = await _importComic(receiverLibrary, bytes, title: '本机漫画');
    final senderSession = (await senderLibrary.openLocalDocumentSession(senderItem))!;
    final receiverSession = (await receiverLibrary.openLocalDocumentSession(receiverItem))!;
    expect(senderSession.item.kind, ContentKind.manga);
    expect(senderSession.readingKind?.name, 'comic');
    final senderImages = _imageIds(await senderSession.readChapter(senderSession.chapterAt(0)!.id));
    final receiverImages = _imageIds(await receiverSession.readChapter(receiverSession.chapterAt(0)!.id));
    final targetImageId = senderImages[1];
    expect(receiverImages, senderImages);

    final now = DateTime.utc(2026, 11, 4, 12);
    expect(
      await senderLibrary.saveLocalMangaReadingProgress(
        LibraryMangaReadingProgress(
          itemId: senderItem,
          chapterId: senderSession.chapterAt(0)!.id,
          imageId: targetImageId,
          imageFraction: .62,
          chapterIndex: 0,
          bookFraction: .54,
          updatedAtUtc: now,
          readingSeconds: 240,
        ),
        senderSession.generation,
      ),
      isTrue,
    );
    expect(
      await senderLibrary.saveLocalMangaBookmark(
        LibraryMangaBookmark(
          id: 'manga-mark',
          itemId: senderItem,
          chapterId: senderSession.chapterAt(0)!.id,
          imageId: targetImageId,
          imageFraction: .37,
          createdAtUtc: now,
        ),
        senderSession.generation,
      ),
      isTrue,
    );
    expect(
      await senderLibrary.saveLocalMangaReadingProgress(
        LibraryMangaReadingProgress(
          itemId: senderItem,
          chapterId: senderSession.chapterAt(0)!.id,
          imageId: targetImageId,
          imageFraction: .1,
          chapterIndex: 0,
          bookFraction: .1,
          updatedAtUtc: now,
        ),
        'stale-generation',
      ),
      isFalse,
    );
    expect(
      await receiverLibrary.saveLocalMangaReadingProgress(
        LibraryMangaReadingProgress(
          itemId: receiverItem,
          chapterId: receiverSession.chapterAt(0)!.id,
          imageId: receiverImages.first,
          imageFraction: .2,
          chapterIndex: 0,
          bookFraction: .2,
          updatedAtUtc: now,
          readingSeconds: 90,
        ),
        receiverSession.generation,
      ),
      isTrue,
    );
    expect(
      await receiverLibrary.saveLocalMangaBookmark(
        LibraryMangaBookmark(
          id: 'local-manga-mark',
          itemId: receiverItem,
          chapterId: receiverSession.chapterAt(0)!.id,
          imageId: receiverImages.first,
          imageFraction: .15,
          createdAtUtc: now,
        ),
        receiverSession.generation,
      ),
      isTrue,
    );
    await senderSession.close();
    await receiverSession.close();

    final senderGateway = MgReadLanSyncGateway(senderLibrary, runtime);
    final receiverGateway = MgReadLanSyncGateway(receiverLibrary, runtime);
    final senderDescriptor = (await senderGateway.listLocalDocumentDescriptors()).single;
    expect(senderDescriptor.readingKind, LanSyncLocalReadingKind.comic);
    expect(senderDescriptor.progress, isNull);
    expect(senderDescriptor.bookmarks, isEmpty);
    expect(senderDescriptor.mangaProgress?.imageId, targetImageId);
    expect(senderDescriptor.mangaProgress?.imageFraction, .62);
    expect(senderDescriptor.mangaBookmarks.single.imageId, targetImageId);
    expect(LanSyncLocalDocumentDescriptor.fromJson(senderDescriptor.toJson()).mangaProgress?.imageFraction, .62);

    final manifest = LanSyncManifest(
      plugins: const <LanSyncPluginDescriptor>[],
      shelfItems: const <LanSyncShelfItem>[],
      skippedShelfItems: 0,
      localDocuments: <LanSyncLocalDocumentDescriptor>[senderDescriptor],
    );
    await receiverLibrary.removeLibraryItem(receiverItem, LibraryRemovalPolicy.removeFromShelfKeepContent);
    final preview = await receiverGateway.previewImport(manifest);
    expect(preview.localDocumentConflicts, hasLength(1));
    expect(preview.localDocumentConflicts.single.choice, LanSyncConflictChoice.keepLocal);
    await receiverGateway.importLocalDocument(senderDescriptor, const Stream<List<int>>.empty(), useSenderMetadata: false);
    expect(await receiverLibrary.listLocalDocuments(includeRetained: false), isEmpty);
    expect((await receiverLibrary.loadProgress(receiverItem)), isA<LibraryMangaReadingProgress>());
    expect((await receiverLibrary.loadProgress(receiverItem) as LibraryMangaReadingProgress).imageFraction, .2);
    expect((await receiverLibrary.loadBookmarks(receiverItem, ContentKind.manga)).single, isA<LibraryMangaBookmark>());

    final original = await senderGateway.openLocalDocumentOriginal(senderDescriptor);
    await receiverGateway.importLocalDocument(senderDescriptor, original, useSenderMetadata: true);
    final restored = await receiverLibrary.listLocalDocuments(includeRetained: false);
    expect(restored.single.id.value, receiverItem.value);
    expect(restored.single.kind, ContentKind.manga);
    final restoredProgress = await receiverLibrary.loadProgress(receiverItem) as LibraryMangaReadingProgress;
    expect(restoredProgress.imageId, targetImageId);
    expect(restoredProgress.imageFraction, .62);
    expect(restoredProgress.bookFraction, .54);
    expect(restoredProgress.readingSeconds, 240);
    final restoredBookmarks = await receiverLibrary.loadBookmarks(receiverItem, ContentKind.manga);
    expect(restoredBookmarks, hasLength(1));
    expect(restoredBookmarks.single, isA<LibraryMangaBookmark>());
    final restoredBookmark = restoredBookmarks.single as LibraryMangaBookmark;
    expect(restoredBookmark.id, 'manga-mark');
    expect(restoredBookmark.imageId, targetImageId);
    expect(restoredBookmark.imageFraction, .37);
  });
}

Future<LibraryItemId> _importComic(ContentLibrary library, List<int> bytes, {required String title}) async {
  final staged = await library.prepareLocalImport(
    LocalImportInput(fileName: 'comic.epub', bytes: bytes.length, openRead: () => Stream<List<int>>.value(bytes)),
  );
  expect(staged.status, LocalImportStatus.awaitingConfirmation);
  final committed = await library.commitLocalImport(staged.id, title: title, documentId: 'shared-comic-document-id');
  expect(committed.status, LocalImportStatus.succeeded, reason: committed.errorCode);
  return committed.itemId!;
}

List<String> _imageIds(Map<String, Object?> chapter) => <String>[
  for (final block in chapter['blocks']! as List)
    if (block is Map && block['type'] == 'image') block['id']! as String,
];

List<int> _comicEpubBytes() {
  final archive = Archive();
  void add(String path, String value) => archive.addFile(ArchiveFile.bytes(path, utf8.encode(value)));
  void addBytes(String path, List<int> value) => archive.addFile(ArchiveFile.bytes(path, value));
  add('mimetype', 'application/epub+zip');
  add(
    'META-INF/container.xml',
    '<?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
  );
  add(
    'OPS/package.opf',
    '<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="book">comic-id</dc:identifier><dc:title>Local Comic</dc:title></metadata><manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="one" href="one.xhtml" media-type="application/xhtml+xml"/><item id="image1" href="image1.png" media-type="image/png"/><item id="image2" href="image2.png" media-type="image/png"/><item id="image3" href="image3.png" media-type="image/png"/></manifest><spine><itemref idref="one"/></spine></package>',
  );
  add(
    'OPS/nav.xhtml',
    '<html xmlns="http://www.w3.org/1999/xhtml"><body><nav epub:type="toc" xmlns:epub="http://www.idpf.org/2007/ops"><ol><li><a href="one.xhtml">第一话</a></li></ol></nav></body></html>',
  );
  add(
    'OPS/one.xhtml',
    '<html xmlns="http://www.w3.org/1999/xhtml"><body><img src="image1.png"/><img src="image2.png"/><img src="image3.png"/></body></html>',
  );
  const png = <int>[137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 0];
  addBytes('OPS/image1.png', png);
  addBytes('OPS/image2.png', png);
  addBytes('OPS/image3.png', png);
  return ZipEncoder().encode(archive);
}
