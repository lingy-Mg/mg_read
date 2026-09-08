/// Windows 与 Android 跨设备配对同步测试的共享数据和内存网关。
///
/// 网关只替代本地持久化与 Runtime；发现、HMAC、HTTP v4 会话、任务清单、
/// 双向插件制品传输及提交确认全部使用生产实现。
library;

import 'dart:async';

import 'package:crypto/crypto.dart';

import 'package:mg_read/features/lan_sync/application/device_identity_store.dart';
import 'package:mg_read/features/lan_sync/application/lan_sync_gateway.dart';
import 'package:mg_read/features/lan_sync/application/paired_device_repository.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_models.dart';
import 'package:mg_read/features/lan_sync/domain/paired_device_models.dart';

const LocalDeviceIdentity crossDeviceWindowsIdentity = LocalDeviceIdentity(deviceId: 'windows_cross_device_123456', label: 'Windows 测试端');
const LocalDeviceIdentity crossDeviceAndroidIdentity = LocalDeviceIdentity(deviceId: 'android_cross_device_123456', label: 'MuMu 测试端');

List<int> crossDeviceSecret() => List<int>.generate(32, (index) => index + 71);

PairedDevice crossDevicePeer(LocalDeviceIdentity identity, PairedDevicePlatform platform) => PairedDevice(
  autoSync: false,
  createdAtUtc: DateTime.utc(2026, 9, 8),
  deviceId: identity.deviceId,
  label: identity.label,
  mode: PairedSyncMode.bidirectional,
  platform: platform,
  syncBookshelf: true,
  syncPlugins: true,
);

final class CrossDevicePairedRepository implements PairedDeviceRepository {
  CrossDevicePairedRepository(PairedDevice peer) : _peer = peer;

  PairedDevice? _peer;

  @override
  Future<List<PairedDevice>> list() async => <PairedDevice>[?_peer];

  @override
  Future<PairedDevice?> read(String deviceId) async => _peer?.deviceId == deviceId ? _peer : null;

  @override
  Future<void> remove(String deviceId) async {
    if (_peer?.deviceId == deviceId) _peer = null;
  }

  @override
  Future<void> upsert(PairedDevice device) async => _peer = device;
}

final class CrossDeviceIdentityStore implements DeviceIdentityStore {
  CrossDeviceIdentityStore(this.identity, this.peerDeviceId);

  final LocalDeviceIdentity identity;
  final String peerDeviceId;
  List<int>? _secret = crossDeviceSecret();

  @override
  Future<void> deletePeerSecret(String peerDeviceId) async {
    if (peerDeviceId == this.peerDeviceId) _secret = null;
  }

  @override
  Future<LocalDeviceIdentity> loadOrCreateIdentity() async => identity;

  @override
  Future<List<int>?> readPeerSecret(String peerDeviceId) async => peerDeviceId == this.peerDeviceId ? _secret : null;

  @override
  Future<void> writePeerSecret(String peerDeviceId, List<int> secret) async {
    if (peerDeviceId == this.peerDeviceId) _secret = List<int>.from(secret);
  }
}

final class CrossDeviceSyncGateway implements LanSyncGateway, LanSyncPairedGateway {
  CrossDeviceSyncGateway({required this.side, required this.pluginIds});

  final String side;
  final List<String> pluginIds;
  final List<LanSyncShelfItem> appliedShelfItems = <LanSyncShelfItem>[];
  final Set<String> importedPluginIds = <String>{};
  Set<String> _preparedPluginIds = <String>{};

  @override
  Future<LanSyncManifest> createManifest() => createPairedManifest();

  @override
  Future<LanSyncManifest> createPairedManifest({
    bool includePlugins = true,
    bool includeShelf = true,
    bool deferPluginArtifacts = false,
  }) async => LanSyncManifest(
    plugins: includePlugins ? <LanSyncPluginDescriptor>[for (final id in pluginIds) _offer(id)] : const <LanSyncPluginDescriptor>[],
    shelfItems: includeShelf
        ? <LanSyncShelfItem>[
            LanSyncShelfItem(
              pluginId: pluginIds.first,
              pluginVersion: '1.0.0',
              remoteContentId: '$side-book',
              contentKind: 'novel',
              title: '$side 书架元信息',
              progress: LanSyncReadingProgress(
                chapterId: '$side-chapter-2',
                paragraphId: '$side-paragraph-3',
                characterOffset: 19,
                chapterIndex: 1,
                chapterFraction: 0.3,
                bookFraction: 0.2,
                updatedAtUtc: DateTime.utc(2026, 9, 8, 3),
                totalReadingSeconds: 120,
              ),
            ),
          ]
        : const <LanSyncShelfItem>[],
    skippedShelfItems: 0,
  );

  @override
  Future<LanSyncMaterializedPlugin> materializePluginArchive(LanSyncPluginDescriptor plugin) async {
    final bytes = _artifactBytes(plugin.id);
    return LanSyncMaterializedPlugin(
      descriptor: LanSyncPluginDescriptor(
        id: plugin.id,
        version: plugin.version,
        bytes: bytes.length,
        artifactFormat: plugin.artifactFormat,
        sha256: sha256.convert(bytes).toString(),
        transferable: true,
        displayName: plugin.displayName,
        provenance: plugin.provenance,
      ),
      bytes: Stream<List<int>>.fromIterable(<List<int>>[
        for (var offset = 0; offset < bytes.length; offset += 64 * 1024) bytes.sublist(offset, (offset + 64 * 1024).clamp(0, bytes.length)),
      ]),
    );
  }

  @override
  Future<LanSyncImportPreview> previewImport(LanSyncManifest manifest, {bool force = false}) async => LanSyncImportPreview(
    newItemCount: manifest.shelfItems.length,
    conflicts: const <LanSyncBookConflict>[],
    blockedItemCount: 0,
    pluginPlans: <String, LanSyncPluginPlanState>{for (final plugin in manifest.plugins) plugin.id: LanSyncPluginPlanState.missing},
    selectedShelfItemIds: <String>{for (final item in manifest.shelfItems) item.identity},
  );

  @override
  Future<void> preparePluginImports(List<LanSyncPluginDescriptor> plugins, {Set<String> forceUpgradePluginIds = const <String>{}}) async {
    _preparedPluginIds = plugins.map((plugin) => plugin.id).toSet();
  }

  @override
  Future<void> importPluginArchive(LanSyncPluginDescriptor plugin, Stream<List<int>> bytes) async {
    if (!_preparedPluginIds.contains(plugin.id)) throw StateError('cross_device_plugin_not_prepared');
    final received = <int>[];
    await for (final chunk in bytes) {
      received.addAll(chunk);
    }
    if (received.length != plugin.bytes || sha256.convert(received).toString() != plugin.sha256) {
      throw StateError('cross_device_plugin_invalid');
    }
    importedPluginIds.add(plugin.id);
  }

  @override
  Future<LanSyncPluginImportResult> finishPluginImports() async => LanSyncPluginImportResult(
    availablePluginIds: <String>{...pluginIds, ...importedPluginIds},
    installed: importedPluginIds.length,
    skipped: 0,
    failed: 0,
  );

  @override
  Future<LanSyncApplyResult> applyImport({
    required LanSyncManifest manifest,
    required Map<String, LanSyncConflictChoice> conflictChoices,
    required Set<String> availablePluginIds,
    required LanSyncPluginImportResult pluginResult,
    bool force = false,
  }) async {
    appliedShelfItems.addAll(manifest.shelfItems);
    return LanSyncApplyResult(
      added: manifest.shelfItems.length,
      updated: 0,
      keptLocal: 0,
      blocked: 0,
      pluginInstalled: pluginResult.installed,
      pluginSkipped: pluginResult.skipped,
      pluginFailed: pluginResult.failed,
    );
  }

  @override
  Future<void> cancelPluginImports() async => _preparedPluginIds = <String>{};

  @override
  Future<Stream<List<int>>> openPluginArchive(LanSyncPluginDescriptor plugin) async =>
      throw UnsupportedError('Paired sync must materialize the selected task.');
}

LanSyncPluginDescriptor _offer(String id) => LanSyncPluginDescriptor(
  id: id,
  version: '1.0.0',
  bytes: 0,
  artifactFormat: LanSyncPluginArtifactFormat.archive,
  sha256: ''.padLeft(64, '0'),
  transferable: true,
  deferred: true,
  displayName: id,
);

List<int> _artifactBytes(String pluginId) => List<int>.generate(256 * 1024, (index) => (index + pluginId.length) % 251);
