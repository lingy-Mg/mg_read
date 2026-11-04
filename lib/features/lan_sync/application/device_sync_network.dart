/// 已配对同步的网络可用性与平台频率策略。
///
/// Android 原有同步与唤醒仅允许 Wi-Fi，并对开发书源变化做低频合并；独立辅助服务可在
/// 私网以太网复用宿主和发现，不放宽同步资格。Windows/macOS 可使用私有以太网或 Wi-Fi。
part of 'device_sync_controller.dart';

abstract base class _DeviceSyncNetworkBase extends Notifier<DeviceSyncState> {
  Map<String, PairedSyncEndpoint> get _endpoints;
  LocalDeviceIdentity? get _identity;
  set _identity(LocalDeviceIdentity? value);
  PairedSyncHost? get _host;
  Timer? get _networkProbeTimer;
  set _networkProbeTimer(Timer? value);
  Timer? get _mobileDevelopmentSyncTimer;
  set _mobileDevelopmentSyncTimer(Timer? value);
  Future<bool>? get _networkRefreshFuture;
  set _networkRefreshFuture(Future<bool>? value);
  bool get _disposed;
  bool get _foregroundDesired;
  bool get _networkAvailable;
  set _networkAvailable(bool value);
  bool get _hostDesired =>
      _foregroundDesired || ((Platform.isWindows || Platform.isMacOS) && (ref.read(lanPeerServiceProvider)?.requiresHost ?? false));

  Future<void> _ensureHost();
  Future<void> _closeHost();
  Future<void> _syncAvailablePeersNow({required bool pushChanges});
  PairedSyncDiagnosticSession _startPairedDiagnostics(
    PairedDevice device, {
    required PairedSyncOperation operation,
    required bool automatic,
    required String role,
  });
  void _showFailure(PairedDevice device, PairedSyncFailure failure, {required bool automatic});

  // Android must remain below the legacy eight-second peer lifetime while old
  // desktop builds can still be paired, otherwise each announcement looks like
  // a fresh online edge and repeatedly triggers automatic synchronization.
  Duration get _announcementInterval => Platform.isAndroid ? const Duration(seconds: 6) : const Duration(seconds: 3);
  Duration get _advertisedPeerLifetime => Platform.isAndroid ? const Duration(seconds: 20) : const Duration(seconds: 12);
  Duration get _endpointCheckInterval => Platform.isAndroid ? const Duration(seconds: 12) : const Duration(seconds: 3);
  Duration get _networkProbeInterval => Platform.isAndroid ? const Duration(seconds: 30) : const Duration(seconds: 15);
  Duration get _reconciliationInterval => Platform.isAndroid ? const Duration(minutes: 15) : const Duration(minutes: 5);

  void _startNetworkMonitor() {
    if (_networkProbeTimer != null || (state.devices.isEmpty && !(ref.read(lanPeerServiceProvider)?.requiresHost ?? false))) return;
    _networkProbeTimer = Timer.periodic(_networkProbeInterval, (_) {
      if (!_disposed && _hostDesired) unawaited(_refreshNetworkAvailability());
    });
  }

  void _stopNetworkMonitor() {
    _networkProbeTimer?.cancel();
    _networkProbeTimer = null;
    _mobileDevelopmentSyncTimer?.cancel();
    _mobileDevelopmentSyncTimer = null;
  }

  Future<bool> _readNetworkAvailability() async {
    if (await ref.read(lanSyncNetworkEnvironmentProvider).isLocalNetworkAvailable()) return true;
    final service = ref.read(lanPeerServiceProvider);
    return service != null && service.requiresHost && await service.canUseNetwork();
  }

  Future<bool> _refreshNetworkAvailability() {
    final existing = _networkRefreshFuture;
    if (existing != null) return existing;
    final next = _refreshNetworkAvailabilityOnce();
    _networkRefreshFuture = next;
    unawaited(
      next.then<void>(
        (_) {
          if (identical(_networkRefreshFuture, next)) _networkRefreshFuture = null;
        },
        onError: (Object _, StackTrace _) {
          if (identical(_networkRefreshFuture, next)) _networkRefreshFuture = null;
        },
      ),
    );
    return next;
  }

  Future<bool> _refreshNetworkAvailabilityOnce() async {
    final available = await _readNetworkAvailability();
    if (_disposed || !_hostDesired) return false;
    final changed = available != _networkAvailable;
    _networkAvailable = available;
    if (!available) {
      if (_host != null) await _closeHost();
      _endpoints.clear();
      if (changed) {
        state = state.copyWith(
          onlineDeviceIds: const <String>{},
          lastErrorCode: null,
          lastMessage: Platform.isAndroid ? '未连接 Wi-Fi，局域网同步已暂停' : '未检测到可用局域网，同步已暂停',
        );
      } else if (state.onlineDeviceIds.isNotEmpty) {
        state = state.copyWith(onlineDeviceIds: const <String>{});
      }
      return false;
    }
    if (_host == null && (state.devices.isNotEmpty || (ref.read(lanPeerServiceProvider)?.requiresHost ?? false))) {
      try {
        await _ensureHost();
      } on Object catch (error, stackTrace) {
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
        state = state.copyWith(lastErrorCode: failure.code, lastErrorDetails: failure.uiDetails, lastMessage: '局域网已恢复，但同步服务启动失败');
        return false;
      }
    }
    if (changed) {
      state = state.copyWith(lastErrorCode: null, lastMessage: Platform.isAndroid ? 'Wi-Fi 已连接，正在发现已配对设备' : '局域网已连接，正在发现已配对设备');
    }
    return true;
  }

  Future<bool> _ensureNetworkForOperation(PairedDevice device, {required PairedSyncOperation operation, required bool automatic}) async {
    if (await ref.read(lanSyncNetworkEnvironmentProvider).isLocalNetworkAvailable() && await _refreshNetworkAvailability()) return true;
    if (automatic || _disposed) return false;
    final code = Platform.isAndroid ? 'lan_sync_wifi_required' : 'lan_sync_local_network_unavailable';
    final failure = PairedSyncFailure.fromException(stage: 'network', error: StateError(code), stackTrace: StackTrace.current, code: code);
    final diagnostics = _startPairedDiagnostics(device, operation: operation, automatic: false, role: 'paired_initiator');
    diagnostics.fail(failure);
    _showFailure(device, failure, automatic: false);
    return false;
  }

  Future<bool> _canAnnounce() async {
    if (!Platform.isAndroid) return _networkAvailable;
    return _readNetworkAvailability();
  }

  bool _shouldAutomaticallyInitiate(PairedDevice device) {
    if ((Platform.isWindows || Platform.isMacOS) && device.platform == PairedDevicePlatform.android) return true;
    if (Platform.isAndroid && device.platform.isDesktop) return false;
    return (_identity?.deviceId.compareTo(device.deviceId) ?? 1) < 0;
  }

  void _scheduleMobileDevelopmentSync() {
    _mobileDevelopmentSyncTimer?.cancel();
    _mobileDevelopmentSyncTimer = Timer(const Duration(seconds: 45), () {
      _mobileDevelopmentSyncTimer = null;
      if (!_disposed && _foregroundDesired) unawaited(_syncAvailablePeersNow(pushChanges: true));
    });
  }
}
