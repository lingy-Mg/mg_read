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
    final gateway = DeferredLanSyncGateway(
      () async => const _FinishingGateway(installed: 1),
      onPluginCatalogChanged: () => catalogChanges += 1,
    );

    final result = await gateway.finishPluginImports();

    expect(result.installed, 1);
    expect(catalogChanges, 1);
  });

  test('empty plugin import does not publish a catalog change', () async {
    var catalogChanges = 0;
    final gateway = DeferredLanSyncGateway(
      () async => const _FinishingGateway(installed: 0),
      onPluginCatalogChanged: () => catalogChanges += 1,
    );

    await gateway.finishPluginImports();

    expect(catalogChanges, 0);
  });
}

final class _FinishingGateway implements LanSyncGateway {
  const _FinishingGateway({required this.installed});

  final int installed;

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
}
