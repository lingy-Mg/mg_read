/// Windows 向 Android 发送真实插件制品与书架元信息的跨设备宿主。
library;

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/features/lan_sync/application/lan_sync_gateway.dart';
import 'package:mg_read/features/lan_sync/data/paired_sync_transport.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_models.dart';
import 'package:mg_read/features/lan_sync/domain/paired_device_models.dart';

import 'paired_sync_cross_device_support.dart';

const String _pluginId = 'org.mgread.discovery-demo';
const String _pluginVersion = '0.1.2';

void main() {
  test('Windows sends a real plugin artifact and bookshelf metadata to Android', () async {
    final artifact = File('plugins/sources/mgread-discovery-demo/artifacts/org.mgread.discovery-demo-0.1.2.mgplugin.js');
    expect(await artifact.exists(), isTrue);
    final gateway = _FilePluginSenderGateway(artifact);
    final result = Completer<PairedSyncRunSummary>();
    final host = await PairedSyncHost.start(
      identity: crossDeviceWindowsIdentity,
      devices: CrossDevicePairedRepository(crossDevicePeer(crossDeviceAndroidIdentity, PairedDevicePlatform.android)),
      identityStore: CrossDeviceIdentityStore(crossDeviceWindowsIdentity, crossDeviceAndroidIdentity.deviceId),
      discoveryPort: 0,
      onIncoming: (session) async {
        try {
          result.complete(await session.run(gateway: gateway));
        } on Object catch (error, stackTrace) {
          result.completeError(error, stackTrace);
        }
      },
    );
    addTearDown(host.close);
    debugPrint('MGREAD_RUNTIME_CROSS_DEVICE_PORT=${host.port}');

    final summary = await result.future.timeout(const Duration(minutes: 8));

    expect(summary.sentBooks, 1);
    expect(summary.sentPlugins, 1);
    expect(summary.receivedBooks, 0);
    expect(summary.receivedPlugins, 0);
    debugPrint('MGREAD_RUNTIME_CROSS_DEVICE_WINDOWS_SUCCESS=true');
  }, timeout: const Timeout(Duration(minutes: 9)));
}

final class _FilePluginSenderGateway implements LanSyncGateway, LanSyncPairedGateway {
  const _FilePluginSenderGateway(this.artifact);

  final File artifact;

  @override
  Future<LanSyncManifest> createManifest() => createPairedManifest();

  @override
  Future<LanSyncManifest> createPairedManifest({
    bool includePlugins = true,
    bool includeShelf = true,
    bool deferPluginArtifacts = false,
  }) async => LanSyncManifest(
    plugins: includePlugins
        ? const <LanSyncPluginDescriptor>[
            LanSyncPluginDescriptor(
              id: _pluginId,
              version: _pluginVersion,
              bytes: 0,
              artifactFormat: LanSyncPluginArtifactFormat.singleFile,
              sha256: '0000000000000000000000000000000000000000000000000000000000000000',
              transferable: true,
              deferred: true,
              displayName: '发现组件演示',
            ),
          ]
        : const <LanSyncPluginDescriptor>[],
    shelfItems: includeShelf
        ? <LanSyncShelfItem>[
            LanSyncShelfItem(
              pluginId: _pluginId,
              pluginVersion: _pluginVersion,
              remoteContentId: 'book:cross-device-runtime',
              contentKind: 'novel',
              title: '跨设备同步测试书籍',
              author: 'MgRead Test',
              progress: LanSyncReadingProgress(
                chapterId: 'chapter:2',
                paragraphId: 'paragraph:3',
                characterOffset: 17,
                chapterIndex: 1,
                chapterFraction: 0.25,
                bookFraction: 0.125,
                updatedAtUtc: DateTime.utc(2026, 9, 8, 4),
                totalReadingSeconds: 180,
              ),
            ),
          ]
        : const <LanSyncShelfItem>[],
    skippedShelfItems: 0,
  );

  @override
  Future<LanSyncMaterializedPlugin> materializePluginArchive(LanSyncPluginDescriptor plugin) async {
    final bytes = await artifact.readAsBytes();
    return LanSyncMaterializedPlugin(
      descriptor: LanSyncPluginDescriptor(
        id: plugin.id,
        version: plugin.version,
        bytes: bytes.length,
        artifactFormat: plugin.artifactFormat,
        sha256: sha256.convert(bytes).toString(),
        transferable: true,
        displayName: plugin.displayName,
      ),
      bytes: artifact.openRead(),
    );
  }

  @override
  Future<LanSyncImportPreview> previewImport(LanSyncManifest manifest, {bool force = false}) async => LanSyncImportPreview(
    newItemCount: 0,
    conflicts: <LanSyncBookConflict>[],
    blockedItemCount: 0,
    pluginPlans: <String, LanSyncPluginPlanState>{},
  );

  @override
  Future<void> preparePluginImports(List<LanSyncPluginDescriptor> plugins, {Set<String> forceUpgradePluginIds = const <String>{}}) async {}

  @override
  Future<void> importPluginArchive(LanSyncPluginDescriptor plugin, Stream<List<int>> bytes) async =>
      throw UnsupportedError('The Windows test endpoint is send-only.');

  @override
  Future<LanSyncPluginImportResult> finishPluginImports() async => const LanSyncPluginImportResult.empty();

  @override
  Future<LanSyncApplyResult> applyImport({
    required LanSyncManifest manifest,
    required Map<String, LanSyncConflictChoice> conflictChoices,
    required Set<String> availablePluginIds,
    required LanSyncPluginImportResult pluginResult,
    bool force = false,
  }) async =>
      const LanSyncApplyResult(added: 0, updated: 0, keptLocal: 0, blocked: 0, pluginInstalled: 0, pluginSkipped: 0, pluginFailed: 0);

  @override
  Future<void> cancelPluginImports() async {}

  @override
  Future<Stream<List<int>>> openPluginArchive(LanSyncPluginDescriptor plugin) async => artifact.openRead();
}
