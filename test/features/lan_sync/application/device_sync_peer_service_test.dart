/// Shared host lifecycle without paired sync devices; no media or sync payloads.
library;

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mg_read/features/lan_sync/application/device_sync_controller.dart';
import 'package:mg_read/features/lan_sync/application/device_identity_store.dart';
import 'package:mg_read/features/lan_sync/application/paired_device_repository.dart';
import 'package:mg_read/features/lan_sync/application/lan_peer_service.dart';
import 'package:mg_read/features/lan_sync/data/lan_sync_transport.dart';
import 'package:mg_read/features/lan_sync/domain/paired_device_models.dart';

void main() {
  test('peer service hosts without sync peers and remains live while desktop sync is paused', () async {
    final service = _Service();
    final container = ProviderContainer(
      overrides: [
        lanPeerServiceProvider.overrideWithValue(service),
        pairedDeviceRepositoryProvider.overrideWithValue(_Devices()),
        deviceIdentityStoreProvider.overrideWithValue(_Identity()),
      ],
    );
    final controller = container.read(deviceSyncControllerProvider.notifier);
    addTearDown(() async {
      await controller.stop();
      container.dispose();
    });
    await controller.start();
    expect(service.port, isNotNull);
    expect(container.read(deviceSyncControllerProvider).devices, isEmpty);
    final addresses = await eligibleLanSyncAddresses();
    expect(addresses, isNotEmpty);
    final client = HttpClient()..findProxy = (_) => 'DIRECT';
    addTearDown(() => client.close(force: true));
    Future<int> request() async {
      final outgoing = await client.getUrl(Uri.http('${addresses.first}:${service.port}', '/peer-test'));
      final response = await outgoing.close();
      await response.drain<void>();
      return response.statusCode;
    }

    expect(await request(), 204);
    controller.pauseSyncKeepingPeerServices();
    expect(await request(), 204);
    service.enabled = false;
    await controller.reloadDevices();
    expect(service.port, isNull);
    expect(service.requests, 2);
  }, skip: !Platform.isWindows && !Platform.isMacOS);
}

final class _Service implements LanPeerService {
  bool enabled = true;
  int? port;
  int requests = 0;
  @override
  bool get requiresHost => enabled;
  @override
  Future<bool> canUseNetwork() async => true;
  @override
  Map<String, Object?> get advertisement => {'test': 1};
  @override
  void hostChanged(int? value) => port = value;
  @override
  Future<bool> handleRequest(HttpRequest request) async {
    if (request.uri.path != '/peer-test') return false;
    requests++;
    request.response.statusCode = 204;
    await request.response.close();
    return true;
  }

  @override
  void trustRevoked(String deviceId) {}
  @override
  void discovered({
    required String deviceId,
    required String label,
    required String address,
    required int port,
    required Duration lifetime,
    required Map<String, Object?> services,
  }) {}
}

final class _Devices implements PairedDeviceRepository {
  @override
  Future<List<PairedDevice>> list() async => [];
  @override
  Future<PairedDevice?> read(String id) async => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Identity implements DeviceIdentityStore {
  @override
  Future<LocalDeviceIdentity> loadOrCreateIdentity() async => const LocalDeviceIdentity(deviceId: 'peer_host_test_12345', label: 'host');
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
