import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/features/lan_sync/application/device_identity_store.dart';
import 'package:mg_read/features/lan_sync/application/lan_sync_gateway.dart';
import 'package:mg_read/features/lan_sync/application/paired_device_repository.dart';
import 'package:mg_read/features/lan_sync/data/lan_sync_transport.dart';
import 'package:mg_read/features/lan_sync/data/paired_sync_transport.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_models.dart';
import 'package:mg_read/features/lan_sync/domain/paired_device_models.dart';

void main() {
  test('paired receiver initiates one authenticated bidirectional sync without sender approval', () async {
    final addresses = await eligibleLanSyncAddresses();
    if (addresses.isEmpty) return;
    final secret = List<int>.generate(32, (index) => index + 1);
    const serverIdentity = LocalDeviceIdentity(deviceId: 'desktop_device_123456', label: '开发电脑');
    const clientIdentity = LocalDeviceIdentity(deviceId: 'phone_device_12345678', label: '手机');
    final serverPeer = _device(clientIdentity, PairedDevicePlatform.android);
    final clientPeer = _device(serverIdentity, PairedDevicePlatform.windows);
    final serverRepository = _MemoryPairedDeviceRepository(serverPeer);
    final serverSecrets = _MemoryIdentityStore(serverIdentity, <String, List<int>>{clientIdentity.deviceId: secret});
    final serverGateway = _ShelfGateway('desktop-book');
    final clientGateway = _ShelfGateway('phone-book');
    final serverResult = Completer<PairedSyncRunSummary>();
    final host = await PairedSyncHost.start(
      identity: serverIdentity,
      devices: serverRepository,
      identityStore: serverSecrets,
      onIncoming: (session) async {
        try {
          serverResult.complete(await session.run(gateway: serverGateway));
        } on Object catch (error, stackTrace) {
          serverResult.completeError(error, stackTrace);
        }
      },
    );
    addTearDown(host.close);
    final session = await PairedSyncClientSession.connectAny(
      endpoints: <PairedSyncEndpoint>[
        PairedSyncEndpoint(
          address: addresses.first,
          deviceId: serverIdentity.deviceId,
          expiresAtUtc: DateTime.now().toUtc().add(const Duration(minutes: 1)),
          label: serverIdentity.label,
          port: host.port,
        ),
      ],
      identity: clientIdentity,
      peer: clientPeer,
      sharedSecret: secret,
    );

    final clientSummary = await session.run(gateway: clientGateway, pullOnly: false);
    final hostSummary = await serverResult.future;

    expect(clientSummary.receivedBooks, 1);
    expect(clientSummary.sentBooks, 1);
    expect(hostSummary.receivedBooks, 1);
    expect(hostSummary.sentBooks, 1);
    expect(clientGateway.appliedIds, <String>['desktop-book']);
    expect(serverGateway.appliedIds, <String>['phone-book']);
  });

  test('paired sync materializes only the development source selected by the receiver', () async {
    final addresses = await eligibleLanSyncAddresses();
    if (addresses.isEmpty) return;
    final secret = List<int>.generate(32, (index) => index + 11);
    const serverIdentity = LocalDeviceIdentity(deviceId: 'desktop_lazy_12345678', label: '开发电脑');
    const clientIdentity = LocalDeviceIdentity(deviceId: 'phone_lazy_1234567890', label: '手机');
    final serverPeer = _device(clientIdentity, PairedDevicePlatform.android);
    final clientPeer = _device(serverIdentity, PairedDevicePlatform.windows);
    final serverGateway = _PluginGateway(offeredIds: const <String>['org.example.selected', 'org.example.same'], requestedId: null);
    final clientGateway = _PluginGateway(offeredIds: const <String>[], requestedId: 'org.example.selected');
    final serverResult = Completer<PairedSyncRunSummary>();
    final host = await PairedSyncHost.start(
      identity: serverIdentity,
      devices: _MemoryPairedDeviceRepository(serverPeer),
      identityStore: _MemoryIdentityStore(serverIdentity, <String, List<int>>{clientIdentity.deviceId: secret}),
      onIncoming: (session) async {
        try {
          serverResult.complete(await session.run(gateway: serverGateway));
        } on Object catch (error, stackTrace) {
          serverResult.completeError(error, stackTrace);
        }
      },
    );
    addTearDown(host.close);
    final session = await PairedSyncClientSession.connectAny(
      endpoints: <PairedSyncEndpoint>[
        PairedSyncEndpoint(
          address: addresses.first,
          deviceId: serverIdentity.deviceId,
          expiresAtUtc: DateTime.now().toUtc().add(const Duration(minutes: 1)),
          label: serverIdentity.label,
          port: host.port,
        ),
      ],
      identity: clientIdentity,
      peer: clientPeer,
      sharedSecret: secret,
    );

    final clientSummary = await session.run(gateway: clientGateway, pullOnly: true);
    final hostSummary = await serverResult.future;

    expect(serverGateway.materializedIds, <String>['org.example.selected']);
    expect(clientGateway.importedIds, <String>['org.example.selected']);
    expect(clientSummary.receivedPlugins, 1);
    expect(hostSummary.sentPlugins, 1);
  });
}

PairedDevice _device(LocalDeviceIdentity identity, PairedDevicePlatform platform) => PairedDevice(
  autoSync: true,
  createdAtUtc: DateTime.utc(2026, 8, 31),
  deviceId: identity.deviceId,
  label: identity.label,
  mode: PairedSyncMode.bidirectional,
  platform: platform,
  syncBookshelf: true,
  syncPlugins: true,
);

final class _MemoryPairedDeviceRepository implements PairedDeviceRepository {
  _MemoryPairedDeviceRepository(PairedDevice device) : _devices = <String, PairedDevice>{device.deviceId: device};

  final Map<String, PairedDevice> _devices;

  @override
  Future<List<PairedDevice>> list() async => _devices.values.toList(growable: false);

  @override
  Future<PairedDevice?> read(String deviceId) async => _devices[deviceId];

  @override
  Future<void> remove(String deviceId) async {
    _devices.remove(deviceId);
  }

  @override
  Future<void> upsert(PairedDevice device) async {
    _devices[device.deviceId] = device;
  }
}

final class _MemoryIdentityStore implements DeviceIdentityStore {
  _MemoryIdentityStore(this.identity, this.secrets);

  final LocalDeviceIdentity identity;
  final Map<String, List<int>> secrets;

  @override
  Future<void> deletePeerSecret(String peerDeviceId) async {
    secrets.remove(peerDeviceId);
  }

  @override
  Future<LocalDeviceIdentity> loadOrCreateIdentity() async => identity;

  @override
  Future<List<int>?> readPeerSecret(String peerDeviceId) async => secrets[peerDeviceId];

  @override
  Future<void> writePeerSecret(String peerDeviceId, List<int> secret) async {
    secrets[peerDeviceId] = secret;
  }
}

final class _ShelfGateway implements LanSyncGateway {
  _ShelfGateway(this.localId);

  final String localId;
  final List<String> appliedIds = <String>[];

  @override
  Future<LanSyncManifest> createManifest() async => LanSyncManifest(
    plugins: const <LanSyncPluginDescriptor>[],
    shelfItems: <LanSyncShelfItem>[
      LanSyncShelfItem(
        pluginId: 'org.example.source',
        pluginVersion: '1.0.0',
        remoteContentId: localId,
        contentKind: 'novel',
        title: localId,
      ),
    ],
    skippedShelfItems: 0,
  );

  @override
  Future<LanSyncImportPreview> previewImport(LanSyncManifest manifest) async => LanSyncImportPreview(
    newItemCount: manifest.shelfItems.length,
    conflicts: const <LanSyncBookConflict>[],
    blockedItemCount: 0,
    pluginPlans: const <String, LanSyncPluginPlanState>{},
    selectedShelfItemIds: <String>{for (final item in manifest.shelfItems) item.identity},
  );

  @override
  Future<void> preparePluginImports(List<LanSyncPluginDescriptor> plugins) async {}

  @override
  Future<void> importPluginArchive(LanSyncPluginDescriptor plugin, Stream<List<int>> bytes) async {}

  @override
  Future<LanSyncPluginImportResult> finishPluginImports() async => const LanSyncPluginImportResult.empty();

  @override
  Future<LanSyncApplyResult> applyImport({
    required LanSyncManifest manifest,
    required Map<String, LanSyncConflictChoice> conflictChoices,
    required Set<String> availablePluginIds,
    required LanSyncPluginImportResult pluginResult,
  }) async {
    appliedIds.addAll(manifest.shelfItems.map((item) => item.remoteContentId));
    return LanSyncApplyResult(
      added: manifest.shelfItems.length,
      updated: 0,
      keptLocal: 0,
      blocked: 0,
      pluginInstalled: pluginResult.installed,
      pluginSkipped: pluginResult.skipped,
      pluginFailed: pluginResult.failed,
    );
  }

  @override
  Future<void> cancelPluginImports() async {}

  @override
  Future<Stream<List<int>>> openPluginArchive(LanSyncPluginDescriptor plugin) async => const Stream<List<int>>.empty();
}

final class _PluginGateway implements LanSyncGateway, LanSyncPairedGateway {
  _PluginGateway({required this.offeredIds, required this.requestedId});

  final List<String> offeredIds;
  final String? requestedId;
  final List<String> materializedIds = <String>[];
  final List<String> importedIds = <String>[];

  @override
  Future<LanSyncManifest> createManifest() => createPairedManifest();

  @override
  Future<LanSyncManifest> createPairedManifest({
    bool includePlugins = true,
    bool includeShelf = true,
    bool deferPluginArtifacts = false,
  }) async {
    if (includePlugins) expect(deferPluginArtifacts, isTrue);
    return LanSyncManifest(
      plugins: includePlugins ? <LanSyncPluginDescriptor>[for (final id in offeredIds) _offer(id)] : const <LanSyncPluginDescriptor>[],
      shelfItems: const <LanSyncShelfItem>[],
      skippedShelfItems: 0,
    );
  }

  @override
  Future<LanSyncMaterializedPlugin> materializePluginArchive(LanSyncPluginDescriptor plugin) async {
    materializedIds.add(plugin.id);
    final descriptor = LanSyncPluginDescriptor(
      id: plugin.id,
      version: plugin.version,
      bytes: 3,
      artifactFormat: plugin.artifactFormat,
      developmentFingerprint: plugin.developmentFingerprint,
      developmentRevision: plugin.developmentRevision,
      sha256: ''.padLeft(64, 'a'),
      transferable: true,
      provenance: plugin.provenance,
    );
    return LanSyncMaterializedPlugin(descriptor: descriptor, bytes: Stream<List<int>>.value(const <int>[1, 2, 3]));
  }

  @override
  Future<LanSyncImportPreview> previewImport(LanSyncManifest manifest) async {
    return LanSyncImportPreview(
      newItemCount: 0,
      conflicts: const <LanSyncBookConflict>[],
      blockedItemCount: 0,
      pluginPlans: <String, LanSyncPluginPlanState>{
        for (final plugin in manifest.plugins)
          plugin.id: plugin.id == requestedId ? LanSyncPluginPlanState.missing : LanSyncPluginPlanState.sameVersion,
      },
    );
  }

  @override
  Future<void> preparePluginImports(List<LanSyncPluginDescriptor> plugins) async {
    expect(plugins.every((plugin) => !plugin.deferred && plugin.bytes == 3), isTrue);
  }

  @override
  Future<void> importPluginArchive(LanSyncPluginDescriptor plugin, Stream<List<int>> bytes) async {
    final received = <int>[];
    await for (final chunk in bytes) {
      received.addAll(chunk);
    }
    expect(received, const <int>[1, 2, 3]);
    importedIds.add(plugin.id);
  }

  @override
  Future<LanSyncPluginImportResult> finishPluginImports() async {
    return LanSyncPluginImportResult(availablePluginIds: importedIds.toSet(), installed: importedIds.length, skipped: 0, failed: 0);
  }

  @override
  Future<LanSyncApplyResult> applyImport({
    required LanSyncManifest manifest,
    required Map<String, LanSyncConflictChoice> conflictChoices,
    required Set<String> availablePluginIds,
    required LanSyncPluginImportResult pluginResult,
  }) async => LanSyncApplyResult(
    added: 0,
    updated: 0,
    keptLocal: 0,
    blocked: 0,
    pluginInstalled: pluginResult.installed,
    pluginSkipped: pluginResult.skipped,
    pluginFailed: pluginResult.failed,
  );

  @override
  Future<void> cancelPluginImports() async {}

  @override
  Future<Stream<List<int>>> openPluginArchive(LanSyncPluginDescriptor plugin) =>
      throw StateError('paired_sync_must_materialize_selected_offer');
}

LanSyncPluginDescriptor _offer(String id) => LanSyncPluginDescriptor(
  id: id,
  version: '1.0.0-dev.7.aaaaaaaaaaaa',
  bytes: 0,
  artifactFormat: LanSyncPluginArtifactFormat.archive,
  developmentFingerprint: ''.padLeft(64, 'b'),
  developmentRevision: 7,
  sha256: ''.padLeft(64, '0'),
  transferable: true,
  deferred: true,
  provenance: LanSyncPluginProvenance.development,
);
