import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/features/lan_sync/data/lan_pairing_transport.dart';
import 'package:mg_read/features/lan_sync/data/lan_sync_transport.dart';
import 'package:mg_read/features/lan_sync/domain/paired_device_models.dart';

void main() {
  const desktop = LocalDeviceIdentity(deviceId: 'desktop_pairing_123456', label: '开发电脑');
  const phone = LocalDeviceIdentity(deviceId: 'phone_pairing_12345678', label: '手机');

  test('pairing commits only after the joining device acknowledges persistence', () async {
    if ((await eligibleLanSyncAddresses()).isEmpty) return;
    final server = await LanPairingServer.start(desktop);
    addTearDown(server.close);
    final requestFuture = server.requests.first;
    final client = await LanPairingClientConnection.connect(server.offer, phone);
    addTearDown(client.close);
    final request = await requestFuture;

    expect(client.pairingCode, request.pairingCode);
    final approvedPeerFuture = client.waitForApproval();
    final serverApproval = request.approve();
    final approvedPeer = await approvedPeerFuture;
    expect(approvedPeer.deviceId, desktop.deviceId);
    await client.confirmCommitted();
    await serverApproval;
    expect(request.isActive, isFalse);
    expect(approvedPeer.platform, _currentPlatform);
  });

  test('an unapproved request expires and closes both sides', () async {
    if ((await eligibleLanSyncAddresses()).isEmpty) return;
    final server = await LanPairingServer.start(desktop, requestLifetime: const Duration(milliseconds: 80));
    addTearDown(server.close);
    final requestFuture = server.requests.first;
    final client = await LanPairingClientConnection.connect(server.offer, phone);
    addTearDown(client.close);
    final request = await requestFuture;
    final rejected = expectLater(client.waitForApproval(), throwsA(isA<Object>()));

    await request.done.timeout(const Duration(seconds: 2));
    await rejected;
    expect(request.isActive, isFalse);
  });

  test('pairing offer exposes a completion signal when its lifetime ends', () async {
    if ((await eligibleLanSyncAddresses()).isEmpty) return;
    final server = await LanPairingServer.start(desktop, sessionLifetime: const Duration(milliseconds: 40));
    await server.done.timeout(const Duration(seconds: 2));
  });
}

PairedDevicePlatform get _currentPlatform => Platform.isWindows
    ? PairedDevicePlatform.windows
    : Platform.isMacOS
    ? PairedDevicePlatform.macos
    : Platform.isAndroid
    ? PairedDevicePlatform.android
    : PairedDevicePlatform.unknown;
