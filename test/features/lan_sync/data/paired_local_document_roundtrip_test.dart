/// Real paired HTTP transfer of imported TXT originals and reading state.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/lan_sync/application/lan_sync_gateway.dart';
import 'package:mg_read/features/lan_sync/data/paired_sync_transport.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_models.dart';
import 'package:mg_read/features/lan_sync/domain/paired_device_models.dart';

import 'paired_sync_cross_device_support.dart';

void main() {
  test('paired session transfers local TXT originals in both directions with positions and bookmarks', () async {
    final networks = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
    final address = networks.expand((network) => network.addresses).where((item) => _privateIpv4(item.address)).firstOrNull;
    if (address == null) markTestSkipped('No private IPv4 interface is available for the paired HTTP test.');

    final root = await Directory.systemTemp.createTemp('mgread-paired-local-books-');
    addTearDown(() => root.delete(recursive: true));
    final windowsLibrary = await ContentLibrary.open(dataRoot: Directory('${root.path}/windows'));
    final androidLibrary = await ContentLibrary.open(dataRoot: Directory('${root.path}/android'));
    addTearDown(windowsLibrary.close);
    addTearDown(androidLibrary.close);
    await _addLocalBook(windowsLibrary, 'windows.txt', 'Windows 原书', 'Windows 原件内容');
    await _addLocalBook(androidLibrary, 'android.txt', 'Android 原书', 'Android 原件内容');
    await _addLocalBook(windowsLibrary, 'shared-windows.txt', 'Windows 冲突版本', 'Windows 冲突原件', documentId: 'shared-document-123');
    await _addLocalBook(androidLibrary, 'shared-android.txt', 'Android 冲突版本', 'Android 冲突原件', documentId: 'shared-document-123');

    final windowsGateway = _LocalBooksGateway(windowsLibrary);
    final androidGateway = _LocalBooksGateway(androidLibrary);
    final hostResult = Completer<PairedSyncRunSummary>();
    final host = await PairedSyncHost.start(
      identity: crossDeviceWindowsIdentity,
      devices: CrossDevicePairedRepository(crossDevicePeer(crossDeviceAndroidIdentity, PairedDevicePlatform.android)),
      identityStore: CrossDeviceIdentityStore(crossDeviceWindowsIdentity, crossDeviceAndroidIdentity.deviceId),
      discoveryPort: 0,
      onIncoming: (session) async {
        try {
          hostResult.complete(await session.run(gateway: windowsGateway));
        } on Object catch (error, stackTrace) {
          hostResult.completeError(error, stackTrace);
        }
      },
    );
    addTearDown(host.close);

    final client = await PairedSyncClientSession.connectAny(
      endpoints: <PairedSyncEndpoint>[
        PairedSyncEndpoint(
          address: address!.address,
          deviceId: crossDeviceWindowsIdentity.deviceId,
          expiresAtUtc: DateTime.now().toUtc().add(const Duration(minutes: 1)),
          label: crossDeviceWindowsIdentity.label,
          port: host.port,
        ),
      ],
      identity: crossDeviceAndroidIdentity,
      peer: crossDevicePeer(crossDeviceWindowsIdentity, PairedDevicePlatform.windows),
      sharedSecret: crossDeviceSecret(),
    );
    addTearDown(client.close);

    final androidSummary = await client.run(gateway: androidGateway).timeout(const Duration(minutes: 2));
    final windowsSummary = await hostResult.future.timeout(const Duration(minutes: 2));
    expect(androidSummary.receivedBooks, 1);
    expect(androidSummary.sentBooks, 1);
    expect(windowsSummary.receivedBooks, 1);
    expect(windowsSummary.sentBooks, 1);

    final windowsBooks = await windowsLibrary.listLocalDocuments();
    final androidBooks = await androidLibrary.listLocalDocuments();
    expect(windowsBooks.map((item) => item.title), containsAll(<String>['Windows 原书', 'Android 原书']));
    expect(androidBooks.map((item) => item.title), containsAll(<String>['Android 原书', 'Windows 原书']));
    expect(windowsBooks.map((item) => item.title), contains('Windows 冲突版本'));
    expect(windowsBooks.map((item) => item.title), isNot(contains('Android 冲突版本')));
    expect(androidBooks.map((item) => item.title), contains('Android 冲突版本'));
    expect(androidBooks.map((item) => item.title), isNot(contains('Windows 冲突版本')));
    expect(await _originalText(windowsLibrary, windowsBooks.singleWhere((item) => item.title == 'Android 原书')), contains('Android 原件内容'));
    expect(await _originalText(androidLibrary, androidBooks.singleWhere((item) => item.title == 'Windows 原书')), contains('Windows 原件内容'));
    expect(await windowsLibrary.readLocalDocumentCover(windowsBooks.singleWhere((item) => item.title == 'Android 原书').id), isNotNull);
    expect(await androidLibrary.readLocalDocumentCover(androidBooks.singleWhere((item) => item.title == 'Windows 原书').id), isNotNull);
    expect(await _originalText(windowsLibrary, windowsBooks.singleWhere((item) => item.title == 'Windows 冲突版本')), contains('Windows 冲突原件'));
    expect(await _originalText(androidLibrary, androidBooks.singleWhere((item) => item.title == 'Android 冲突版本')), contains('Android 冲突原件'));
    for (final pair in <(ContentLibrary, List<LibraryItem>)>[(windowsLibrary, windowsBooks), (androidLibrary, androidBooks)]) {
      for (final item in pair.$2) {
        expect((await pair.$1.loadProgress(item.id) as LibraryReadingProgress).totalReadingSeconds, greaterThan(0));
        expect(await pair.$1.loadBookmarks(item.id, ContentKind.novel), hasLength(1));
      }
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}

Future<void> _addLocalBook(ContentLibrary library, String fileName, String title, String bodyText, {String? documentId}) async {
  final bytes = utf8.encode('第一章 起点\n\n$bodyText\n\n第二章 终点\n\n更多正文');
  final stage = await library.prepareLocalImport(
    LocalImportInput(fileName: fileName, bytes: bytes.length, openRead: () => Stream.value(bytes)),
  );
  final committed = await library.commitLocalImport(stage.id, title: title, author: '测试作者', documentId: documentId);
  expect(committed.status, LocalImportStatus.succeeded, reason: committed.errorCode);
  final itemId = committed.itemId!;
  await library.updateLocalDocumentCover(itemId, bytes: <int>[137, 80, 78, 71, 13, 10, 26, 10, ...utf8.encode(title)]);
  final session = (await library.openLocalDocumentSession(itemId))!;
  final chapter = session.chapterAt(0)!;
  final body = await session.readChapter(chapter.id);
  final paragraph = ((body['blocks']! as List).first as Map)['id']! as String;
  await library.saveLocalReadingProgress(
    LibraryReadingProgress(
      itemId: itemId,
      chapterId: chapter.id,
      paragraphId: paragraph,
      characterOffset: 1,
      chapterIndex: 0,
      chapterFraction: .1,
      bookFraction: .1,
      updatedAtUtc: DateTime.utc(2026, 11, 4),
      totalReadingSeconds: 25,
    ),
    session.generation,
  );
  await library.saveLocalReadingBookmark(
    LibraryBookmark(
      id: 'bookmark-$title',
      itemId: itemId,
      chapterId: chapter.id,
      paragraphId: paragraph,
      characterOffset: 1,
      chapterTitle: chapter.title,
      excerpt: bodyText,
      createdAtUtc: DateTime.utc(2026, 11, 4),
    ),
    session.generation,
  );
  await session.close();
}

Future<String> _originalText(ContentLibrary library, LibraryItem item) async =>
    utf8.decode(await library.openLocalDocumentOriginal(item.id).expand((chunk) => chunk).toList());

bool _privateIpv4(String value) {
  final parts = value.split('.').map(int.tryParse).toList(growable: false);
  if (parts.length != 4 || parts.any((part) => part == null)) return false;
  final a = parts[0]!;
  final b = parts[1]!;
  return a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168);
}

final class _LocalBooksGateway implements LanSyncGateway, LanSyncLocalDocumentGateway {
  _LocalBooksGateway(this.library);
  final ContentLibrary library;

  @override
  Future<LanSyncManifest> createManifest() async =>
      LanSyncManifest(plugins: const <LanSyncPluginDescriptor>[], shelfItems: const <LanSyncShelfItem>[], skippedShelfItems: 0);

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
      LocalImportInput(fileName: 'paired.${document.format}', bytes: document.originalBytes, openRead: () => bytes),
      options: LocalDocumentParseOptions.fromJson(document.options),
    );
    expect(staged.status, LocalImportStatus.awaitingConfirmation, reason: staged.errorCode);
    final transferId = const LibraryItemId('paired-transfer');
    final progress = document.progress;
    final importedProgress = progress == null
        ? null
        : LibraryReadingProgress(
            itemId: transferId,
            chapterId: progress.chapterId,
            paragraphId: progress.paragraphId,
            characterOffset: progress.characterOffset,
            chapterIndex: progress.chapterIndex,
            chapterFraction: progress.chapterFraction,
            bookFraction: progress.bookFraction,
            updatedAtUtc: progress.updatedAtUtc,
            totalReadingSeconds: progress.totalReadingSeconds,
          );
    final bookmarks = <LibraryBookmark>[
      for (final bookmark in document.bookmarks)
        LibraryBookmark(
          id: bookmark.id,
          itemId: transferId,
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
    final conflicts = <LanSyncLocalDocumentConflict>[];
    final localItems = await library.listLocalDocuments();
    for (final document in manifest.localDocuments) {
      for (final item in localItems) {
        final details = await library.localDocumentDetails(item.id);
        if (details?.documentId == document.documentId || details?.rawSha256 == document.rawSha256) {
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
