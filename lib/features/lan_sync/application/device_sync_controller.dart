/// 应用级已配对设备与自动同步协调器。
///
/// 职责：
/// - 管理首次配对、持久设备策略、前台发现和手动拉取。
/// - 串行化所有入站/出站同步，避免 Runtime 批量导入状态互相覆盖。
/// - 两端在线时由稳定设备 ID 决定唯一自动发起方，并在开发书源变化后立即推动一次同步。
///
/// 注意：
/// - Provider 非 autoDispose；离开设置页只取消未完成的首次配对，不停止前台同步宿主。
/// - endpoint 仅保存在内存，设备信任和 IP 完全解耦。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/lan_sync/application/device_identity_store.dart';
import 'package:mg_read/features/lan_sync/application/lan_sync_gateway.dart';
import 'package:mg_read/features/lan_sync/application/paired_device_repository.dart';
import 'package:mg_read/features/lan_sync/data/lan_pairing_transport.dart';
import 'package:mg_read/features/lan_sync/data/paired_sync_transport.dart';
import 'package:mg_read/features/lan_sync/domain/lan_pairing_payload.dart';
import 'package:mg_read/features/lan_sync/domain/paired_device_models.dart';
import 'package:mg_read/features/library/application/library_page_controller.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';

final deviceSyncControllerProvider = NotifierProvider<DeviceSyncController, DeviceSyncState>(DeviceSyncController.new);

enum DevicePairingPhase { idle, creatingOffer, showingOffer, confirming, joining, waitingApproval, completed, failed }

final class DeviceSyncState {
  const DeviceSyncState({
    this.devices = const <PairedDevice>[],
    this.onlineDeviceIds = const <String>{},
    this.busyDeviceId,
    this.lastMessage,
    this.lastErrorCode,
    this.pairingPhase = DevicePairingPhase.idle,
    this.pairingOffer,
    this.pairingCode,
    this.pairingPeer,
    this.started = false,
  });

  final List<PairedDevice> devices;
  final Set<String> onlineDeviceIds;
  final String? busyDeviceId;
  final String? lastMessage;
  final String? lastErrorCode;
  final DevicePairingPhase pairingPhase;
  final LanPairingOffer? pairingOffer;
  final String? pairingCode;
  final PairedDevice? pairingPeer;
  final bool started;

  bool get pairingBusy => switch (pairingPhase) {
    DevicePairingPhase.creatingOffer ||
    DevicePairingPhase.showingOffer ||
    DevicePairingPhase.confirming ||
    DevicePairingPhase.joining ||
    DevicePairingPhase.waitingApproval => true,
    _ => false,
  };

  DeviceSyncState copyWith({
    List<PairedDevice>? devices,
    Set<String>? onlineDeviceIds,
    Object? busyDeviceId = _unchanged,
    Object? lastMessage = _unchanged,
    Object? lastErrorCode = _unchanged,
    DevicePairingPhase? pairingPhase,
    Object? pairingOffer = _unchanged,
    Object? pairingCode = _unchanged,
    Object? pairingPeer = _unchanged,
    bool? started,
  }) => DeviceSyncState(
    devices: devices ?? this.devices,
    onlineDeviceIds: onlineDeviceIds ?? this.onlineDeviceIds,
    busyDeviceId: identical(busyDeviceId, _unchanged) ? this.busyDeviceId : busyDeviceId as String?,
    lastMessage: identical(lastMessage, _unchanged) ? this.lastMessage : lastMessage as String?,
    lastErrorCode: identical(lastErrorCode, _unchanged) ? this.lastErrorCode : lastErrorCode as String?,
    pairingPhase: pairingPhase ?? this.pairingPhase,
    pairingOffer: identical(pairingOffer, _unchanged) ? this.pairingOffer : pairingOffer as LanPairingOffer?,
    pairingCode: identical(pairingCode, _unchanged) ? this.pairingCode : pairingCode as String?,
    pairingPeer: identical(pairingPeer, _unchanged) ? this.pairingPeer : pairingPeer as PairedDevice?,
    started: started ?? this.started,
  );
}

const Object _unchanged = Object();

final class DeviceSyncController extends Notifier<DeviceSyncState> {
  final Map<String, PairedSyncEndpoint> _endpoints = <String, PairedSyncEndpoint>{};
  final Map<String, DateTime> _lastAttemptAt = <String, DateTime>{};
  Future<void>? _startFuture;
  LocalDeviceIdentity? _identity;
  PairedSyncHost? _host;
  StreamSubscription<PairedSyncEndpoint>? _endpointSubscription;
  Timer? _endpointExpiryTimer;
  String? _activeDeviceId;
  LanPairingServer? _pairingServer;
  StreamSubscription<LanPairingRequest>? _pairingSubscription;
  LanPairingRequest? _pairingRequest;
  LanPairingClientConnection? _pairingClient;
  int _pairingGeneration = 0;
  bool _disposed = false;
  bool _foregroundDesired = false;

  @override
  DeviceSyncState build() {
    _disposed = false;
    ref.onDispose(() {
      _disposed = true;
      _pairingGeneration++;
      unawaited(_stopResources());
    });
    return const DeviceSyncState();
  }

  Future<void> start() {
    _foregroundDesired = true;
    return _startFuture ??= _start();
  }

  Future<void> _start() async {
    if (_host != null) return;
    try {
      final devices = ref.read(pairedDeviceRepositoryProvider);
      final identityStore = ref.read(deviceIdentityStoreProvider);
      final identity = await identityStore.loadOrCreateIdentity();
      final saved = await devices.list();
      _identity = identity;
      if (!_foregroundDesired || _disposed) return;
      if (saved.isNotEmpty) await _ensureHost();
      if (_disposed || !_foregroundDesired) {
        await _closeHost();
        return;
      }
      state = state.copyWith(devices: saved, started: true, lastErrorCode: null);
    } on Object {
      _startFuture = null;
      if (!_disposed) {
        state = state.copyWith(started: false, lastErrorCode: 'device_sync_start_failed', lastMessage: '自动同步服务暂时无法启动');
      }
    }
  }

  Future<void> stop() async {
    _foregroundDesired = false;
    _startFuture = null;
    await _closeHost();
    _endpoints.clear();
    if (!_disposed) state = state.copyWith(onlineDeviceIds: const <String>{}, started: false);
  }

  Future<void> _closeHost() async {
    _endpointExpiryTimer?.cancel();
    _endpointExpiryTimer = null;
    final subscription = _endpointSubscription;
    _endpointSubscription = null;
    await subscription?.cancel();
    final host = _host;
    _host = null;
    await host?.close();
  }

  Future<void> reloadDevices() async {
    final devices = await ref.read(pairedDeviceRepositoryProvider).list();
    if (devices.isEmpty) {
      await _closeHost();
      _endpoints.clear();
    } else if (_host == null) {
      await _ensureHost();
    }
    state = state.copyWith(devices: devices, onlineDeviceIds: _onlineIds());
  }

  Future<void> _ensureHost() async {
    if (_host != null || _disposed || !_foregroundDesired) return;
    final identity = _identity ?? await ref.read(deviceIdentityStoreProvider).loadOrCreateIdentity();
    _identity = identity;
    final host = await PairedSyncHost.start(
      identity: identity,
      devices: ref.read(pairedDeviceRepositoryProvider),
      identityStore: ref.read(deviceIdentityStoreProvider),
      onIncoming: _handleIncoming,
    );
    if (_disposed || !_foregroundDesired) {
      await host.close();
      return;
    }
    _host = host;
    _endpointSubscription = host.endpoints.listen(_handleEndpoint);
    _endpointExpiryTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!_disposed) state = state.copyWith(onlineDeviceIds: _onlineIds());
    });
  }

  Future<void> beginPairing() async {
    final generation = ++_pairingGeneration;
    await _closePairingResources();
    state = state.copyWith(
      pairingPhase: DevicePairingPhase.creatingOffer,
      pairingOffer: null,
      pairingCode: null,
      pairingPeer: null,
      lastErrorCode: null,
    );
    try {
      final identity = _identity ?? await ref.read(deviceIdentityStoreProvider).loadOrCreateIdentity();
      _identity = identity;
      if (generation != _pairingGeneration) return;
      final server = await LanPairingServer.start(identity);
      if (generation != _pairingGeneration) {
        await server.close();
        return;
      }
      _pairingServer = server;
      _pairingSubscription = server.requests.listen(_handlePairingRequest);
      state = state.copyWith(pairingPhase: DevicePairingPhase.showingOffer, pairingOffer: server.offer);
    } on Object {
      if (generation == _pairingGeneration) _pairingFailed('device_pairing_offer_failed');
    }
  }

  void _handlePairingRequest(LanPairingRequest request) {
    final previous = _pairingRequest;
    if (previous != null) {
      unawaited(request.reject());
      return;
    }
    _pairingRequest = request;
    state = state.copyWith(pairingPhase: DevicePairingPhase.confirming, pairingCode: request.pairingCode, pairingPeer: request.peer);
  }

  Future<void> approvePairing() async {
    final request = _pairingRequest;
    if (request == null || state.pairingPhase != DevicePairingPhase.confirming) return;
    try {
      await _savePairing(request.peer, request.sharedSecret);
      await request.approve();
      _pairingRequest = null;
      await _closePairingResources();
      await reloadDevices();
      state = state.copyWith(
        pairingPhase: DevicePairingPhase.completed,
        pairingOffer: null,
        pairingCode: null,
        pairingPeer: request.peer,
        lastMessage: '已配对 ${request.peer.label}，以后无需发送端确认',
      );
    } on Object {
      await request.reject();
      _pairingFailed('device_pairing_save_failed');
    }
  }

  Future<void> rejectPairing() async {
    final request = _pairingRequest;
    _pairingRequest = null;
    await request?.reject();
    state = state.copyWith(pairingPhase: DevicePairingPhase.showingOffer, pairingCode: null, pairingPeer: null);
  }

  Future<void> joinPairing(String payload) async {
    final offer = LanPairingQrPayload.decode(payload);
    if (offer == null) {
      _pairingFailed('device_pairing_qr_invalid');
      return;
    }
    final generation = ++_pairingGeneration;
    await _closePairingResources();
    state = state.copyWith(
      pairingPhase: DevicePairingPhase.joining,
      pairingOffer: null,
      pairingCode: null,
      pairingPeer: null,
      lastErrorCode: null,
    );
    try {
      final identity = _identity ?? await ref.read(deviceIdentityStoreProvider).loadOrCreateIdentity();
      _identity = identity;
      final client = await LanPairingClientConnection.connect(offer, identity);
      if (generation != _pairingGeneration) {
        await client.close();
        return;
      }
      _pairingClient = client;
      state = state.copyWith(pairingPhase: DevicePairingPhase.waitingApproval, pairingCode: client.pairingCode, pairingPeer: client.peer);
      final peer = await client.waitForApproval();
      if (generation != _pairingGeneration) return;
      _pairingClient = null;
      await _savePairing(peer, client.sharedSecret);
      await reloadDevices();
      state = state.copyWith(
        pairingPhase: DevicePairingPhase.completed,
        pairingCode: null,
        pairingPeer: peer,
        lastMessage: '已配对 ${peer.label}，可立即拉取或等待自动同步',
      );
    } on Object {
      if (generation == _pairingGeneration) _pairingFailed('device_pairing_failed');
    }
  }

  Future<void> cancelPairing() async {
    _pairingGeneration++;
    await _closePairingResources();
    state = state.copyWith(pairingPhase: DevicePairingPhase.idle, pairingOffer: null, pairingCode: null, pairingPeer: null);
  }

  Future<void> updateDevice(PairedDevice device) async {
    await ref.read(pairedDeviceRepositoryProvider).upsert(device);
    await reloadDevices();
  }

  Future<void> removeDevice(String deviceId) async {
    await ref.read(pairedDeviceRepositoryProvider).remove(deviceId);
    await ref.read(deviceIdentityStoreProvider).deletePeerSecret(deviceId);
    _endpoints.remove(deviceId);
    await reloadDevices();
  }

  Future<void> syncNow(String deviceId, {bool pullOnly = true}) async {
    await start();
    final device = _device(deviceId);
    if (device == null) return;
    final endpoint = _endpoints[deviceId];
    if (endpoint == null || endpoint.expiresAtUtc.isBefore(DateTime.now().toUtc())) {
      state = state.copyWith(lastErrorCode: 'lan_sync_peer_offline', lastMessage: '${device.label} 当前不在线');
      return;
    }
    await _runOutbound(device, endpoint, pullOnly: pullOnly);
  }

  Future<void> syncAvailablePeers({bool pushChanges = false}) async {
    await start();
    final now = DateTime.now().toUtc();
    for (final device in state.devices) {
      final endpoint = _endpoints[device.deviceId];
      if (!device.autoSync || endpoint == null || endpoint.expiresAtUtc.isBefore(now)) continue;
      if (!pushChanges && (_identity?.deviceId.compareTo(device.deviceId) ?? 1) >= 0) continue;
      await _runOutbound(device, endpoint, pullOnly: false);
    }
  }

  void _handleEndpoint(PairedSyncEndpoint endpoint) {
    final device = _device(endpoint.deviceId);
    if (device == null) return;
    _endpoints[endpoint.deviceId] = endpoint;
    state = state.copyWith(onlineDeviceIds: _onlineIds());
    final now = DateTime.now().toUtc();
    final lastAttempt = _lastAttemptAt[endpoint.deviceId];
    if (!device.autoSync ||
        _activeDeviceId != null ||
        (_identity?.deviceId.compareTo(device.deviceId) ?? 1) >= 0 ||
        (lastAttempt != null && now.difference(lastAttempt) < const Duration(seconds: 20))) {
      return;
    }
    unawaited(_runOutbound(device, endpoint, pullOnly: false));
  }

  Future<void> _runOutbound(PairedDevice device, PairedSyncEndpoint endpoint, {required bool pullOnly}) async {
    if (_activeDeviceId != null) return;
    _activeDeviceId = device.deviceId;
    _lastAttemptAt[device.deviceId] = DateTime.now().toUtc();
    state = state.copyWith(busyDeviceId: device.deviceId, lastErrorCode: null, lastMessage: '正在与 ${device.label} 同步');
    try {
      final secret = await ref.read(deviceIdentityStoreProvider).readPeerSecret(device.deviceId);
      final identity = _identity ?? await ref.read(deviceIdentityStoreProvider).loadOrCreateIdentity();
      if (secret == null) throw StateError('paired_secret_missing');
      final session = await PairedSyncClientSession.connectAny(
        endpoints: <PairedSyncEndpoint>[endpoint],
        identity: identity,
        peer: device,
        sharedSecret: secret,
      );
      final summary = await session.run(gateway: ref.read(lanSyncGatewayProvider), pullOnly: pullOnly);
      await _recordResultSafely(device, PairedSyncResultState.success);
      _refreshAfterSync();
      state = state.copyWith(lastMessage: _summaryMessage(device.label, summary), lastErrorCode: null);
    } on Object {
      await _recordResultSafely(device, PairedSyncResultState.failed);
      state = state.copyWith(lastErrorCode: 'device_sync_failed', lastMessage: '与 ${device.label} 同步失败，稍后会自动重试');
    } finally {
      _activeDeviceId = null;
      state = state.copyWith(busyDeviceId: null);
    }
  }

  Future<void> _handleIncoming(PairedSyncServerSession session) async {
    final device = _device(session.peer.deviceId) ?? session.peer;
    if (_activeDeviceId != null) {
      await session.rejectBusy();
      return;
    }
    _activeDeviceId = device.deviceId;
    state = state.copyWith(busyDeviceId: device.deviceId, lastErrorCode: null, lastMessage: '正在与 ${device.label} 同步');
    try {
      final summary = await session.run(gateway: ref.read(lanSyncGatewayProvider));
      await _recordResultSafely(device, PairedSyncResultState.success);
      _refreshAfterSync();
      state = state.copyWith(lastMessage: _summaryMessage(device.label, summary), lastErrorCode: null);
    } on Object {
      await session.close();
      await _recordResultSafely(device, PairedSyncResultState.failed);
      state = state.copyWith(lastErrorCode: 'device_sync_failed', lastMessage: '与 ${device.label} 同步失败，稍后会自动重试');
    } finally {
      _activeDeviceId = null;
      state = state.copyWith(busyDeviceId: null);
    }
  }

  Future<void> _recordResult(PairedDevice device, PairedSyncResultState result) async {
    final updated = device.copyWith(lastSeenAtUtc: DateTime.now().toUtc(), lastSyncAtUtc: DateTime.now().toUtc(), lastSyncResult: result);
    await ref.read(pairedDeviceRepositoryProvider).upsert(updated);
    await reloadDevices();
  }

  Future<void> _recordResultSafely(PairedDevice device, PairedSyncResultState result) async {
    try {
      await _recordResult(device, result);
    } on Object {
      // 同步结果已经确定；仅记录摘要失败不能制造未处理异常或覆盖业务终态。
    }
  }

  Future<void> _savePairing(PairedDevice peer, List<int> secret) async {
    final store = ref.read(deviceIdentityStoreProvider);
    await store.writePeerSecret(peer.deviceId, secret);
    try {
      await ref.read(pairedDeviceRepositoryProvider).upsert(peer);
    } on Object {
      await store.deletePeerSecret(peer.deviceId);
      rethrow;
    }
  }

  void _refreshAfterSync() {
    ref.invalidate(pluginRuntimeConnectionProvider);
    ref.invalidate(pluginRuntimeStatusProvider);
    ref.invalidate(availablePluginSourcesProvider);
    ref.invalidate(libraryPageControllerProvider);
    ref.invalidate(privateLibraryPageControllerProvider);
  }

  PairedDevice? _device(String deviceId) {
    for (final device in state.devices) {
      if (device.deviceId == deviceId) return device;
    }
    return null;
  }

  Set<String> _onlineIds() {
    final now = DateTime.now().toUtc();
    _endpoints.removeWhere((_, endpoint) => endpoint.expiresAtUtc.isBefore(now));
    return Set<String>.unmodifiable(_endpoints.keys.where((id) => _device(id) != null));
  }

  void _pairingFailed(String code) {
    unawaited(_closePairingResources());
    state = state.copyWith(
      pairingPhase: DevicePairingPhase.failed,
      pairingOffer: null,
      pairingCode: null,
      pairingPeer: null,
      lastErrorCode: code,
    );
  }

  Future<void> _closePairingResources() async {
    final subscription = _pairingSubscription;
    _pairingSubscription = null;
    await subscription?.cancel();
    final request = _pairingRequest;
    _pairingRequest = null;
    await request?.reject();
    final client = _pairingClient;
    _pairingClient = null;
    await client?.close();
    final server = _pairingServer;
    _pairingServer = null;
    await server?.close();
  }

  Future<void> _stopResources() async {
    await _closePairingResources();
    await stop();
  }
}

String _summaryMessage(String label, PairedSyncRunSummary summary) {
  final changes = summary.receivedBooks + summary.receivedPlugins + summary.sentBooks + summary.sentPlugins;
  if (summary.developmentConflicts > 0) {
    return '$label 同步完成；${summary.developmentConflicts} 个开发书源存在双端修改，已保留两端现状';
  }
  if (changes == 0) return '$label 已是最新状态';
  return '$label 同步完成：接收 ${summary.receivedPlugins} 个插件、${summary.receivedBooks} 本书架更新';
}
