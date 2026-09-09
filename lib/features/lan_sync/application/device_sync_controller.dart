/// 应用级已配对设备与自动同步协调器。
///
/// 职责：
/// - 管理首次配对、持久设备策略、前台发现和手动同步/拉取/推送。
/// - 串行化所有入站/出站同步，避免 Runtime 批量导入状态互相覆盖。
/// - 桌面端/Android 由桌面端自动发起；同平台用稳定设备 ID 选主，避免双向重复同步。
/// - 开发书源变化由桌面立即推动，Android 合并延迟后再推送，手动操作始终即时执行。
/// - 在线设备只公布可用 App 版本；App 拉取和安装必须由用户显式触发。
///
/// 注意：
/// - Provider 非 autoDispose；离开设置页只取消未完成的首次配对，不停止前台同步宿主。
/// - endpoint 仅保存在内存，设备信任和 IP 完全解耦。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/lan_sync/application/app_update_service.dart';
import 'package:mg_read/features/lan_sync/application/device_identity_store.dart';
import 'package:mg_read/features/lan_sync/application/lan_sync_gateway.dart';
import 'package:mg_read/features/lan_sync/application/lan_sync_session.dart';
import 'package:mg_read/features/lan_sync/application/lan_sync_screen_awake.dart';
import 'package:mg_read/features/lan_sync/application/paired_sync_completion.dart';
import 'package:mg_read/features/lan_sync/application/lan_sync_network_environment.dart';
import 'package:mg_read/features/lan_sync/application/paired_device_repository.dart';
import 'package:mg_read/features/lan_sync/application/paired_sync_failure.dart';
import 'package:mg_read/features/lan_sync/data/lan_pairing_transport.dart';
import 'package:mg_read/features/lan_sync/data/lan_sync_transport.dart';
import 'package:mg_read/features/lan_sync/data/paired_sync_transport.dart';
import 'package:mg_read/features/lan_sync/domain/lan_pairing_payload.dart';
import 'package:mg_read/features/lan_sync/domain/app_update_models.dart';
import 'package:mg_read/features/lan_sync/domain/paired_device_models.dart';
import 'package:mg_read/features/library/application/library_page_controller.dart';
import 'package:mg_read/features/library/application/library_page_state.dart';

part 'device_sync_messages.dart';
part 'device_sync_network.dart';
part 'device_sync_operations.dart';
part 'device_sync_pairing.dart';
part 'device_sync_state.dart';

final deviceSyncControllerProvider = NotifierProvider<DeviceSyncController, DeviceSyncState>(DeviceSyncController.new);

final class DeviceSyncController extends _DeviceSyncOperationsBase {
  @override
  final Map<String, PairedSyncEndpoint> _endpoints = <String, PairedSyncEndpoint>{};
  @override
  final Map<String, int> _retryFailures = <String, int>{};
  @override
  final Map<String, Timer> _retryTimers = <String, Timer>{};
  @override
  final Map<String, _PendingWakeRequest> _pendingWakeRequests = <String, _PendingWakeRequest>{};
  Future<void> _repositoryMutation = Future<void>.value();
  Future<void>? _startFuture;
  Future<void>? _hostStartFuture;
  @override
  LocalDeviceIdentity? _identity;
  @override
  PairedSyncHost? _host;
  StreamSubscription<PairedSyncEndpoint>? _endpointSubscription;
  Timer? _endpointExpiryTimer;
  Timer? _reconciliationTimer;
  @override
  Timer? _networkProbeTimer;
  @override
  Timer? _mobileDevelopmentSyncTimer;
  @override
  Future<bool>? _networkRefreshFuture;
  @override
  String? _activeDeviceId;
  @override
  LanPairingServer? _pairingServer;
  @override
  StreamSubscription<LanPairingRequest>? _pairingSubscription;
  @override
  LanPairingRequest? _pairingRequest;
  @override
  LanPairingClientConnection? _pairingClient;
  @override
  int _pairingGeneration = 0;
  @override
  bool _disposed = false;
  @override
  bool _networkAvailable = false;
  @override
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
      AppVersionInfo? localAppVersion;
      try {
        localAppVersion = await ref.read(appUpdateServiceProvider).currentVersion();
      } on Object {
        // App 版本探测失败不能阻断既有的数据同步宿主。
      }
      _identity = identity;
      if (!_foregroundDesired || _disposed) return;
      state = state.copyWith(devices: saved, localAppVersion: localAppVersion);
      if (saved.isNotEmpty) _startNetworkMonitor();
      if (saved.isNotEmpty) {
        _networkAvailable = await _readNetworkAvailability();
        if (_networkAvailable) await _ensureHost();
      }
      if (_disposed || !_foregroundDesired) {
        await _closeHost();
        return;
      }
      state = state.copyWith(
        devices: saved,
        started: true,
        lastErrorCode: null,
        lastMessage: saved.isNotEmpty && !_networkAvailable
            ? Platform.isAndroid
                  ? '等待 Wi-Fi 连接后自动同步'
                  : '等待可用局域网连接后自动同步'
            : null,
      );
    } on Object catch (error, stackTrace) {
      _startFuture = null;
      if (!_disposed) {
        final failure = PairedSyncFailure.fromException(
          stage: 'host_start',
          error: error,
          stackTrace: stackTrace,
          code: 'device_sync_start_failed',
        );
        final diagnostics = PairedSyncDiagnosticSession.start(
          ref.read(diagnosticsManagerProvider),
          role: 'paired_host',
          operation: PairedSyncOperation.bidirectional,
          automatic: true,
          peerPlatform: PairedDevicePlatform.unknown,
        )..stage('host_start');
        diagnostics.fail(failure);
        state = state.copyWith(
          started: false,
          lastErrorCode: failure.code,
          lastErrorDetails: failure.uiDetails,
          lastMessage: '自动同步服务无法启动，请查看下方原因',
        );
      }
    }
  }

  Future<void> stop() async {
    _foregroundDesired = false;
    _startFuture = null;
    _stopNetworkMonitor();
    await _closeHost();
    _endpoints.clear();
    if (!_disposed) state = state.copyWith(onlineDeviceIds: const <String>{}, started: false);
  }

  @override
  Future<void> _closeHost() async {
    final starting = _hostStartFuture;
    if (starting != null) {
      try {
        await starting;
      } on Object {
        // The start caller reports the stable failure state.
      }
    }
    _endpointExpiryTimer?.cancel();
    _endpointExpiryTimer = null;
    _reconciliationTimer?.cancel();
    _reconciliationTimer = null;
    for (final timer in _retryTimers.values) {
      timer.cancel();
    }
    _retryTimers.clear();
    _retryFailures.clear();
    final pendingWakeRequests = _pendingWakeRequests.values.toList(growable: false);
    _pendingWakeRequests.clear();
    for (final request in pendingWakeRequests) {
      final error = StateError('device_sync_stopped');
      final failure = PairedSyncFailure.fromException(
        stage: request.diagnostics.stageName,
        error: error,
        stackTrace: StackTrace.current,
        code: 'device_sync_stopped',
      );
      request.diagnostics.fail(failure);
      if (!request.completion.isCompleted) request.completion.completeError(error, StackTrace.current);
    }
    final subscription = _endpointSubscription;
    _endpointSubscription = null;
    await subscription?.cancel();
    final host = _host;
    _host = null;
    await host?.close();
  }

  @override
  Future<void> reloadDevices() async {
    final devices = await ref.read(pairedDeviceRepositoryProvider).list();
    state = state.copyWith(devices: devices);
    if (devices.isEmpty) {
      _stopNetworkMonitor();
      await _closeHost();
      _endpoints.clear();
    } else {
      _startNetworkMonitor();
      await _refreshNetworkAvailability();
    }
    state = state.copyWith(onlineDeviceIds: _onlineIds());
  }

  @override
  Future<void> _ensureHost() {
    final existing = _hostStartFuture;
    if (existing != null) return existing;
    final next = _startHost();
    _hostStartFuture = next;
    unawaited(
      next.then<void>(
        (_) {
          if (identical(_hostStartFuture, next)) _hostStartFuture = null;
        },
        onError: (Object _, StackTrace _) {
          if (identical(_hostStartFuture, next)) _hostStartFuture = null;
        },
      ),
    );
    return next;
  }

  Future<void> _startHost() async {
    if (_host != null || _disposed || !_foregroundDesired || !_networkAvailable) return;
    final identity = _identity ?? await ref.read(deviceIdentityStoreProvider).loadOrCreateIdentity();
    _identity = identity;
    final host = await PairedSyncHost.start(
      identity: identity,
      devices: ref.read(pairedDeviceRepositoryProvider),
      identityStore: ref.read(deviceIdentityStoreProvider),
      onIncoming: _handleIncoming,
      onWakeRequest: _handleWakeRequest,
      onWakeFailure: _handleWakeFailure,
      announcementInterval: _announcementInterval,
      advertisedPeerLifetime: _advertisedPeerLifetime,
      canAnnounce: _canAnnounce,
      appUpdates: ref.read(appUpdateServiceProvider),
    );
    if (_disposed || !_foregroundDesired) {
      await host.close();
      return;
    }
    _host = host;
    _endpointSubscription = host.endpoints.listen(_handleEndpoint);
    _endpointExpiryTimer = Timer.periodic(_endpointCheckInterval, (_) {
      if (!_disposed) state = state.copyWith(onlineDeviceIds: _onlineIds());
    });
    _reconciliationTimer = Timer.periodic(_reconciliationInterval, (_) {
      if (!_disposed && _foregroundDesired) {
        unawaited(syncAvailablePeers());
      }
    });
  }

  Future<void> updateDevice(PairedDevice device) async {
    await updateDeviceSettings(
      device.deviceId,
      autoSync: device.autoSync,
      mode: device.mode,
      syncBookshelf: device.syncBookshelf,
      syncPlugins: device.syncPlugins,
    );
  }

  Future<void> updateDeviceSettings(String deviceId, {bool? autoSync, PairedSyncMode? mode, bool? syncBookshelf, bool? syncPlugins}) async {
    await _serializeRepositoryMutation(() async {
      final repository = ref.read(pairedDeviceRepositoryProvider);
      final latest = await repository.read(deviceId);
      if (latest == null) return;
      await repository.upsert(latest.copyWith(autoSync: autoSync, mode: mode, syncBookshelf: syncBookshelf, syncPlugins: syncPlugins));
    });
    if (autoSync == false) {
      _retryTimers.remove(deviceId)?.cancel();
      _retryFailures.remove(deviceId);
    }
    await reloadDevices();
  }

  Future<void> removeDevice(String deviceId) async {
    await _serializeRepositoryMutation(() async {
      await ref.read(pairedDeviceRepositoryProvider).remove(deviceId);
      await ref.read(deviceIdentityStoreProvider).deletePeerSecret(deviceId);
    });
    _retryTimers.remove(deviceId)?.cancel();
    _retryFailures.remove(deviceId);
    _endpoints.remove(deviceId);
    await reloadDevices();
  }

  Future<void> syncNow(String deviceId, {PairedSyncOperation operation = PairedSyncOperation.push}) async {
    await start();
    final device = _device(deviceId);
    if (device == null) return;
    if (!_operationAllowed(device, operation)) {
      final failure = PairedSyncFailure.fromException(
        stage: 'policy',
        error: StateError('device_sync_operation_not_allowed'),
        stackTrace: StackTrace.current,
        code: 'device_sync_operation_not_allowed',
      );
      final diagnostics = _startPairedDiagnostics(device, operation: operation, automatic: false, role: 'paired_initiator');
      diagnostics.fail(failure);
      state = state.copyWith(
        lastErrorCode: failure.code,
        lastErrorDetails: failure.uiDetails,
        lastMessage: switch (operation) {
          PairedSyncOperation.pull => '设备策略已禁止拉取，请先将方向改为“双向”或“仅接收”',
          PairedSyncOperation.push => '设备策略已禁止推送，请先将方向改为“双向”或“仅发送”',
          PairedSyncOperation.bidirectional => '当前设备策略不允许双向同步，请先将方向改为“双向”',
        },
      );
      return;
    }
    if (!await _ensureNetworkForOperation(device, operation: operation, automatic: false)) return;
    final endpoint = _endpoints[deviceId];
    if (endpoint == null || endpoint.expiresAtUtc.isBefore(DateTime.now().toUtc())) {
      final failure = PairedSyncFailure.fromException(
        stage: 'discovery',
        error: StateError('lan_sync_peer_offline'),
        stackTrace: StackTrace.current,
        code: 'lan_sync_peer_offline',
      );
      final diagnostics = _startPairedDiagnostics(device, operation: operation, automatic: false, role: 'paired_initiator');
      diagnostics.fail(failure);
      _showFailure(device, failure, automatic: false);
      return;
    }
    await _runOperation(device, endpoint, operation: operation);
  }

  Future<void> installAppFrom(String deviceId, {required bool force}) async {
    await start();
    final device = _device(deviceId);
    final endpoint = _endpoints[deviceId];
    if (device == null || endpoint == null || endpoint.expiresAtUtc.isBefore(DateTime.now().toUtc())) {
      state = state.copyWith(lastErrorCode: 'lan_sync_peer_offline', lastMessage: '设备当前不在线，无法获取 App');
      return;
    }
    if (_activeDeviceId != null || state.busyDeviceId != null) return;
    _activeDeviceId = deviceId;
    state = state.copyWith(
      busyDeviceId: deviceId,
      busyMessage: '正在准备 App 安装包',
      lastErrorCode: null,
      lastMessage: '正在从 ${device.label} 获取 App',
    );
    final awake = LanSyncScreenAwake();
    try {
      final secret = await ref.read(deviceIdentityStoreProvider).readPeerSecret(deviceId);
      final identity = _identity ?? await ref.read(deviceIdentityStoreProvider).loadOrCreateIdentity();
      if (secret == null) throw StateError('paired_secret_missing');
      final appUpdates = ref.read(appUpdateServiceProvider);
      await appUpdates.ensureInstallPermission();
      await pullPairedAppUpdate(
        endpoint: endpoint,
        identity: identity,
        peer: device,
        sharedSecret: secret,
        service: appUpdates,
        force: force,
        onProgress: (bytes, total) {
          if (_disposed) return;
          final percent = total <= 0 ? 0 : (bytes * 100 ~/ total).clamp(0, 100);
          state = state.copyWith(busyMessage: percent >= 100 ? '安装包已校验，正在打开系统安装程序' : '正在下载 App · $percent%');
        },
      );
      if (!_disposed) {
        state = state.copyWith(lastMessage: '已打开系统安装程序，请按提示完成升级', lastErrorCode: null);
      }
    } on Object catch (error) {
      final code = _appUpdateFailureCode(error);
      if (!_disposed) {
        state = state.copyWith(lastErrorCode: code, lastMessage: _appUpdateFailureMessage(device.label, code));
      }
    } finally {
      await awake.close();
      _activeDeviceId = null;
      if (!_disposed) state = state.copyWith(busyDeviceId: null, busyMessage: null);
    }
  }

  Future<void> syncAvailablePeers({bool pushChanges = false}) async {
    await start();
    if (pushChanges && Platform.isAndroid) {
      _scheduleMobileDevelopmentSync();
      return;
    }
    await _syncAvailablePeersNow(pushChanges: pushChanges);
  }

  @override
  Future<void> _syncAvailablePeersNow({required bool pushChanges}) async {
    if (!await _refreshNetworkAvailability()) return;
    final now = DateTime.now().toUtc();
    for (final device in state.devices) {
      final endpoint = _endpoints[device.deviceId];
      if (!device.autoSync || endpoint == null || endpoint.expiresAtUtc.isBefore(now)) continue;
      if (!pushChanges && !_shouldAutomaticallyInitiate(device)) continue;
      await _runOperation(device, endpoint, operation: PairedSyncOperation.push, automatic: true);
    }
  }

  void _handleEndpoint(PairedSyncEndpoint endpoint) {
    var device = _device(endpoint.deviceId);
    if (device == null) return;
    if (endpoint.label != device.label) {
      device = device.copyWith(label: endpoint.label);
      state = state.copyWith(
        devices: <PairedDevice>[
          for (final saved in state.devices)
            if (saved.deviceId == device.deviceId) device else saved,
        ],
      );
      unawaited(_persistDiscoveredLabel(device));
    }
    final previous = _endpoints[endpoint.deviceId];
    final wasOnline = previous != null && previous.expiresAtUtc.isAfter(DateTime.now().toUtc());
    _endpoints[endpoint.deviceId] = endpoint;
    final localPlatform = state.localAppVersion?.platform;
    final appOffer = endpoint.appOffers.where((item) => item.version.platform == localPlatform).firstOrNull;
    final appOffers = <String, AppPackageOffer>{...state.appOffersByDeviceId};
    if (appOffer != null) appOffers[endpoint.deviceId] = appOffer;
    state = state.copyWith(onlineDeviceIds: _onlineIds(), appOffersByDeviceId: appOffers);
    if (!device.autoSync ||
        !_networkAvailable ||
        wasOnline ||
        _activeDeviceId != null ||
        state.busyDeviceId != null ||
        !_shouldAutomaticallyInitiate(device)) {
      return;
    }
    unawaited(_runOperation(device, endpoint, operation: PairedSyncOperation.push, automatic: true));
  }

  Future<void> _persistDiscoveredLabel(PairedDevice device) async {
    try {
      await _serializeRepositoryMutation(() async {
        final repository = ref.read(pairedDeviceRepositoryProvider);
        final latest = await repository.read(device.deviceId);
        if (latest != null && latest.label != device.label) {
          await repository.upsert(latest.copyWith(label: device.label));
        }
      });
    } on Object {
      // 在线标签已经更新；持久化失败不能影响发现和同步连接。
    }
  }

  Future<void> _recordResult(PairedDevice device, PairedSyncResultState result) async {
    await _serializeRepositoryMutation(() async {
      final repository = ref.read(pairedDeviceRepositoryProvider);
      final latest = await repository.read(device.deviceId);
      if (latest == null) return;
      final now = DateTime.now().toUtc();
      await repository.upsert(latest.copyWith(label: device.label, lastSeenAtUtc: now, lastSyncAtUtc: now, lastSyncResult: result));
    });
    await reloadDevices();
  }

  @override
  Future<void> _recordResultSafely(PairedDevice device, PairedSyncResultState result) async {
    try {
      await _recordResult(device, result);
    } on Object {
      // 同步结果已经确定；仅记录摘要失败不能制造未处理异常或覆盖业务终态。
    }
  }

  @override
  Future<void> _savePairing(PairedDevice peer, List<int> secret) async {
    await _serializeRepositoryMutation(() async {
      final store = ref.read(deviceIdentityStoreProvider);
      await store.writePeerSecret(peer.deviceId, secret);
      try {
        await ref.read(pairedDeviceRepositoryProvider).upsert(peer);
      } on Object {
        await store.deletePeerSecret(peer.deviceId);
        rethrow;
      }
    });
  }

  @override
  Future<void> _deletePairing(String deviceId) async {
    await _serializeRepositoryMutation(() async {
      await ref.read(pairedDeviceRepositoryProvider).remove(deviceId);
      await ref.read(deviceIdentityStoreProvider).deletePeerSecret(deviceId);
    });
  }

  Future<T> _serializeRepositoryMutation<T>(Future<T> Function() action) {
    final result = Completer<T>();
    _repositoryMutation = _repositoryMutation.then<void>((_) async {
      try {
        result.complete(await action());
      } on Object catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }

  @override
  void _scheduleRetry(String deviceId) {
    if (_retryTimers.containsKey(deviceId) || !_foregroundDesired) return;
    final failures = (_retryFailures[deviceId] ?? 0) + 1;
    _retryFailures[deviceId] = failures;
    final exponent = failures > 4 ? 3 : failures - 1;
    final seconds = 30 * (1 << exponent);
    _retryTimers[deviceId] = Timer(Duration(seconds: seconds), () {
      _retryTimers.remove(deviceId);
      final device = _device(deviceId);
      final endpoint = _endpoints[deviceId];
      if (device == null ||
          !device.autoSync ||
          endpoint == null ||
          endpoint.expiresAtUtc.isBefore(DateTime.now().toUtc()) ||
          !_shouldAutomaticallyInitiate(device)) {
        return;
      }
      unawaited(_runOperation(device, endpoint, operation: PairedSyncOperation.push, automatic: true));
    });
  }

  @override
  bool _completeWakeRequest(String? requestId, PairedSyncRunSummary summary) {
    if (requestId == null) return false;
    final pending = _pendingWakeRequests[requestId];
    if (pending == null || pending.completion.isCompleted) return false;
    pending.completion.complete(summary);
    return true;
  }

  @override
  bool _failWakeRequest(String? requestId, Object error, StackTrace stackTrace) {
    if (requestId == null) return false;
    final pending = _pendingWakeRequests[requestId];
    if (pending == null || pending.completion.isCompleted) return false;
    pending.completion.completeError(error, stackTrace);
    return true;
  }

  @override
  _PendingWakeRequest? _pendingWakeForDevice(String deviceId) {
    for (final pending in _pendingWakeRequests.values) {
      if (pending.deviceId == deviceId) return pending;
    }
    return null;
  }

  @override
  PairedSyncDiagnosticSession _startPairedDiagnostics(
    PairedDevice device, {
    required PairedSyncOperation operation,
    required bool automatic,
    required String role,
  }) => PairedSyncDiagnosticSession.start(
    ref.read(diagnosticsManagerProvider),
    role: role,
    operation: operation,
    automatic: automatic,
    peerPlatform: device.platform,
  );

  @override
  void _showFailure(PairedDevice device, PairedSyncFailure failure, {required bool automatic}) {
    if (_disposed) return;
    state = state.copyWith(
      lastErrorCode: failure.code,
      lastErrorDetails: failure.uiDetails,
      lastMessage: pairedSyncFailureMessage(device, failure, automatic: automatic),
    );
  }

  @override
  Future<PairedSyncFailure?> _refreshAfterSync() async {
    try {
      ref.invalidate(availablePluginSourcesProvider);
      await ref.read(libraryPageControllerProvider.notifier).refresh();
      await ref.read(privateLibraryPageControllerProvider.notifier).refresh();
      final projections = <LibraryPageState>[ref.read(libraryPageControllerProvider), ref.read(privateLibraryPageControllerProvider)];
      for (final projection in projections) {
        if (!projection.hasFailure) continue;
        return PairedSyncFailure.fromException(
          stage: 'library_refresh',
          error: StateError('library_refresh_${projection.error?.code.wireValue ?? 'unknown'}'),
          stackTrace: StackTrace.current,
          code: 'device_sync_library_refresh_failed',
        );
      }
      return null;
    } on Object catch (error, stackTrace) {
      return PairedSyncFailure.fromException(
        stage: 'library_refresh',
        error: error,
        stackTrace: stackTrace,
        code: 'device_sync_library_refresh_failed',
      );
    }
  }

  @override
  PairedDevice? _device(String deviceId) {
    for (final device in state.devices) {
      if (device.deviceId == deviceId) return device;
    }
    return null;
  }

  @override
  Set<String> _onlineIds() {
    final now = DateTime.now().toUtc();
    final expired = <String>[
      for (final entry in _endpoints.entries)
        if (entry.value.expiresAtUtc.isBefore(now)) entry.key,
    ];
    for (final deviceId in expired) {
      _endpoints.remove(deviceId);
      _retryTimers.remove(deviceId)?.cancel();
      _retryFailures.remove(deviceId);
    }
    return Set<String>.unmodifiable(_endpoints.keys.where((id) => _device(id) != null));
  }

  @override
  void _pairingFailed(String code, {String? details}) {
    unawaited(_closePairingResources());
    state = state.copyWith(
      pairingPhase: DevicePairingPhase.failed,
      pairingOffer: null,
      pairingCode: null,
      pairingPeer: null,
      lastErrorCode: code,
      lastErrorDetails: details,
    );
  }

  @override
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

String _appUpdateFailureCode(Object error) {
  final match = RegExp(r'(app_update_[a-z_]+|lan_sync_[a-z_]+)').firstMatch(error.toString());
  return match?.group(1) ?? 'app_update_failed';
}

String _appUpdateFailureMessage(String label, String code) => switch (code) {
  'app_update_not_newer' => '$label 的 App 版本不高于本机；如确实需要，请选择强制安装',
  'app_update_platform_mismatch' => '$label 没有适用于当前设备平台的 App 安装包',
  'app_update_install_permission_required' => '请在系统设置中允许安装未知来源应用，返回后再次升级',
  'app_update_installer_unavailable' => '系统中没有可用的 APK 安装程序',
  'app_update_installer_permission_denied' => '系统拒绝向安装程序授予 APK 读取权限',
  'app_update_file_provider_failed' => '安装包临时文件无法提供给系统安装程序',
  'app_update_installer_failed' => '系统安装程序启动失败',
  'lan_sync_peer_offline' => '$label 已离线，无法获取 App',
  _ => '从 $label 获取 App 失败（$code）',
};
