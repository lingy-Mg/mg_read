import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/core/persistence/persistence.dart';
import 'package:mg_read/features/lan_sync/data/persistent_paired_device_repository.dart';
import 'package:mg_read/features/lan_sync/domain/paired_device_models.dart';

void main() {
  test('paired device metadata survives reopen without storing endpoint or secret', () async {
    final root = await Directory.systemTemp.createTemp('mg-read-paired-device-');
    addTearDown(() => root.delete(recursive: true));
    final registry = RecordDocumentRegistry(<RecordDocumentCodec>[pairedDeviceRecordDocumentCodec]);
    var records = await PersistenceRecordStore.open(dataRoot: root, registry: registry);
    final repository = PersistentPairedDeviceRepository(records);
    final device = PairedDevice(
      autoSync: true,
      createdAtUtc: DateTime.utc(2026, 8, 31, 10),
      deviceId: 'phone_device_12345678',
      label: '我的手机',
      mode: PairedSyncMode.bidirectional,
      platform: PairedDevicePlatform.android,
      syncBookshelf: true,
      syncPlugins: true,
    );
    await repository.upsert(device);
    await records.close();

    records = await PersistenceRecordStore.open(dataRoot: root, registry: registry);
    addTearDown(records.close);
    final reopened = PersistentPairedDeviceRepository(records);
    final restored = await reopened.read(device.deviceId);

    expect(restored?.label, '我的手机');
    expect(restored?.platform, PairedDevicePlatform.android);
    expect(restored?.autoSync, isTrue);
    final envelope = await records.read(id: 'paired-device:${device.deviceId}', scope: pairedDeviceScope);
    expect(envelope, isNotNull);
    expect(envelope!.document.keys, isNot(contains('address')));
    expect(envelope.document.keys, isNot(contains('secret')));

    await reopened.remove(device.deviceId);
    expect(await reopened.read(device.deviceId), isNull);
  });
}
