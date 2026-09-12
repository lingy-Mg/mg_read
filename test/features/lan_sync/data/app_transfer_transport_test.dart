import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/features/lan_sync/application/app_update_service.dart';
import 'package:mg_read/features/lan_sync/application/device_identity_store.dart';
import 'package:mg_read/features/lan_sync/application/paired_device_repository.dart';
import 'package:mg_read/features/lan_sync/data/app_transfer_transport.dart';
import 'package:mg_read/features/lan_sync/data/lan_sync_checksum.dart';
import 'package:mg_read/features/lan_sync/data/lan_sync_transport.dart';
import 'package:mg_read/features/lan_sync/data/paired_sync_transport.dart';
import 'package:mg_read/features/lan_sync/domain/app_update_models.dart';
import 'package:mg_read/features/lan_sync/domain/paired_device_models.dart';

void main() {
  test('temporary App channel compares versions, transfers verified bytes, and launches receiver installer', () async {
    final addresses = await eligibleLanSyncAddresses();
    if (addresses.isEmpty) return;
    final senderService = await _FakeAppUpdateService.create('1.2.0', 12);
    final receiverService = await _FakeAppUpdateService.create('1.1.0', 11);
    addTearDown(senderService.close);
    addTearDown(receiverService.close);
    final sender = await AppTransferSenderService.start(senderService);
    addTearDown(sender.close);

    final receiver = await AppTransferReceiverConnection.connectAny(sender.connectionOffer, await receiverService.currentVersion());
    addTearDown(receiver.close);
    expect(receiver.remoteOffer.version.displayVersion, '1.2.0 (12)');

    await receiver.downloadAndInstall(receiverService, await receiverService.currentVersion(), force: false);

    expect(receiverService.installedBytes, senderService.packageBytes);
  });

  test('paired online App pull uses HMAC host endpoint and supports explicit force install', () async {
    final addresses = await eligibleLanSyncAddresses();
    if (addresses.isEmpty) return;
    final secret = List<int>.generate(32, (index) => index + 3);
    const hostIdentity = LocalDeviceIdentity(deviceId: 'windows_app_host_123456', label: 'Windows');
    const clientIdentity = LocalDeviceIdentity(deviceId: 'windows_app_client_1234', label: 'Windows 2');
    final hostPeer = _device(clientIdentity);
    final clientPeer = _device(hostIdentity);
    final hostService = await _FakeAppUpdateService.create('2.0.0', 20);
    final clientService = await _FakeAppUpdateService.create('2.0.0', 20);
    addTearDown(hostService.close);
    addTearDown(clientService.close);
    final host = await PairedSyncHost.start(
      identity: hostIdentity,
      devices: _MemoryRepository(hostPeer),
      identityStore: _MemoryIdentityStore(hostIdentity, clientIdentity.deviceId, secret),
      appUpdates: hostService,
      onIncoming: (session) => session.rejectBusy(),
    );
    addTearDown(host.close);
    final offer = (await hostService.availablePackages()).single;
    final endpoint = PairedSyncEndpoint(
      address: addresses.first,
      deviceId: hostIdentity.deviceId,
      expiresAtUtc: DateTime.now().toUtc().add(const Duration(minutes: 1)),
      label: hostIdentity.label,
      port: host.port,
      appOffers: <AppPackageOffer>[offer],
    );

    await pullPairedAppUpdate(
      endpoint: endpoint,
      identity: clientIdentity,
      peer: clientPeer,
      sharedSecret: secret,
      service: clientService,
      force: true,
    );

    expect(clientService.installedBytes, hostService.packageBytes);
  });
}

final class _FakeAppUpdateService implements AppUpdateService {
  _FakeAppUpdateService._(this.version, this.root, this.packageBytes);
  final AppVersionInfo version;
  final Directory root;
  final List<int> packageBytes;
  List<int>? installedBytes;

  static Future<_FakeAppUpdateService> create(String version, int build) async {
    final root = await Directory.systemTemp.createTemp('mgread-app-transfer-test-');
    return _FakeAppUpdateService._(
      AppVersionInfo(platform: AppUpdatePlatform.windows, version: version, buildNumber: build),
      root,
      utf8.encode('mgread-package-$version-$build'),
    );
  }

  @override
  Future<AppVersionInfo> currentVersion() async => version;

  @override
  Future<List<AppPackageOffer>> availablePackages() async => <AppPackageOffer>[AppPackageOffer(version: version, available: true)];

  @override
  Future<void> ensureInstallPermission() async {}

  @override
  Future<PreparedAppPackage> preparePackage(AppUpdatePlatform platform) async {
    final file = File('${root.path}${Platform.pathSeparator}mg_read.zip');
    await file.writeAsBytes(packageBytes);
    return PreparedAppPackage(
      descriptor: AppPackageDescriptor(
        version: version,
        bytes: packageBytes.length,
        checksum: lanSyncChecksum(packageBytes),
        fileName: 'mg_read.zip',
      ),
      file: file,
    );
  }

  @override
  Future<void> launchInstaller(File package, AppPackageDescriptor descriptor) async {
    installedBytes = await package.readAsBytes();
  }

  Future<void> close() async {
    if (await root.exists()) await root.delete(recursive: true);
  }
}

PairedDevice _device(LocalDeviceIdentity identity) => PairedDevice(
  autoSync: false,
  createdAtUtc: DateTime.utc(2026, 9, 8),
  deviceId: identity.deviceId,
  label: identity.label,
  mode: PairedSyncMode.bidirectional,
  platform: PairedDevicePlatform.windows,
  syncBookshelf: true,
  syncPlugins: true,
);

final class _MemoryRepository implements PairedDeviceRepository {
  _MemoryRepository(this.device);
  PairedDevice device;
  @override
  Future<List<PairedDevice>> list() async => <PairedDevice>[device];
  @override
  Future<PairedDevice?> read(String deviceId) async => device.deviceId == deviceId ? device : null;
  @override
  Future<void> remove(String deviceId) async {}
  @override
  Future<void> upsert(PairedDevice value) async => device = value;
}

final class _MemoryIdentityStore implements DeviceIdentityStore {
  _MemoryIdentityStore(this.identity, this.peerId, this.secret);
  final LocalDeviceIdentity identity;
  final String peerId;
  final List<int> secret;
  @override
  Future<void> deletePeerSecret(String peerDeviceId) async {}
  @override
  Future<LocalDeviceIdentity> loadOrCreateIdentity() async => identity;
  @override
  Future<List<int>?> readPeerSecret(String peerDeviceId) async => peerDeviceId == peerId ? secret : null;
  @override
  Future<void> writePeerSecret(String peerDeviceId, List<int> secret) async {}
}
