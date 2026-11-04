/// Exercises a real TXT import, backup export and re-import through the
/// production Content Library and MgRead LAN gateway adapters.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/import_export/application/import_export_service.dart';
import 'package:mg_read/features/lan_sync/application/lan_sync_gateway.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_models.dart';

void main() {
  test('backup round trips original TXT, metadata, reading position and bookmark', () async {
    final root = await Directory.systemTemp.createTemp('mgread-local-backup-');
    addTearDown(() => root.delete(recursive: true));
    final source = await ContentLibrary.open(dataRoot: Directory('${root.path}/source'));
    final target = await ContentLibrary.open(dataRoot: Directory('${root.path}/target'));
    addTearDown(source.close);
    addTearDown(target.close);

    const original = '第一章 起点\n\n第一段正文。\n\n第二章 远方\n\n第二段正文。';
    final originalBytes = utf8.encode(original);
    final staged = await source.prepareLocalImport(
      LocalImportInput(fileName: '真实原件.txt', bytes: originalBytes.length, openRead: () => Stream.value(originalBytes)),
    );
    final committed = await source.commitLocalImport(staged.id, title: '用户书名', author: '作者甲');
    expect(committed.status, LocalImportStatus.succeeded, reason: committed.errorCode);
    final sourceId = committed.itemId!;
    final session = (await source.openLocalDocumentSession(sourceId))!;
    final chapter = session.chapterAt(0)!;
    final body = await session.readChapter(chapter.id);
    final paragraph = ((body['blocks']! as List).first as Map)['id']! as String;
    await source.saveLocalReadingProgress(
      LibraryReadingProgress(
        itemId: sourceId,
        chapterId: chapter.id,
        paragraphId: paragraph,
        characterOffset: 2,
        chapterIndex: 0,
        chapterFraction: .2,
        bookFraction: .1,
        updatedAtUtc: DateTime.utc(2026, 11, 4),
        totalReadingSeconds: 37,
      ),
      session.generation,
    );
    await source.saveLocalReadingBookmark(
      LibraryBookmark(
        id: 'bookmark-backup-1',
        itemId: sourceId,
        chapterId: chapter.id,
        paragraphId: paragraph,
        characterOffset: 2,
        chapterTitle: chapter.title,
        excerpt: '第一段正文',
        createdAtUtc: DateTime.utc(2026, 11, 4),
      ),
      session.generation,
    );
    await session.close();
    const senderCover = <int>[137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3];
    await source.updateLocalDocumentCover(sourceId, bytes: senderCover);

    final bundlePath = '${root.path}${Platform.pathSeparator}local-only.mgread';
    final picker = _FilePicker(bundlePath);
    final exporter = ImportExportService(_LocalOnlyGateway(source), picker);
    final exportPlan = await exporter.prepareExport();
    final descriptor = exportPlan.manifest.localDocuments.single;
    expect(descriptor.title, '用户书名');
    expect(descriptor.author, '作者甲');
    expect(descriptor.progress?.totalReadingSeconds, 37);
    expect(descriptor.bookmarks, hasLength(1));
    expect(
      await exporter.exportSelection(
        exportPlan,
        pluginIds: const <String>{},
        shelfItemIds: const <String>{},
        localDocumentIds: <String>{descriptor.documentId},
      ),
      isTrue,
    );

    final localCopy = await target.prepareLocalImport(
      LocalImportInput(fileName: '本机副本.txt', bytes: originalBytes.length, openRead: () => Stream.value(originalBytes)),
    );
    final localCopyResult = await target.commitLocalImport(localCopy.id, title: '本机自定义书名', author: '本机作者');
    expect(localCopyResult.status, LocalImportStatus.succeeded, reason: localCopyResult.errorCode);
    const receiverCover = <int>[137, 80, 78, 71, 13, 10, 26, 10, 9, 8, 7];
    await target.updateLocalDocumentCover(localCopyResult.itemId!, bytes: receiverCover);
    final importer = ImportExportService(_LocalOnlyGateway(target), picker);
    final importPlan = (await importer.pickImport())!;
    expect(importPlan.manifest.plugins, isEmpty);
    expect(importPlan.manifest.shelfItems, isEmpty);
    expect(importPlan.manifest.localDocuments.single.rawSha256, descriptor.rawSha256);
    expect(importPlan.preview.localDocumentConflicts, hasLength(1));
    final kept = await importer.importSelection(
      importPlan,
      pluginIds: const <String>{},
      shelfItemIds: const <String>{},
      localDocumentIds: <String>{descriptor.documentId},
      conflictChoices: const <String, LanSyncConflictChoice>{},
    );

    final imported = (await target.listLocalDocuments()).single;
    expect(imported.title, '本机自定义书名');
    expect(imported.author, '本机作者');
    expect(await target.openLocalDocumentOriginal(imported.id).expand((chunk) => chunk).toList(), originalBytes);
    expect(kept.keptLocal, 1);
    expect(await target.loadProgress(imported.id), isNull);
    expect(await target.loadBookmarks(imported.id, ContentKind.novel), isEmpty);
    expect(await target.readLocalDocumentCover(imported.id), receiverCover);

    final senderMetadataPlan = (await importer.pickImport())!;
    await importer.importSelection(
      senderMetadataPlan,
      pluginIds: const <String>{},
      shelfItemIds: const <String>{},
      localDocumentIds: <String>{descriptor.documentId},
      conflictChoices: <String, LanSyncConflictChoice>{descriptor.documentId: LanSyncConflictChoice.useSender},
    );
    expect((await target.listLocalDocuments()).single.title, '用户书名');
    expect(await target.readLocalDocumentCover(imported.id), senderCover);
    expect((await target.loadProgress(imported.id) as LibraryReadingProgress).totalReadingSeconds, 37);
    expect(await target.loadBookmarks(imported.id, ContentKind.novel), hasLength(1));
    expect((await target.getLibraryItem(imported.id))!.source.matchesLocalDocument(descriptor.documentId), isTrue);
  });
}

final class _LocalOnlyGateway implements LanSyncGateway, LanSyncLocalDocumentGateway {
  _LocalOnlyGateway(this.library);
  final ContentLibrary library;

  @override
  Future<LanSyncManifest> createManifest() async => LanSyncManifest(
    plugins: const <LanSyncPluginDescriptor>[],
    shelfItems: const <LanSyncShelfItem>[],
    skippedShelfItems: 0,
    localDocuments: await listLocalDocumentDescriptors(),
  );

  @override
  Future<List<LanSyncLocalDocumentDescriptor>> listLocalDocumentDescriptors() async {
    final result = <LanSyncLocalDocumentDescriptor>[];
    for (final item in await library.listLocalDocuments()) {
      final details = (await library.localDocumentDetails(item.id))!;
      final progress = await library.loadProgress(item.id);
      final bookmarks = await library.loadBookmarks(item.id, ContentKind.novel);
      final coverBytes = item.source.coverHash == null ? null : await library.readLocalDocumentCover(item.id);
      result.add(
        LanSyncLocalDocumentDescriptor(
          documentId: details.documentId,
          rawSha256: details.rawSha256,
          originalBytes: details.originalBytes,
          format: details.format.name,
          title: item.title,
          author: item.author,
          options: details.options.toJson(),
          coverSha256: coverBytes == null ? null : crypto.sha256.convert(coverBytes).toString(),
          coverBytes: coverBytes?.length,
          coverMimeType: coverBytes == null ? null : 'image/png',
          progress: progress is LibraryReadingProgress
              ? LanSyncReadingProgress(
                  chapterId: progress.chapterId,
                  paragraphId: progress.paragraphId,
                  characterOffset: progress.characterOffset,
                  chapterIndex: progress.chapterIndex,
                  chapterFraction: progress.chapterFraction,
                  bookFraction: progress.bookFraction,
                  updatedAtUtc: progress.updatedAtUtc,
                  totalReadingSeconds: progress.totalReadingSeconds,
                )
              : null,
          bookmarks: <LanSyncLocalBookmark>[
            for (final bookmark in bookmarks.whereType<LibraryBookmark>())
              LanSyncLocalBookmark(
                id: bookmark.id,
                chapterId: bookmark.chapterId,
                paragraphId: bookmark.paragraphId,
                characterOffset: bookmark.characterOffset,
                chapterTitle: bookmark.chapterTitle,
                excerpt: bookmark.excerpt,
                createdAtUtc: bookmark.createdAtUtc,
              ),
          ],
        ),
      );
    }
    return result;
  }

  @override
  Future<Stream<List<int>>> openLocalDocumentOriginal(LanSyncLocalDocumentDescriptor document) async {
    final item = (await library.listLocalDocuments()).singleWhere((item) => item.source.documentId == document.documentId);
    return library.openLocalDocumentOriginal(item.id);
  }

  @override
  Future<Stream<List<int>>?> openLocalDocumentCover(LanSyncLocalDocumentDescriptor document) async {
    final item = (await library.listLocalDocuments()).singleWhere((item) => item.source.documentId == document.documentId);
    final bytes = await library.readLocalDocumentCover(item.id);
    return bytes == null ? null : Stream<List<int>>.value(bytes);
  }

  @override
  Future<void> importLocalDocument(
    LanSyncLocalDocumentDescriptor document,
    Stream<List<int>> bytes, {
    required bool useSenderMetadata,
    Stream<List<int>>? coverBytes,
    String? coverMimeType,
  }) async {
    final staged = await library.prepareLocalImport(
      LocalImportInput(fileName: 'transfer.${document.format}', bytes: document.originalBytes, openRead: () => bytes),
      options: LocalDocumentParseOptions.fromJson(document.options),
    );
    expect(staged.status, LocalImportStatus.awaitingConfirmation, reason: staged.errorCode);
    final itemId = const LibraryItemId('transfer');
    final importedProgress = document.progress == null
        ? null
        : LibraryReadingProgress(
            itemId: itemId,
            chapterId: document.progress!.chapterId,
            paragraphId: document.progress!.paragraphId,
            characterOffset: document.progress!.characterOffset,
            chapterIndex: document.progress!.chapterIndex,
            chapterFraction: document.progress!.chapterFraction,
            bookFraction: document.progress!.bookFraction,
            updatedAtUtc: document.progress!.updatedAtUtc,
            totalReadingSeconds: document.progress!.totalReadingSeconds,
          );
    final bookmarks = <LibraryBookmark>[
      for (final bookmark in document.bookmarks)
        LibraryBookmark(
          id: bookmark.id,
          itemId: itemId,
          chapterId: bookmark.chapterId,
          paragraphId: bookmark.paragraphId,
          characterOffset: bookmark.characterOffset,
          chapterTitle: bookmark.chapterTitle,
          excerpt: bookmark.excerpt,
          createdAtUtc: bookmark.createdAtUtc,
        ),
    ];
    final result = await library.commitLocalImport(
      staged.id,
      title: document.title,
      author: document.author,
      documentId: document.documentId,
      progress: importedProgress,
      bookmarks: bookmarks,
      useSenderMetadata: useSenderMetadata,
      coverBytes: coverBytes == null ? null : await coverBytes.expand((chunk) => chunk).toList(),
      coverMimeType: coverMimeType ?? 'image/png',
    );
    expect(result.status, LocalImportStatus.succeeded, reason: result.errorCode);
  }

  @override
  Future<Stream<List<int>>> openPluginArchive(LanSyncPluginDescriptor plugin) async => const Stream.empty();
  @override
  Future<LanSyncImportPreview> previewImport(LanSyncManifest manifest, {bool force = false}) async {
    final localItems = await library.listLocalDocuments();
    final conflicts = <LanSyncLocalDocumentConflict>[];
    for (final document in manifest.localDocuments) {
      for (final item in localItems) {
        if ((await library.localDocumentDetails(item.id))?.rawSha256 == document.rawSha256) {
          conflicts.add(LanSyncLocalDocumentConflict(documentId: document.documentId, senderTitle: document.title, localTitle: item.title));
          break;
        }
      }
    }
    return LanSyncImportPreview(
      newItemCount: 0,
      conflicts: const <LanSyncBookConflict>[],
      blockedItemCount: 0,
      pluginPlans: const <String, LanSyncPluginPlanState>{},
      localDocumentConflicts: conflicts,
    );
  }

  @override
  Future<void> preparePluginImports(List<LanSyncPluginDescriptor> plugins, {Set<String> forceUpgradePluginIds = const <String>{}}) async {}
  @override
  Future<void> importPluginArchive(LanSyncPluginDescriptor plugin, Stream<List<int>> bytes) async {}
  @override
  Future<LanSyncPluginImportResult> finishPluginImports() async => const LanSyncPluginImportResult.empty();
  @override
  Future<void> cancelPluginImports() async {}
  @override
  Future<LanSyncApplyResult> applyImport({
    required LanSyncManifest manifest,
    required Map<String, LanSyncConflictChoice> conflictChoices,
    required Set<String> availablePluginIds,
    required LanSyncPluginImportResult pluginResult,
    bool force = false,
  }) async =>
      const LanSyncApplyResult(added: 0, updated: 0, keptLocal: 0, blocked: 0, pluginInstalled: 0, pluginSkipped: 0, pluginFailed: 0);
}

final class _FilePicker implements ImportExportFilePicker {
  const _FilePicker(this.path);
  final String path;
  @override
  Future<String?> chooseExportPath(String suggestedName) async => path;
  @override
  Future<bool> completeExport(String path) async => true;
  @override
  Future<String?> chooseImportPath() async => path;
}
