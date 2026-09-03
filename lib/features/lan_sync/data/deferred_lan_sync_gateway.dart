/// Deferred LAN-sync gateway used by the application composition root.
///
/// Responsibilities:
/// - Wait for the startup-owned content library before creating the real gateway.
/// - Preserve one gateway instance for the full multi-step synchronization session.
/// - Allow a failed startup resolution to be retried by the next user action.
/// - Publish successful plugin-batch mutations once for all synchronization consumers.
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

final class DeferredLanSyncGateway implements LanSyncGateway, LanSyncPairedGateway {
  // The public callback parameter cannot use the private field's name across libraries.
  // ignore: prefer_initializing_formals
  DeferredLanSyncGateway(this._factory, {void Function()? onPluginCatalogChanged}) : _onPluginCatalogChanged = onPluginCatalogChanged;

  final LanSyncGatewayFactory _factory;
  final void Function()? _onPluginCatalogChanged;
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
  Future<LanSyncManifest> createPairedManifest({
    bool includePlugins = true,
    bool includeShelf = true,
    bool deferPluginArtifacts = false,
  }) async {
    final delegate = await _delegate();
    if (delegate is LanSyncPairedGateway) {
      return (delegate as LanSyncPairedGateway).createPairedManifest(
        includePlugins: includePlugins,
        includeShelf: includeShelf,
        deferPluginArtifacts: deferPluginArtifacts,
      );
    }
    final manifest = await delegate.createManifest();
    return LanSyncManifest(
      plugins: includePlugins ? manifest.plugins : const <LanSyncPluginDescriptor>[],
      shelfItems: includeShelf ? manifest.shelfItems : const <LanSyncShelfItem>[],
      skippedShelfItems: includeShelf ? manifest.skippedShelfItems : 0,
    );
  }

  @override
  Future<Stream<List<int>>> openPluginArchive(LanSyncPluginDescriptor plugin) async => (await _delegate()).openPluginArchive(plugin);

  @override
  Future<LanSyncMaterializedPlugin> materializePluginArchive(LanSyncPluginDescriptor plugin) async {
    final delegate = await _delegate();
    if (delegate is LanSyncPairedGateway) {
      return (delegate as LanSyncPairedGateway).materializePluginArchive(plugin);
    }
    return LanSyncMaterializedPlugin(descriptor: plugin, bytes: await delegate.openPluginArchive(plugin));
  }

  @override
  Future<LanSyncImportPreview> previewImport(LanSyncManifest manifest) async => (await _delegate()).previewImport(manifest);

  @override
  Future<void> preparePluginImports(List<LanSyncPluginDescriptor> plugins) async => (await _delegate()).preparePluginImports(plugins);

  @override
  Future<void> importPluginArchive(LanSyncPluginDescriptor plugin, Stream<List<int>> bytes) async =>
      (await _delegate()).importPluginArchive(plugin, bytes);

  @override
  Future<LanSyncPluginImportResult> finishPluginImports() async {
    final result = await (await _delegate()).finishPluginImports();
    if (result.installed > 0) _onPluginCatalogChanged?.call();
    return result;
  }

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
