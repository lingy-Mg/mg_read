/// Deferred LAN-sync gateway used by the application composition root.
///
/// Responsibilities:
/// - Wait for the startup-owned content library before creating the real gateway.
/// - Preserve one gateway instance for the full multi-step synchronization session.
/// - Allow a failed startup resolution to be retried by the next user action.
///
/// Notes:
/// - Constructing this adapter performs no library, Runtime, or network IO.
/// - The delegate factory must return a gateway whose lifetime is owned elsewhere.
///
library;

import 'dart:async';

import 'package:mg_read/features/lan_sync/application/lan_sync_gateway.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_models.dart';

typedef LanSyncGatewayFactory = Future<LanSyncGateway> Function();

final class DeferredLanSyncGateway implements LanSyncGateway {
  DeferredLanSyncGateway(this._factory);

  final LanSyncGatewayFactory _factory;
  Future<LanSyncGateway>? _delegateFuture;

  Future<LanSyncGateway> _delegate() {
    final existing = _delegateFuture;
    if (existing != null) return existing;
    final next = Future<LanSyncGateway>.sync(_factory);
    _delegateFuture = next;
    unawaited(
      next.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {
          if (identical(_delegateFuture, next)) _delegateFuture = null;
        },
      ),
    );
    return next;
  }

  @override
  Future<LanSyncManifest> createManifest() async => (await _delegate()).createManifest();

  @override
  Future<Stream<List<int>>> openPluginArchive(LanSyncPluginDescriptor plugin) async => (await _delegate()).openPluginArchive(plugin);

  @override
  Future<LanSyncImportPreview> previewImport(LanSyncManifest manifest) async => (await _delegate()).previewImport(manifest);

  @override
  Future<void> preparePluginImports(List<LanSyncPluginDescriptor> plugins) async => (await _delegate()).preparePluginImports(plugins);

  @override
  Future<void> importPluginArchive(LanSyncPluginDescriptor plugin, Stream<List<int>> bytes) async =>
      (await _delegate()).importPluginArchive(plugin, bytes);

  @override
  Future<LanSyncPluginImportResult> finishPluginImports() async => (await _delegate()).finishPluginImports();

  @override
  Future<void> cancelPluginImports() async => (await _delegate()).cancelPluginImports();

  @override
  Future<LanSyncApplyResult> applyImport({
    required LanSyncManifest manifest,
    required Map<String, LanSyncConflictChoice> conflictChoices,
    required Set<String> availablePluginIds,
    required LanSyncPluginImportResult pluginResult,
  }) async => (await _delegate()).applyImport(
    manifest: manifest,
    conflictChoices: conflictChoices,
    availablePluginIds: availablePluginIds,
    pluginResult: pluginResult,
  );
}
