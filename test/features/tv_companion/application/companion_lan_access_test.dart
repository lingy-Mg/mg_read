import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/features/tv_companion/application/companion_controller.dart';
import 'package:mg_read/features/tv_companion/domain/companion_command.dart';

import 'companion_controller_testkit.dart';

void main() {
  late CompanionPairFixture fixture;

  tearDown(() async => fixture.close());

  test('unpaired LAN connection returns only after authoritative state and can acquire control', () async {
    final privateAddress = await _privateIpv4();
    if (privateAddress == null) markTestSkipped('No private IPv4 interface is available.');
    fixture = await CompanionPairFixture.create(allowControl: false, serverAddress: InternetAddress(privateAddress!));
    await fixture.phoneIdentity.deletePeerSecret(companionTestTvId);
    await fixture.tvIdentity.deletePeerSecret(companionTestPhoneId);
    await fixture.phoneDevices.remove(companionTestTvId);
    await fixture.tvDevices.remove(companionTestPhoneId);

    await fixture.phone.connectManual(address: privateAddress, port: fixture.tvServer.port, deviceId: companionTestTvId);

    expect(fixture.phone.connectionStatus.name, 'connected');
    expect(fixture.phone.remoteState?.hostEpoch, fixture.tv.hostEpoch);
    expect(fixture.phone.stale, isFalse);
    expect(fixture.phone.requiresHost, isTrue);
    expect(fixture.tv.connectedControllerIds, [companionTestPhoneId]);
    final acquired = await fixture.phone.command(CompanionCommandType.acquireControl, ensureControl: false);
    expect(acquired.phase, CompanionCommandPhase.applied);
    await fixture.waitFor(() => fixture.phone.hasControl);
    expect(fixture.phone.hasControl, isTrue);
    await fixture.phone.disconnect();
    expect(fixture.phone.requiresHost, isFalse);
  });

  test('phone discovery keeps the shared LAN host alive until discovery is released', () async {
    fixture = await CompanionPairFixture.create();
    await fixture.phone.setTvMode(false);
    expect(fixture.phone.requiresHost, isFalse);

    await fixture.phone.discover(true);
    expect(fixture.phone.requiresHost, isTrue);
    await fixture.phone.discover(false);

    expect(fixture.phone.requiresHost, isFalse);
  });

  test('TV role automatically enables the receiver and leaving TV role disables it', () async {
    fixture = await CompanionPairFixture.create();
    await fixture.phone.setTvMode(true);
    expect(fixture.phone.receiverEnabled, isTrue);
    expect(fixture.phone.requiresHost, isTrue);

    await fixture.phone.setTvMode(false);
    expect(fixture.phone.receiverEnabled, isFalse);
    expect(fixture.phone.requiresHost, isFalse);
  });

  test('manual IP connection resolves the TV identity over private HTTP before LAN handshake', () async {
    final privateAddress = await _privateIpv4();
    if (privateAddress == null) markTestSkipped('No private IPv4 interface is available.');
    fixture = await CompanionPairFixture.create(serverAddress: InternetAddress(privateAddress!));
    await fixture.phoneIdentity.deletePeerSecret(companionTestTvId);
    await fixture.tvIdentity.deletePeerSecret(companionTestPhoneId);
    await fixture.phoneDevices.remove(companionTestTvId);
    await fixture.tvDevices.remove(companionTestPhoneId);

    await fixture.phone.connectManual(address: privateAddress, port: fixture.tvServer.port);

    expect(fixture.phone.selectedDeviceId, companionTestTvId);
    expect(fixture.phone.selectedLabel, 'TV');
    expect(fixture.phone.remoteState?.hostEpoch, fixture.tv.hostEpoch);
  });
}

Future<String?> _privateIpv4() async {
  for (final interface in await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false)) {
    for (final address in interface.addresses) {
      final parts = address.address.split('.').map(int.tryParse).toList();
      if (parts.length != 4 || parts.any((part) => part == null)) continue;
      final a = parts[0]!;
      final b = parts[1]!;
      if (a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168)) return address.address;
    }
  }
  return null;
}
