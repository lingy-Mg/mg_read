import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/features/tv_companion/application/companion_controller.dart';
import 'package:mg_read/features/tv_companion/data/companion_repository.dart';
import 'package:mg_read/features/tv_companion/domain/companion_command.dart';
import 'package:mg_read/features/tv_companion/domain/companion_models.dart';

import 'companion_controller_testkit.dart';

void main() {
  late CompanionPairFixture fixture;

  tearDown(() async => fixture.close());

  test('real encrypted connection publishes authoritative idle state and grants a control lease', () async {
    fixture = await CompanionPairFixture.create();
    await fixture.connect();
    await fixture.waitFor(() => fixture.phone.remoteState?.status == 'idle');

    expect(fixture.phone.connectionStatus, CompanionConnectionStatus.connected);
    expect(fixture.phone.remoteState?.hostEpoch, fixture.tv.hostEpoch);
    expect(fixture.phone.remoteState?.content, isNull);
    expect(fixture.phone.stale, isFalse);

    final receipt = await fixture.phone.command(CompanionCommandType.acquireControl, ensureControl: false);
    expect(receipt.phase, CompanionCommandPhase.applied);
    await fixture.waitFor(() => fixture.phone.hasControl);
    expect(fixture.phone.remoteState?.controllerId, companionTestPhoneId);
  });

  test('LAN connection is independent of paired identity and companion control policy', () async {
    fixture = await CompanionPairFixture.create(allowControl: false);

    await fixture.connect();
    expect(fixture.tv.connectedControllerIds, [companionTestPhoneId]);
    expect(fixture.phone.connectionStatus, CompanionConnectionStatus.connected);
    expect(fixture.phone.remoteState?.hostEpoch, fixture.tv.hostEpoch);
  });

  test('re-pairing the same ID does not gate ephemeral LAN access or create companion trust', () async {
    fixture = await CompanionPairFixture.create();
    await fixture.rotatePhonePairing(companionTestRotatedPsk);

    await fixture.connect();
    await fixture.waitFor(() => fixture.phone.remoteState != null);
    expect(fixture.phone.connectionStatus, CompanionConnectionStatus.connected);
    expect(fixture.tv.connectedControllerIds, [companionTestPhoneId]);
  });

  test('legacy policy refresh closes an active LAN channel but does not authorize-gate reconnect', () async {
    fixture = await CompanionPairFixture.create();
    await fixture.connect();
    await fixture.waitFor(() => fixture.phone.remoteState != null);
    expect(fixture.tv.connectedControllerIds, [companionTestPhoneId]);

    await fixture.tv.setPolicy(companionTestPhoneId, const CompanionPolicy(control: false));
    await fixture.waitFor(() => fixture.tv.connectedControllerIds.isEmpty);
    await fixture.phone.disconnect(rememberSelection: true);
    expect(fixture.phone.connectionStatus, CompanionConnectionStatus.disconnected);

    await fixture.connect();
    await fixture.waitFor(() => fixture.phone.remoteState != null);
    expect(fixture.tv.connectedControllerIds, [companionTestPhoneId]);
    expect(fixture.phone.connectionStatus, CompanionConnectionStatus.connected);
  });

  test('a real command reaches the TV handler only after the snapshot grants control', () async {
    final navigated = <String>[];
    fixture = await CompanionPairFixture.create(
      onNavigate: (key) async {
        navigated.add(key);
      },
    );
    await fixture.connect();
    await fixture.waitFor(() => fixture.phone.remoteState != null);

    final receipt = await fixture.phone.command(CompanionCommandType.navigate, arguments: const {'key': 'right'});

    expect(receipt.phase, CompanionCommandPhase.applied);
    expect(navigated, ['right']);
    expect(fixture.phone.hasControl, isTrue);
  });
}
