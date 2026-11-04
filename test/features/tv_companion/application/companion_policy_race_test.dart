/// Explicit revocation wins over grants paused inside platform/storage IO.
library;

import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mg_read/features/lan_sync/application/device_identity_store.dart';
import 'package:mg_read/features/lan_sync/application/paired_device_repository.dart';
import 'package:mg_read/features/lan_sync/domain/paired_device_models.dart';
import 'package:mg_read/features/tv_companion/application/companion_controller.dart';
import 'package:mg_read/features/tv_companion/data/companion_network.dart';
import 'package:mg_read/features/tv_companion/data/companion_repository.dart';
import 'companion_controller_testkit.dart';

void main() {
  test('revoke fences a previously started grant before its delayed key read finishes', () async {
    final fixture = await _create();
    final service = fixture.$1, identity = fixture.$2;
    await service.setPolicy(companionTestPhoneId, const CompanionPolicy(control: true));
    final gate = Completer<void>();
    identity.gate = gate;
    identity.entered = Completer<void>();
    final oldGrant = service.setPolicy(companionTestPhoneId, const CompanionPolicy(control: true));
    await identity.entered!.future;
    final revoke = service.setPolicy(companionTestPhoneId, const CompanionPolicy());
    gate.complete();
    await Future.wait([oldGrant, revoke]);
    expect((await fixture.$4.policy(companionTestPhoneId)).control, isFalse);
    expect(service.policies[companionTestPhoneId]?.control, isFalse);
  });
  test('receiver off wins while an earlier enable waits for platform permission', () async {
    final fixture = await _create();
    final service = fixture.$1, network = fixture.$3;
    final gate = Completer<void>();
    network.gate = gate;
    network.entered = Completer<void>();
    final enabling = service.setReceiverEnabled(true);
    await network.entered!.future;
    final disabling = service.setReceiverEnabled(false);
    expect(service.receiverEnabled, isFalse);
    gate.complete();
    await Future.wait([enabling, disabling]);
    expect(service.receiverEnabled, isFalse);
    expect(await fixture.$4.receiverEnabled(), isFalse);
  });
}

Future<(CompanionController, _Identity, _Network, MemoryCompanionRepository)> _create() async {
  final identity = _Identity(), network = _Network(), repository = MemoryCompanionRepository();
  final devices = CompanionTestPairedDevices();
  await devices.upsert(
    PairedDevice(
      deviceId: companionTestPhoneId,
      label: 'Phone',
      platform: PairedDevicePlatform.android,
      createdAtUtc: DateTime.utc(2026),
      mode: PairedSyncMode.bidirectional,
      autoSync: false,
      syncBookshelf: false,
      syncPlugins: false,
    ),
  );
  final container = ProviderContainer(
    overrides: [
      deviceIdentityStoreProvider.overrideWithValue(identity),
      pairedDeviceRepositoryProvider.overrideWithValue(devices),
      companionRepositoryProvider.overrideWithValue(repository),
      companionNetworkProvider.overrideWithValue(network),
    ],
  );
  addTearDown(container.dispose);
  final service = container.read(companionControllerProvider);
  await service.initialize();
  return (service, identity, network, repository);
}

final class _Identity implements DeviceIdentityStore {
  Completer<void>? gate, entered;
  @override
  Future<LocalDeviceIdentity> loadOrCreateIdentity() async => const LocalDeviceIdentity(deviceId: companionTestTvId, label: 'TV');
  @override
  Future<List<int>?> readPeerSecret(String id) async {
    final pending = gate;
    if (pending != null) {
      gate = null;
      entered!.complete();
      await pending.future;
    }
    return companionTestPsk;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Network extends CompanionNetwork {
  Completer<void>? gate, entered;
  @override
  Future<bool> available() async => true;
  @override
  Future<List<String>> addresses() async => ['127.0.0.1'];
  @override
  Future<bool> ensurePermission() async {
    final pending = gate;
    if (pending != null) {
      gate = null;
      entered!.complete();
      await pending.future;
    }
    return true;
  }
}
