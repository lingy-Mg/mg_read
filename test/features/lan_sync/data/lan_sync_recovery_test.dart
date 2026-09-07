/// 本机真实 HTTP 验证扫码导入失败、重复点击和重新连接；不替代双设备验收。
library;

import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mg_read/features/lan_sync/application/lan_sync_controller.dart';
import 'package:mg_read/features/lan_sync/application/lan_sync_gateway.dart';
import 'package:mg_read/features/lan_sync/application/lan_sync_network_environment.dart';
import 'package:mg_read/features/lan_sync/data/lan_sync_transport.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_models.dart';

const _plugin = LanSyncPluginDescriptor(
  id: 'source.recovery',
  version: '1.0.0',
  bytes: 3,
  artifactFormat: LanSyncPluginArtifactFormat.archive,
  sha256: '039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81',
  transferable: true,
);

void main() {
  test('temporary transport reports an importer rejection without waiting for an unsubscribed stream', () async {
    final sender = await _sender();
    addTearDown(sender.close);
    final receiver = await LanSyncReceiverConnection.connect(_peer(sender));
    addTearDown(receiver.close);
    await receiver.confirmAndReadManifest();
    final error = StateError('runtime_import_rejected');
    await expectLater(
      receiver.receivePlugins(pluginIds: {_plugin.id}, importPlugin: (_, _) async => throw error).timeout(const Duration(seconds: 2)),
      throwsA(same(error)),
    );
  });

  test('invalid manual input remains retryable and import cannot be entered twice', () async {
    final sender = await _sender();
    addTearDown(sender.close);
    final gateway = _Gateway();
    final container = ProviderContainer(
      overrides: [lanSyncGatewayProvider.overrideWithValue(gateway), lanSyncNetworkEnvironmentProvider.overrideWithValue(_Network())],
    );
    addTearDown(container.dispose);
    final listener = container.listen(lanSyncControllerProvider, (_, _) {});
    addTearDown(listener.close);
    final controller = container.read(lanSyncControllerProvider.notifier);
    await controller.startReceiving();
    await controller.connectManual('not an address');
    expect(container.read(lanSyncControllerProvider).phase, LanSyncPhase.discovering);
    expect(container.read(lanSyncControllerProvider).errorCode, 'lan_sync_manual_address_invalid');
    await controller.connectPeer(_peer(sender));
    await controller.confirmReceiverPairing();
    final first = controller.beginImport();
    await gateway.started.future;
    await controller.beginImport();
    expect(gateway.prepareCount, 1);
    gateway.ready.complete();
    await first.timeout(const Duration(seconds: 3));
    expect(container.read(lanSyncControllerProvider).phase, LanSyncPhase.completed);
    expect(gateway.received, [1, 2, 3]);
  });
}

Future<LanSyncSenderService> _sender() => LanSyncSenderService.start(
  manifest: const LanSyncManifest(plugins: [_plugin], shelfItems: [], skippedShelfItems: 0),
  openPlugin: (_) async => Stream.value([1, 2, 3]),
);

LanSyncPeer _peer(LanSyncSenderService sender) => LanSyncPeer(
  sessionId: sender.sessionId,
  label: 'test sender',
  address: sender.addresses.first,
  port: sender.port,
  expiresAtUtc: DateTime.now().toUtc().add(const Duration(minutes: 1)),
);

final class _Network implements LanSyncNetworkEnvironment {
  @override
  Future<bool> isLocalNetworkAvailable() async => true;
}

final class _Gateway implements LanSyncGateway {
  final started = Completer<void>();
  final ready = Completer<void>();
  final received = <int>[];
  int prepareCount = 0;

  @override
  Future<LanSyncImportPreview> previewImport(LanSyncManifest manifest, {bool force = false}) async => LanSyncImportPreview(
    newItemCount: 0,
    conflicts: [],
    blockedItemCount: 0,
    pluginPlans: {_plugin.id: LanSyncPluginPlanState.missing},
    selectedPluginIds: {_plugin.id},
  );

  @override
  Future<void> preparePluginImports(List<LanSyncPluginDescriptor> plugins, {Set<String> forceUpgradePluginIds = const {}}) async {
    prepareCount++;
    started.complete();
    await ready.future;
  }

  @override
  Future<void> importPluginArchive(LanSyncPluginDescriptor plugin, Stream<List<int>> bytes) async {
    await for (final chunk in bytes) {
      received.addAll(chunk);
    }
  }

  @override
  Future<LanSyncPluginImportResult> finishPluginImports() async =>
      LanSyncPluginImportResult(availablePluginIds: {_plugin.id}, installed: 1, skipped: 0, failed: 0);

  @override
  Future<LanSyncApplyResult> applyImport({
    required LanSyncManifest manifest,
    required Map<String, LanSyncConflictChoice> conflictChoices,
    required Set<String> availablePluginIds,
    required LanSyncPluginImportResult pluginResult,
    bool force = false,
  }) async =>
      const LanSyncApplyResult(added: 0, updated: 0, keptLocal: 0, blocked: 0, pluginInstalled: 1, pluginSkipped: 0, pluginFailed: 0);

  @override
  Future<void> cancelPluginImports() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
