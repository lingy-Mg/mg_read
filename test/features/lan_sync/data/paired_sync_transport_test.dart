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
    final serverPeer = _device(clientIdentity, PairedDevicePlatform.android, label: '旧手机名');
    final clientPeer = _device(serverIdentity, PairedDevicePlatform.windows, label: '旧电脑名');
    final serverRepository = _MemoryPairedDeviceRepository(serverPeer);
    final serverSecrets = _MemoryIdentityStore(serverIdentity, <String, List<int>>{clientIdentity.deviceId: secret});
    final serverGateway = _ShelfGateway('desktop-book');
    final clientGateway = _ShelfGateway('phone-book');
    final serverResult = Completer<PairedSyncRunSummary>();
    String? authenticatedClientLabel;
    final host = await PairedSyncHost.start(
      identity: serverIdentity,
      devices: serverRepository,
      identityStore: serverSecrets,
      onIncoming: (session) async {
        try {
          serverResult.complete(await session.run(gateway: serverGateway));
          authenticatedClientLabel = session.peer.label;
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

    expect(session.peer.label, serverIdentity.label);
    final clientSummary = await session.run(gateway: clientGateway);
    final hostSummary = await serverResult.future;

    expect(clientSummary.receivedBooks, 1);
    expect(clientSummary.sentBooks, 1);
    expect(hostSummary.receivedBooks, 1);
    expect(hostSummary.sentBooks, 1);
    expect(clientGateway.appliedIds, <String>['desktop-book']);
    expect(serverGateway.appliedIds, <String>['phone-book']);
    expect(authenticatedClientLabel, clientIdentity.label);
  });

  test('paired sync materializes only the development source selected by the receiver', () async {
    final addresses = await eligibleLanSyncAddresses();
    if (addresses.isEmpty) return;
    final secret = List<int>.generate(32, (index) => index + 11);
    const serverIdentity = LocalDeviceIdentity(deviceId: 'desktop_lazy_12345678', label: '开发电脑');
    const clientIdentity = LocalDeviceIdentity(deviceId: 'phone_lazy_1234567890', label: '手机');
    final serverPeer = _device(clientIdentity, PairedDevicePlatform.android);
    final clientPeer = _device(serverIdentity, PairedDevicePlatform.windows);
    final serverGateway = _PluginGateway(
      offeredIds: const <String>['org.example.selected', 'org.example.same'],
      requestedId: 'org.example.client-only',
    );
    final clientGateway = _PluginGateway(offeredIds: const <String>['org.example.client-only'], requestedId: 'org.example.selected');
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

    final clientSummary = await session.run(gateway: clientGateway, operation: PairedSyncOperation.pull);
    final hostSummary = await serverResult.future;

    expect(serverGateway.materializedIds, <String>['org.example.selected']);
    expect(clientGateway.importedIds, <String>['org.example.selected']);
    expect(clientGateway.materializedIds, isEmpty);
    expect(serverGateway.importedIds, isEmpty);
    expect(clientSummary.receivedPlugins, 1);
    expect(clientSummary.sentPlugins, 0);
    expect(hostSummary.sentPlugins, 1);
    expect(hostSummary.receivedPlugins, 0);
  });

  test('paired initiator can push without receiving remote shelf changes', () async {
    final addresses = await eligibleLanSyncAddresses();
    if (addresses.isEmpty) return;
    final secret = List<int>.generate(32, (index) => index + 21);
    const serverIdentity = LocalDeviceIdentity(deviceId: 'desktop_push_12345678', label: '开发电脑');
    const clientIdentity = LocalDeviceIdentity(deviceId: 'phone_push_1234567890', label: '手机');
    final serverGateway = _ShelfGateway('desktop-book');
    final clientGateway = _ShelfGateway('phone-book');
    final serverResult = Completer<PairedSyncRunSummary>();
    final host = await PairedSyncHost.start(
      identity: serverIdentity,
      devices: _MemoryPairedDeviceRepository(_device(clientIdentity, PairedDevicePlatform.android)),
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
      peer: _device(serverIdentity, PairedDevicePlatform.windows),
      sharedSecret: secret,
    );

    final clientSummary = await session.run(gateway: clientGateway, operation: PairedSyncOperation.push);
    final hostSummary = await serverResult.future;

    expect(clientSummary.receivedBooks, 0);
    expect(clientSummary.sentBooks, 1);
    expect(hostSummary.receivedBooks, 1);
    expect(hostSummary.sentBooks, 0);
    expect(clientGateway.appliedIds, isEmpty);
    expect(serverGateway.appliedIds, <String>['phone-book']);
  });

  test('authenticated wake request asks a Windows peer to reverse-connect once', () async {
    final addresses = await eligibleLanSyncAddresses();
    if (addresses.isEmpty) return;
    final secret = List<int>.generate(32, (index) => index + 31);
    const serverIdentity = LocalDeviceIdentity(deviceId: 'desktop_wake_12345678', label: '开发电脑');
    const clientIdentity = LocalDeviceIdentity(deviceId: 'phone_wake_1234567890', label: '手机');
    final wake = Completer<PairedSyncWakeRequest>();
    var callbackCount = 0;
    final host = await PairedSyncHost.start(
      identity: serverIdentity,
      devices: _MemoryPairedDeviceRepository(_device(clientIdentity, PairedDevicePlatform.android)),
      identityStore: _MemoryIdentityStore(serverIdentity, <String, List<int>>{clientIdentity.deviceId: secret}),
      onIncoming: (session) => session.close(),
      onWakeRequest: (request) async {
        callbackCount++;
        if (!wake.isCompleted) wake.complete(request);
      },
      discoveryPort: 0,
    );
    addTearDown(host.close);
    final requestId = createPairedSyncWakeRequestId();

    for (final address in addresses) {
      await sendPairedSyncWakeRequest(
        identity: clientIdentity,
        endpoint: PairedSyncEndpoint(
          address: address,
          deviceId: serverIdentity.deviceId,
          expiresAtUtc: DateTime.now().toUtc().add(const Duration(minutes: 1)),
          label: serverIdentity.label,
          port: host.port,
        ),
        sharedSecret: secret,
        operation: PairedSyncOperation.pull,
        localPort: 54321,
        requestId: requestId,
        discoveryPort: host.discoveryPort,
      );
    }
    final request = await wake.future.timeout(const Duration(seconds: 3));
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(request.requestId, requestId);
    expect(request.operation, PairedSyncOperation.pull);
    expect(request.operation.reversed, PairedSyncOperation.push);
    expect(request.endpoint.deviceId, clientIdentity.deviceId);
    expect(request.endpoint.port, 54321);
    expect(callbackCount, 1);
  });

  test('phone pull wake completes through a Windows outbound reverse connection', () async {
    final addresses = await eligibleLanSyncAddresses();
    if (addresses.isEmpty) return;
    final secret = List<int>.generate(32, (index) => index + 41);
    const desktopIdentity = LocalDeviceIdentity(deviceId: 'desktop_reverse_123456', label: '开发电脑');
    const phoneIdentity = LocalDeviceIdentity(deviceId: 'phone_reverse_12345678', label: '手机');
    final desktopGateway = _ShelfGateway('desktop-book');
    final phoneGateway = _ShelfGateway('phone-book');
    final phoneResult = Completer<PairedSyncRunSummary>();
    final desktopResult = Completer<PairedSyncRunSummary>();
    String? incomingRequestId;
    final phoneHost = await PairedSyncHost.start(
      identity: phoneIdentity,
      devices: _MemoryPairedDeviceRepository(_device(desktopIdentity, PairedDevicePlatform.windows)),
      identityStore: _MemoryIdentityStore(phoneIdentity, <String, List<int>>{desktopIdentity.deviceId: secret}),
      onIncoming: (session) async {
        try {
          phoneResult.complete(await session.run(gateway: phoneGateway));
          incomingRequestId = session.requestId;
        } on Object catch (error, stackTrace) {
          phoneResult.completeError(error, stackTrace);
        }
      },
      discoveryPort: 0,
    );
    addTearDown(phoneHost.close);
    final desktopHost = await PairedSyncHost.start(
      identity: desktopIdentity,
      devices: _MemoryPairedDeviceRepository(_device(phoneIdentity, PairedDevicePlatform.android)),
      identityStore: _MemoryIdentityStore(desktopIdentity, <String, List<int>>{phoneIdentity.deviceId: secret}),
      onIncoming: (session) => session.close(),
      onWakeRequest: (request) async {
        try {
          final session = await PairedSyncClientSession.connectAny(
            endpoints: <PairedSyncEndpoint>[request.endpoint],
            identity: desktopIdentity,
            peer: _device(phoneIdentity, PairedDevicePlatform.android),
            sharedSecret: secret,
          );
          desktopResult.complete(
            await session.run(gateway: desktopGateway, operation: request.operation.reversed, requestId: request.requestId),
          );
        } on Object catch (error, stackTrace) {
          desktopResult.completeError(error, stackTrace);
        }
      },
      discoveryPort: 0,
    );
    addTearDown(desktopHost.close);
    final requestId = createPairedSyncWakeRequestId();

    for (final address in addresses) {
      await sendPairedSyncWakeRequest(
        identity: phoneIdentity,
        endpoint: PairedSyncEndpoint(
          address: address,
          deviceId: desktopIdentity.deviceId,
          expiresAtUtc: DateTime.now().toUtc().add(const Duration(minutes: 1)),
          label: desktopIdentity.label,
          port: desktopHost.port,
        ),
        sharedSecret: secret,
        operation: PairedSyncOperation.pull,
        localPort: phoneHost.port,
        requestId: requestId,
        discoveryPort: desktopHost.discoveryPort,
      );
    }
    final phoneSummary = await phoneResult.future.timeout(const Duration(seconds: 5));
    final desktopSummary = await desktopResult.future.timeout(const Duration(seconds: 5));

    expect(incomingRequestId, requestId);
    expect(phoneSummary.receivedBooks, 1);
    expect(phoneSummary.sentBooks, 0);
    expect(desktopSummary.receivedBooks, 0);
    expect(desktopSummary.sentBooks, 1);
    expect(phoneGateway.appliedIds, <String>['desktop-book']);
    expect(desktopGateway.appliedIds, isEmpty);
  });
}

PairedDevice _device(LocalDeviceIdentity identity, PairedDevicePlatform platform, {String? label}) => PairedDevice(
  autoSync: true,
  createdAtUtc: DateTime.utc(2026, 8, 31),
  deviceId: identity.deviceId,
  label: label ?? identity.label,
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
