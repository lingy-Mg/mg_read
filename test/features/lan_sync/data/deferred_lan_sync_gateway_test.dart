/// Deferred LAN-sync gateway mutation notification tests.
///
/// Verifies that every synchronization consumer shares one successful plugin
/// catalog notification after a completed import batch.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/features/lan_sync/application/lan_sync_gateway.dart';
import 'package:mg_read/features/lan_sync/data/deferred_lan_sync_gateway.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_models.dart';

void main() {
  test('completed plugin import publishes one shared catalog change', () async {
    var catalogChanges = 0;
    final gateway = DeferredLanSyncGateway(() async => _FinishingGateway(installed: 1), onPluginCatalogChanged: () => catalogChanges += 1);

    final result = await gateway.finishPluginImports();

    expect(result.installed, 1);
    expect(catalogChanges, 1);
  });

  test('empty plugin import does not publish a catalog change', () async {
    var catalogChanges = 0;
    final gateway = DeferredLanSyncGateway(() async => _FinishingGateway(installed: 0), onPluginCatalogChanged: () => catalogChanges += 1);

    await gateway.finishPluginImports();

    expect(catalogChanges, 0);
  });

  test('deferred wrapper forwards local-document originals and custom covers', () async {
    final document = LanSyncLocalDocumentDescriptor(
      documentId: 'local_document_123456',
      rawSha256: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      originalBytes: 3,
      format: 'txt',
      title: '本地书',
      options: <String, Object?>{},
      coverSha256: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      coverBytes: 2,
      coverMimeType: 'image/png',
    );
    final delegate = _FinishingGateway(installed: 0, localDocuments: <LanSyncLocalDocumentDescriptor>[document]);
    final gateway = DeferredLanSyncGateway(() async => delegate);

    expect(await gateway.listLocalDocumentDescriptors(), <LanSyncLocalDocumentDescriptor>[document]);
    expect(await (await gateway.openLocalDocumentOriginal(document)).expand((chunk) => chunk).toList(), <int>[1, 2, 3]);
    expect(await (await gateway.openLocalDocumentCover(document))!.expand((chunk) => chunk).toList(), <int>[4, 5]);
    await gateway.importLocalDocument(
      document,
      Stream<List<int>>.value(<int>[1, 2, 3]),
      useSenderMetadata: true,
      coverBytes: Stream<List<int>>.value(<int>[4, 5]),
      coverMimeType: 'image/png',
    );
    expect(delegate.importedOriginal, <int>[1, 2, 3]);
    expect(delegate.importedCover, <int>[4, 5]);
    expect(delegate.importUsedSenderMetadata, isTrue);
  });
}

final class _FinishingGateway implements LanSyncGateway, LanSyncLocalDocumentGateway {
  _FinishingGateway({required this.installed, this.localDocuments = const <LanSyncLocalDocumentDescriptor>[]});

  final int installed;
  final List<LanSyncLocalDocumentDescriptor> localDocuments;
  List<int>? importedOriginal;
  List<int>? importedCover;
  bool? importUsedSenderMetadata;

  Never _unused() => throw UnsupportedError('Not used by deferred gateway notification tests.');

  @override
  Future<LanSyncApplyResult> applyImport({
    required LanSyncManifest manifest,
    required Map<String, LanSyncConflictChoice> conflictChoices,
    required Set<String> availablePluginIds,
    required LanSyncPluginImportResult pluginResult,
    bool force = false,
  }) async => _unused();

  @override
  Future<void> cancelPluginImports() async {}

  @override
  Future<LanSyncManifest> createManifest() async => _unused();

  @override
  Future<LanSyncPluginImportResult> finishPluginImports() async =>
      LanSyncPluginImportResult(availablePluginIds: const <String>{'org.example.synced'}, installed: installed, skipped: 0, failed: 0);

  @override
  Future<void> importPluginArchive(LanSyncPluginDescriptor plugin, Stream<List<int>> bytes) async => _unused();

  @override
  Future<Stream<List<int>>> openPluginArchive(LanSyncPluginDescriptor plugin) async => _unused();

  @override
  Future<void> preparePluginImports(List<LanSyncPluginDescriptor> plugins, {Set<String> forceUpgradePluginIds = const <String>{}}) async =>
      _unused();

  @override
  Future<LanSyncImportPreview> previewImport(LanSyncManifest manifest, {bool force = false}) async => _unused();

  @override
  Future<List<LanSyncLocalDocumentDescriptor>> listLocalDocumentDescriptors() async => localDocuments;

  @override
  Future<Stream<List<int>>> openLocalDocumentOriginal(LanSyncLocalDocumentDescriptor document) async =>
      Stream<List<int>>.value(<int>[1, 2, 3]);

  @override
  Future<Stream<List<int>>?> openLocalDocumentCover(LanSyncLocalDocumentDescriptor document) async => Stream<List<int>>.value(<int>[4, 5]);

  @override
  Future<void> importLocalDocument(
    LanSyncLocalDocumentDescriptor document,
    Stream<List<int>> bytes, {
    required bool useSenderMetadata,
    Stream<List<int>>? coverBytes,
    String? coverMimeType,
  }) async {
    importedOriginal = await bytes.expand((chunk) => chunk).toList();
    importedCover = coverBytes == null ? null : await coverBytes.expand((chunk) => chunk).toList();
    importUsedSenderMetadata = useSenderMetadata;
  }
}
