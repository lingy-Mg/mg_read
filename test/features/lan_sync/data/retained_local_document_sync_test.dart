import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/lan_sync/data/mg_read_lan_sync_gateway.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('backup conflict includes retained local copies; keepLocal preserves them and useSender restores their state', () async {
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
    final root = await Directory.systemTemp.createTemp('mgread-retained-local-conflict-');
    final senderRoot = Directory('${root.path}${Platform.pathSeparator}sender');
    final receiverRoot = Directory('${root.path}${Platform.pathSeparator}receiver');
    final senderLibrary = await ContentLibrary.open(dataRoot: senderRoot);
    final receiverLibrary = await ContentLibrary.open(dataRoot: receiverRoot);
    addTearDown(() async {
      await senderLibrary.close();
      await receiverLibrary.close();
      await root.delete(recursive: true);
    });

    await _addBook(senderLibrary, title: '备份书名', progressSeconds: 82, bookmarkExcerpt: '备份书签', coverMarker: 8);
    final receiverItem = await _addBook(receiverLibrary, title: '本机书名', progressSeconds: 19, bookmarkExcerpt: '本机书签', coverMarker: 3);
    final senderGateway = MgReadLanSyncGateway(senderLibrary, runtime);
    final receiverGateway = MgReadLanSyncGateway(receiverLibrary, runtime);
    final senderDocument = (await senderGateway.listLocalDocumentDescriptors()).single;
    final manifest = LanSyncManifest(
      plugins: const <LanSyncPluginDescriptor>[],
      shelfItems: const <LanSyncShelfItem>[],
      skippedShelfItems: 0,
      localDocuments: <LanSyncLocalDocumentDescriptor>[senderDocument],
    );

    await receiverLibrary.removeLibraryItem(receiverItem, LibraryRemovalPolicy.removeFromShelfKeepContent);
    expect(await receiverLibrary.listLocalDocuments(includeRetained: false), isEmpty);

    final preview = await receiverGateway.previewImport(manifest);
    expect(preview.localDocumentConflicts, hasLength(1));
    expect(preview.localDocumentConflicts.single.choice, LanSyncConflictChoice.keepLocal);
    expect(preview.localDocumentConflicts.single.localTitle, '本机书名（内容保留中）');

    await receiverGateway.importLocalDocument(senderDocument, const Stream<List<int>>.empty(), useSenderMetadata: false);
    expect(await receiverLibrary.listLocalDocuments(includeRetained: false), isEmpty);
    expect((await receiverLibrary.listLocalDocuments()).single.title, '本机书名');
    expect((await receiverLibrary.loadProgress(receiverItem) as LibraryReadingProgress).totalReadingSeconds, 19);
    expect((await receiverLibrary.loadBookmarks(receiverItem, ContentKind.novel)).whereType<LibraryBookmark>().single.excerpt, '本机书签');
    expect(await receiverLibrary.readLocalDocumentCover(receiverItem), <int>[137, 80, 78, 71, 13, 10, 26, 10, 3]);

    final senderOriginal = await senderGateway.openLocalDocumentOriginal(senderDocument);
    final senderCover = await senderGateway.openLocalDocumentCover(senderDocument);
    await receiverGateway.importLocalDocument(
      senderDocument,
      senderOriginal,
      useSenderMetadata: true,
      coverBytes: senderCover,
      coverMimeType: senderDocument.coverMimeType,
    );

    final restored = await receiverLibrary.listLocalDocuments(includeRetained: false);
    expect(restored.map((item) => item.id.value), contains(receiverItem.value));
    expect(restored.single.title, '备份书名');
    expect((await receiverLibrary.loadProgress(receiverItem) as LibraryReadingProgress).totalReadingSeconds, 82);
    expect((await receiverLibrary.loadBookmarks(receiverItem, ContentKind.novel)).whereType<LibraryBookmark>().single.excerpt, '备份书签');
    expect(await receiverLibrary.readLocalDocumentCover(receiverItem), <int>[137, 80, 78, 71, 13, 10, 26, 10, 8]);
  });
}

Future<LibraryItemId> _addBook(
  ContentLibrary library, {
  required String title,
  required int progressSeconds,
  required String bookmarkExcerpt,
  required int coverMarker,
}) async {
  const documentId = 'same-retained-document-id';
  final bytes = utf8.encode('第一章 起点\n\n同一份原书内容\n\n第二章 后续\n\n继续阅读');
  final staged = await library.prepareLocalImport(
    LocalImportInput(fileName: 'shared.txt', bytes: bytes.length, openRead: () => Stream<List<int>>.value(bytes)),
  );
  final committed = await library.commitLocalImport(staged.id, title: title, author: '作者', documentId: documentId);
  expect(committed.status, LocalImportStatus.succeeded, reason: committed.errorCode);
  final id = committed.itemId!;
  await library.updateLocalDocumentCover(id, bytes: <int>[137, 80, 78, 71, 13, 10, 26, 10, coverMarker]);
  final session = (await library.openLocalDocumentSession(id))!;
  final chapter = session.chapterAt(0)!;
  final body = await session.readChapter(chapter.id);
  final paragraphId = ((body['blocks']! as List).first as Map)['id']! as String;
  await library.saveLocalReadingProgress(
    LibraryReadingProgress(
      itemId: id,
      chapterId: chapter.id,
      paragraphId: paragraphId,
      characterOffset: 2,
      chapterIndex: 0,
      chapterFraction: .4,
      bookFraction: .25,
      updatedAtUtc: DateTime.utc(2026, 11, 4),
      totalReadingSeconds: progressSeconds,
    ),
    session.generation,
  );
  await library.saveLocalReadingBookmark(
    LibraryBookmark(
      id: 'bookmark-$title',
      itemId: id,
      chapterId: chapter.id,
      paragraphId: paragraphId,
      characterOffset: 2,
      chapterTitle: chapter.title,
      excerpt: bookmarkExcerpt,
      createdAtUtc: DateTime.utc(2026, 11, 4),
    ),
    session.generation,
  );
  await session.close();
  return id;
}
