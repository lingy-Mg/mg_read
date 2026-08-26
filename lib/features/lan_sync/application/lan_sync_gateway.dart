import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/features/lan_sync/domain/lan_sync_models.dart';

abstract interface class LanSyncGateway {
  Future<LanSyncManifest> createManifest();

  Future<Stream<List<int>>> openPluginArchive(LanSyncPluginDescriptor plugin);

  Future<LanSyncImportPreview> previewImport(LanSyncManifest manifest);

  Future<void> preparePluginImports(List<LanSyncPluginDescriptor> plugins);

  Future<void> importPluginArchive(LanSyncPluginDescriptor plugin, Stream<List<int>> bytes);

  Future<LanSyncPluginImportResult> finishPluginImports();

  Future<void> cancelPluginImports();

  Future<LanSyncApplyResult> applyImport({
    required LanSyncManifest manifest,
    required Map<String, LanSyncConflictChoice> conflictChoices,
    required Set<String> availablePluginIds,
    required LanSyncPluginImportResult pluginResult,
  });
}

/// A stable, privacy-safe failure surfaced by the LAN-sync data boundary.
final class LanSyncGatewayException implements Exception {
  const LanSyncGatewayException(this.code);

  final String code;
}

final class LanSyncPluginImportResult {
  const LanSyncPluginImportResult({
    required this.availablePluginIds,
    required this.installed,
    required this.skipped,
    required this.failed,
    this.failureCode,
  });

  const LanSyncPluginImportResult.empty()
    : availablePluginIds = const <String>{},
      installed = 0,
      skipped = 0,
      failed = 0,
      failureCode = null;

  final Set<String> availablePluginIds;
  final int installed;
  final int skipped;
  final int failed;
  final String? failureCode;
}

final lanSyncGatewayProvider = Provider<LanSyncGateway>((Ref ref) {
  return const _UnavailableLanSyncGateway();
});

final class _UnavailableLanSyncGateway implements LanSyncGateway {
  const _UnavailableLanSyncGateway();

  Never _unavailable() => throw StateError('lan_sync_unavailable');

  @override
  Future<LanSyncApplyResult> applyImport({
    required LanSyncManifest manifest,
    required Map<String, LanSyncConflictChoice> conflictChoices,
    required Set<String> availablePluginIds,
    required LanSyncPluginImportResult pluginResult,
  }) async => _unavailable();

  @override
  Future<LanSyncManifest> createManifest() async => _unavailable();

  @override
  Future<LanSyncPluginImportResult> finishPluginImports() async => _unavailable();

  @override
  Future<void> cancelPluginImports() async {}

  @override
  Future<void> importPluginArchive(LanSyncPluginDescriptor plugin, Stream<List<int>> bytes) async => _unavailable();

  @override
  Future<void> preparePluginImports(List<LanSyncPluginDescriptor> plugins) async => _unavailable();

  @override
  Future<Stream<List<int>>> openPluginArchive(LanSyncPluginDescriptor plugin) async => _unavailable();

  @override
  Future<LanSyncImportPreview> previewImport(LanSyncManifest manifest) async => _unavailable();
}
