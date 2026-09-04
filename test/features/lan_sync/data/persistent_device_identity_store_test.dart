import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/core/persistence/persistence.dart';
import 'package:mg_read/features/lan_sync/data/persistent_device_identity_store.dart';

void main() {
  test('local identity and peer secret survive persistence reopen', () async {
    const peerDeviceId = 'peer_device_12345678';
    final secret = List<int>.generate(32, (index) => index);
    final root = await Directory.systemTemp.createTemp('mg-read-device-identity-');
    addTearDown(() => root.delete(recursive: true));
    final registry = RecordDocumentRegistry(deviceIdentityRecordDocumentCodecs);
    var records = await PersistenceRecordStore.open(dataRoot: root, registry: registry);
    final store = PersistentDeviceIdentityStore(records, deviceLabelResolver: () async => 'MacBook Pro');

    final created = await store.loadOrCreateIdentity();
    await store.writePeerSecret(peerDeviceId, secret);
    await records.close();

    records = await PersistenceRecordStore.open(dataRoot: root, registry: registry);
    addTearDown(records.close);
    final reopened = PersistentDeviceIdentityStore(records, deviceLabelResolver: () async => 'MacBook Pro');

    final restored = await reopened.loadOrCreateIdentity();
    expect(restored.deviceId, created.deviceId);
    expect(restored.label, created.label);
    expect(await reopened.readPeerSecret(peerDeviceId), secret);

    await reopened.deletePeerSecret(peerDeviceId);
    expect(await reopened.readPeerSecret(peerDeviceId), isNull);
  });

  test('invalid peer secret is rejected before persistence', () async {
    final root = await Directory.systemTemp.createTemp('mg-read-invalid-device-secret-');
    addTearDown(() => root.delete(recursive: true));
    final records = await PersistenceRecordStore.open(dataRoot: root, registry: RecordDocumentRegistry(deviceIdentityRecordDocumentCodecs));
    addTearDown(records.close);
    final store = PersistentDeviceIdentityStore(records);

    await expectLater(store.writePeerSecret('peer_device_12345678', const <int>[1, 2, 3]), throwsArgumentError);
    expect(await store.readPeerSecret('peer_device_12345678'), isNull);
  });

  test('normalizes the platform device label before persistence', () async {
    final root = await Directory.systemTemp.createTemp('mg-read-device-label-');
    addTearDown(() => root.delete(recursive: true));
    final records = await PersistenceRecordStore.open(dataRoot: root, registry: RecordDocumentRegistry(deviceIdentityRecordDocumentCodecs));
    addTearDown(records.close);
    final store = PersistentDeviceIdentityStore(records, deviceLabelResolver: () async => '  Google   Pixel 9 Pro  ');

    expect((await store.loadOrCreateIdentity()).label, 'Google Pixel 9 Pro');
  });
}
