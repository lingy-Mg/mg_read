/// 验证两种同步的共享会话所有权、取消边界与反向连接等待。
library;

import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mg_read/features/lan_sync/application/lan_sync_controller.dart';
import 'package:mg_read/features/lan_sync/application/lan_sync_gateway.dart';
import 'package:mg_read/features/lan_sync/application/lan_sync_network_environment.dart';
import 'package:mg_read/features/lan_sync/application/lan_sync_session.dart';
import 'package:mg_read/features/lan_sync/application/paired_sync_completion.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_models.dart';

void main() {
  test('manual cancel cannot cancel the paired operation holding the gateway', () async {
    final gateway = _Gateway();
    final coordinator = LanSyncSessionCoordinator();
    final automatic = coordinator.tryAcquire(gateway)!;
    final container = ProviderContainer(
      overrides: [
        lanSyncGatewayProvider.overrideWithValue(gateway),
        lanSyncSessionCoordinatorProvider.overrideWithValue(coordinator),
        lanSyncNetworkEnvironmentProvider.overrideWithValue(_Network()),
      ],
    );
    addTearDown(container.dispose);
    final listener = container.listen(lanSyncControllerProvider, (_, _) {});
    addTearDown(listener.close);
    final controller = container.read(lanSyncControllerProvider.notifier);
    await controller.startSending();
    expect(container.read(lanSyncControllerProvider).errorCode, 'lan_sync_peer_busy');
    await controller.cancel();
    expect(gateway.cancellations, 0);
    expect(coordinator.tryAcquire(gateway), isNull);
    await automatic.close();
    expect(gateway.cancellations, 1);
  });

  test('cancellation waits for in-flight preparation and cleans it before reuse', () async {
    final gateway = _Gateway()..manifest = Completer<LanSyncManifest>();
    final coordinator = LanSyncSessionCoordinator();
    final container = ProviderContainer(
      overrides: [
        lanSyncGatewayProvider.overrideWithValue(gateway),
        lanSyncSessionCoordinatorProvider.overrideWithValue(coordinator),
        lanSyncNetworkEnvironmentProvider.overrideWithValue(_Network()),
      ],
    );
    addTearDown(container.dispose);
    final listener = container.listen(lanSyncControllerProvider, (_, _) {});
    addTearDown(listener.close);
    final controller = container.read(lanSyncControllerProvider.notifier);
    final starting = controller.startSending();
    await gateway.manifestStarted.future;
    final cancelling = controller.cancel();
    expect(coordinator.tryAcquire(gateway), isNull);
    gateway.manifest!.complete(const LanSyncManifest(plugins: [], shelfItems: [], skippedShelfItems: 0));
    await starting;
    await cancelling;
    expect(container.read(lanSyncControllerProvider).phase, LanSyncPhase.cancelled);
    expect(gateway.cancellations, 1);
    final next = coordinator.tryAcquire(gateway)!;
    await next.close();
  });

  test('old cleanup is idempotent and cannot release the next owner', () async {
    final coordinator = LanSyncSessionCoordinator();
    final gateway = _Gateway();
    final old = coordinator.tryAcquire(gateway)!;
    await old.close();
    final next = coordinator.tryAcquire(gateway)!;
    await old.close();
    expect(coordinator.tryAcquire(gateway), isNull);
    expect(gateway.cancellations, 1);
    await next.close();
  });

  test('reverse transfer continues beyond the connection timeout after connecting', () async {
    final completion = PairedSyncCompletion<int>();
    final result = completion.wait(const Duration(milliseconds: 10));
    completion.connected();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    completion.complete(7);
    expect(await result, 7);
  });

  test('missing reverse connection still times out', () async {
    await expectLater(PairedSyncCompletion<int>().wait(const Duration(milliseconds: 5)), throwsA(isA<TimeoutException>()));
  });

  test('failure before UDP send completes is observed without an unhandled error', () async {
    final completion = PairedSyncCompletion<int>();
    final error = StateError('wake failed');
    completion.completeError(error, StackTrace.current);
    await Future<void>.delayed(Duration.zero);
    await expectLater(completion.wait(const Duration(seconds: 1)), throwsA(same(error)));
  });
}

final class _Network implements LanSyncNetworkEnvironment {
  @override
  Future<bool> isLocalNetworkAvailable() async => true;
}

final class _Gateway implements LanSyncGateway {
  int cancellations = 0;
  Completer<LanSyncManifest>? manifest;
  final Completer<void> manifestStarted = Completer();

  @override
  Future<void> cancelPluginImports() async => cancellations++;

  @override
  Future<LanSyncManifest> createManifest() async {
    manifestStarted.complete();
    return await manifest?.future ?? const LanSyncManifest(plugins: [], shelfItems: [], skippedShelfItems: 0);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
