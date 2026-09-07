/// 已配对控制器的真实本机发现/认证 HTTP 测试；平台亮屏仍为模拟通道。
library;

import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';
import 'package:mg_read/features/lan_sync/application/device_sync_controller.dart';
import 'package:mg_read/features/lan_sync/application/device_identity_store.dart';
import 'package:mg_read/features/lan_sync/application/paired_device_repository.dart';
import 'package:mg_read/features/lan_sync/application/lan_sync_gateway.dart';
import 'package:mg_read/features/lan_sync/application/lan_sync_network_environment.dart';
import 'package:mg_read/features/lan_sync/data/paired_sync_transport.dart';
import 'package:mg_read/features/lan_sync/domain/paired_device_models.dart';
import 'lan_sync_awake_testkit.dart';

const _local = LocalDeviceIdentity(deviceId: 'aaa_awake_local_12345', label: 'local');
const _remote = LocalDeviceIdentity(deviceId: 'zzz_awake_remote_1234', label: 'remote');
final _secret = List<int>.generate(32, (i) => i + 1);

void main() {
  installAwakeProbe();

  for (final fail in [false, true]) {
    test('automatic outbound ${fail ? 'failure' : 'completion'} releases only after cleanup', () async {
      final gateway = AwakeGateway();
      final manifest = gateway.pause('manifest');
      final cleanup = gateway.pause('cleanup');
      if (fail) gateway.failure = 'manifest';
      final container = _container(gateway, autoSync: true);
      final controller = container.read(deviceSyncControllerProvider.notifier);
      await controller.start();
      expect(ScreenAwakeCoordinator.instance.holderCount, 0, reason: 'idle discovery host');
      final remoteDone = Completer<void>();
      final host = await PairedSyncHost.start(
        identity: _remote,
        devices: _Repository(_peer(_local)),
        identityStore: _Identity(_remote),
        announcementInterval: const Duration(milliseconds: 100),
        onIncoming: (session) async {
          try {
            await session.run(gateway: AwakeGateway());
          } on Object {
            // 失败场景由本机控制器断言；这里仍等待远端处理退出。
          } finally {
            remoteDone.complete();
          }
        },
      );
      addTearDown(host.close);
      await waitUntil(() => gateway.reached.contains('manifest'));
      expect(ScreenAwakeCoordinator.instance.holderCount, 1);
      manifest.complete();
      await waitUntil(() => gateway.reached.contains('cleanup'));
      expect(ScreenAwakeCoordinator.instance.holderCount, 1);
      cleanup.complete();
      await waitUntil(() => container.read(deviceSyncControllerProvider).busyDeviceId == null);
      if (!fail) {
        await remoteDone.future.timeout(const Duration(seconds: 8));
      } else {
        expect(remoteDone.isCompleted, isFalse, reason: '本地清单失败发生在创建远端 HTTP 会话之前');
      }
      expect(ScreenAwakeCoordinator.instance.holderCount, 0);
      expect(
        container.read(deviceSyncControllerProvider).devices.single.lastSyncResult,
        fail ? PairedSyncResultState.failed : PairedSyncResultState.success,
      );
      await controller.stop();
    });
  }

  for (final cancel in [false, true]) {
    test('paired incoming ${cancel ? 'stop during apply' : 'completion'} retains awake through actual processing', () async {
      final gateway = AwakeGateway();
      final install = gateway.pause('install');
      final apply = gateway.pause('apply');
      final cleanup = gateway.pause('cleanup');
      final container = _container(gateway, autoSync: false);
      final controller = container.read(deviceSyncControllerProvider.notifier);
      final endpointReady = Completer<PairedSyncEndpoint>();
      final host = await PairedSyncHost.start(
        identity: _remote,
        devices: _Repository(_peer(_local)),
        identityStore: _Identity(_remote),
        canAnnounce: () async => false,
        onIncoming: (session) => session.rejectBusy(),
      );
      addTearDown(host.close);
      final subscription = host.endpoints.listen((endpoint) {
        if (endpoint.deviceId == _local.deviceId && !endpointReady.isCompleted) endpointReady.complete(endpoint);
      });
      addTearDown(subscription.cancel);
      await controller.start();
      expect(ScreenAwakeCoordinator.instance.holderCount, 0);
      final endpoint = await endpointReady.future.timeout(const Duration(seconds: 8));
      final session = await PairedSyncClientSession.connectAny(
        endpoints: [endpoint],
        identity: _remote,
        peer: _peer(_local),
        sharedSecret: _secret,
      );
      final remoteResult = session.run(gateway: AwakeGateway(requireAwake: false), operation: PairedSyncOperation.push);
      // Observe disconnect errors immediately when stop closes the accepted connection.
      final observed = remoteResult.then<void>((_) {}, onError: (Object _, StackTrace _) {});
      await Future.any<void>([
        waitUntil(() => gateway.reached.contains('install')),
        remoteResult.then<void>((value) => throw StateError('remote sync ended before install: $value')),
      ]);
      expect(ScreenAwakeCoordinator.instance.holderCount, 1);
      install.complete();
      await waitUntil(() => gateway.reached.contains('apply'));
      if (cancel) await controller.stop();
      expect(ScreenAwakeCoordinator.instance.holderCount, 1, reason: 'in-flight bookshelf write survives host stop');
      apply.complete();
      await waitUntil(() => gateway.reached.contains('cleanup'));
      expect(ScreenAwakeCoordinator.instance.holderCount, 1);
      cleanup.complete();
      await waitUntil(() => container.read(deviceSyncControllerProvider).busyDeviceId == null);
      await observed.timeout(const Duration(seconds: 8));
      expect(ScreenAwakeCoordinator.instance.holderCount, 0);
      await controller.stop();
    });
  }
}

ProviderContainer _container(AwakeGateway gateway, {required bool autoSync}) {
  final container = ProviderContainer(
    overrides: [
      lanSyncGatewayProvider.overrideWithValue(gateway),
      lanSyncNetworkEnvironmentProvider.overrideWithValue(AwakeNetwork()),
      pairedDeviceRepositoryProvider.overrideWithValue(_Repository(_peer(_remote, autoSync: autoSync))),
      deviceIdentityStoreProvider.overrideWithValue(_Identity(_local)),
    ],
  );
  addTearDown(() async {
    await container.read(deviceSyncControllerProvider.notifier).stop();
    container.dispose();
  });
  return container;
}

PairedDevice _peer(LocalDeviceIdentity identity, {bool autoSync = false}) => PairedDevice(
  autoSync: autoSync,
  createdAtUtc: DateTime.utc(2026),
  deviceId: identity.deviceId,
  label: identity.label,
  mode: PairedSyncMode.bidirectional,
  platform: PairedDevicePlatform.android,
  syncBookshelf: true,
  syncPlugins: true,
);

final class _Identity implements DeviceIdentityStore {
  _Identity(this.identity);
  final LocalDeviceIdentity identity;
  @override
  Future<LocalDeviceIdentity> loadOrCreateIdentity() async => identity;
  @override
  Future<List<int>?> readPeerSecret(String peerDeviceId) async => _secret;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Repository implements PairedDeviceRepository {
  _Repository(this.device);
  PairedDevice device;
  @override
  Future<List<PairedDevice>> list() async => [device];
  @override
  Future<PairedDevice?> read(String deviceId) async => device.deviceId == deviceId ? device : null;
  @override
  Future<void> upsert(PairedDevice value) async => device = value;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
