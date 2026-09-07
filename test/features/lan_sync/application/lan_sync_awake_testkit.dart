/// 本机 HTTP 亮屏测试夹具；网关检查真实业务入口，平台调用通过 MethodChannel 记录。
library;

import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';
import 'package:mg_read/features/lan_sync/application/lan_sync_controller.dart';
import 'package:mg_read/features/lan_sync/application/lan_sync_gateway.dart';
import 'package:mg_read/features/lan_sync/application/lan_sync_network_environment.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_models.dart';

const awakePlugin = LanSyncPluginDescriptor(
  id: 'source.awake',
  version: '1.0.0',
  bytes: 3,
  artifactFormat: LanSyncPluginArtifactFormat.archive,
  sha256: '039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81',
  transferable: true,
);
const awakeManifest = LanSyncManifest(plugins: [awakePlugin], shelfItems: [], skippedShelfItems: 0);

void installAwakeProbe() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('novel_reader_ui/system');
  late HttpOverrides? previousHttpOverrides;
  setUp(() {
    previousHttpOverrides = HttpOverrides.current;
    HttpOverrides.global = _RealHttpOverrides();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) async => null);
    expect(ScreenAwakeCoordinator.instance.holderCount, 0);
  });
  tearDown(() async {
    await waitUntil(() => ScreenAwakeCoordinator.instance.holderCount == 0);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    HttpOverrides.global = previousHttpOverrides;
  });
}

final class _RealHttpOverrides extends HttpOverrides {}

Future<void> waitUntil(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 8));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out waiting for sync state');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

final class AwakeNetwork implements LanSyncNetworkEnvironment {
  @override
  Future<bool> isLocalNetworkAvailable() async => true;
}

ProviderContainer manualContainer(AwakeGateway gateway) {
  final container = ProviderContainer(
    overrides: [lanSyncGatewayProvider.overrideWithValue(gateway), lanSyncNetworkEnvironmentProvider.overrideWithValue(AwakeNetwork())],
  );
  final subscription = container.listen(lanSyncControllerProvider, (_, _) {});
  addTearDown(() async {
    await container.read(lanSyncControllerProvider.notifier).cancel();
    subscription.close();
    container.dispose();
  });
  return container;
}

final class AwakeGateway implements LanSyncGateway {
  AwakeGateway({this.requireAwake = true});

  final bool requireAwake;
  final gates = <String, Completer<void>>{};
  final reached = <String>{};
  String? failure;
  int cancellations = 0;

  Completer<void> pause(String stage) => gates[stage] = Completer<void>();

  Future<void> stage(String stage) async {
    if (requireAwake) {
      expect(ScreenAwakeCoordinator.instance.holderCount, greaterThan(0), reason: stage);
    }
    reached.add(stage);
    await gates[stage]?.future;
    if (failure == stage) throw StateError('awake_test_$stage');
  }

  @override
  Future<LanSyncManifest> createManifest() async {
    await stage('manifest');
    return awakeManifest;
  }

  @override
  Future<Stream<List<int>>> openPluginArchive(LanSyncPluginDescriptor plugin) async {
    await stage('archive');
    return Stream.value([1, 2, 3]);
  }

  @override
  Future<LanSyncImportPreview> previewImport(LanSyncManifest manifest, {bool force = false}) async {
    await stage('preview');
    return LanSyncImportPreview(
      newItemCount: 0,
      conflicts: [],
      blockedItemCount: 0,
      pluginPlans: {awakePlugin.id: LanSyncPluginPlanState.missing},
      selectedPluginIds: {awakePlugin.id},
    );
  }

  @override
  Future<void> preparePluginImports(List<LanSyncPluginDescriptor> plugins, {Set<String> forceUpgradePluginIds = const {}}) =>
      stage('prepare');

  @override
  Future<void> importPluginArchive(LanSyncPluginDescriptor plugin, Stream<List<int>> bytes) async {
    await stage('receive');
    await bytes.drain<void>();
  }

  @override
  Future<LanSyncPluginImportResult> finishPluginImports() async {
    await stage('install');
    return LanSyncPluginImportResult(availablePluginIds: {awakePlugin.id}, installed: 1, skipped: 0, failed: 0);
  }

  @override
  Future<LanSyncApplyResult> applyImport({
    required LanSyncManifest manifest,
    required Map<String, LanSyncConflictChoice> conflictChoices,
    required Set<String> availablePluginIds,
    required LanSyncPluginImportResult pluginResult,
    bool force = false,
  }) async {
    await stage('apply');
    return const LanSyncApplyResult(added: 0, updated: 0, keptLocal: 0, blocked: 0, pluginInstalled: 1, pluginSkipped: 0, pluginFailed: 0);
  }

  @override
  Future<void> cancelPluginImports() async {
    await stage('cleanup');
    cancellations++;
  }
}
