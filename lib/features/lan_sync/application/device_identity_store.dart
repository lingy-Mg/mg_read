/// 本机设备身份和逐设备共享密钥的本地存储边界。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/features/lan_sync/domain/paired_device_models.dart';

abstract interface class DeviceIdentityStore {
  Future<void> deletePeerSecret(String peerDeviceId);

  Future<LocalDeviceIdentity> loadOrCreateIdentity();

  Future<List<int>?> readPeerSecret(String peerDeviceId);

  Future<void> writePeerSecret(String peerDeviceId, List<int> secret);
}

final deviceIdentityStoreProvider = Provider<DeviceIdentityStore>((ref) => const _UnavailableDeviceIdentityStore());

final class _UnavailableDeviceIdentityStore implements DeviceIdentityStore {
  const _UnavailableDeviceIdentityStore();

  Never _unavailable() => throw StateError('device_identity_store_unavailable');

  @override
  Future<void> deletePeerSecret(String peerDeviceId) async => _unavailable();

  @override
  Future<LocalDeviceIdentity> loadOrCreateIdentity() async => _unavailable();

  @override
  Future<List<int>?> readPeerSecret(String peerDeviceId) async => _unavailable();

  @override
  Future<void> writePeerSecret(String peerDeviceId, List<int> secret) async => _unavailable();
}
