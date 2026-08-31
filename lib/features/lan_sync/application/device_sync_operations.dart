/// 已配对同步的操作编排。
///
/// 负责发起、反向连接、入站处理、传输终态和页面刷新；设备发现、配对和持久化仍由
/// [DeviceSyncController] 持有。所有失败都先完成业务终态，再投影到 UI 与诊断。
part of 'device_sync_controller.dart';

abstract base class _DeviceSyncOperationsBase extends _DeviceSyncPairingBase {
  Map<String, int> get _retryFailures;
  Map<String, Timer> get _retryTimers;
  Map<String, _PendingWakeRequest> get _pendingWakeRequests;
  String? get _activeDeviceId;
  set _activeDeviceId(String? value);

  PairedDevice? _device(String deviceId);
  Future<void> _recordResultSafely(PairedDevice device, PairedSyncResultState result);
  void _scheduleRetry(String deviceId);
  bool _completeWakeRequest(String? requestId, PairedSyncRunSummary summary);
  bool _failWakeRequest(String? requestId, Object error, StackTrace stackTrace);
  _PendingWakeRequest? _pendingWakeForDevice(String deviceId);
  Future<PairedSyncFailure?> _refreshAfterSync();
  Set<String> _onlineIds();

  Future<void> _runOperation(
    PairedDevice device,
    PairedSyncEndpoint endpoint, {
    required PairedSyncOperation operation,
    bool automatic = false,
  }) async {
    if (!await _ensureNetworkForOperation(device, operation: operation, automatic: automatic)) return;
    if (Platform.isAndroid && device.platform == PairedDevicePlatform.windows) {
      await _requestReverseOperation(device, endpoint, operation: operation, automatic: automatic);
      return;
    }
    await _runOutbound(device, endpoint, operation: operation, automatic: automatic);
  }

  Future<void> _requestReverseOperation(
    PairedDevice device,
    PairedSyncEndpoint endpoint, {
    required PairedSyncOperation operation,
    required bool automatic,
  }) async {
    if (_activeDeviceId != null || state.busyDeviceId != null) return;
    final diagnostics = _startPairedDiagnostics(device, operation: operation, automatic: automatic, role: 'paired_initiator');
    final host = _host;
    final identity = _identity;
    if (host == null || identity == null) {
      final failure = PairedSyncFailure.fromException(
        stage: 'identity',
        error: StateError('device_sync_host_not_ready'),
        stackTrace: StackTrace.current,
        code: 'device_sync_start_failed',
      );
      diagnostics.fail(failure);
      _showFailure(device, failure, automatic: automatic);
      return;
    }
    final secret = await ref.read(deviceIdentityStoreProvider).readPeerSecret(device.deviceId);
    if (secret == null) {
      final failure = PairedSyncFailure.fromException(
        stage: 'identity',
        error: StateError('paired_secret_missing'),
        stackTrace: StackTrace.current,
      );
      diagnostics.fail(failure);
      _showFailure(device, failure, automatic: automatic);
      return;
    }
    final requestId = createPairedSyncWakeRequestId();
    final pending = _PendingWakeRequest(deviceId: device.deviceId, diagnostics: diagnostics);
    _pendingWakeRequests[requestId] = pending;
    state = state.copyWith(busyDeviceId: device.deviceId, lastErrorCode: null, lastMessage: '正在请求 ${device.label} 建立反向连接');
    try {
      diagnostics.stage('wake_send');
      await sendPairedSyncWakeRequest(
        identity: identity,
        endpoint: endpoint,
        sharedSecret: secret,
        operation: operation,
        localPort: host.port,
        requestId: requestId,
      );
      diagnostics.stage('wake_wait');
      final summary = await pending.completion.future.timeout(const Duration(seconds: 12));
      diagnostics.complete(summary);
    } on Object catch (error, stackTrace) {
      if (_pendingWakeRequests.containsKey(requestId)) {
        final failure = error is PairedSyncRemoteFailureException
            ? PairedSyncFailure.remote(code: error.code, stage: error.stage, errorText: error.errorText, receiptStackTrace: stackTrace)
            : PairedSyncFailure.fromException(
                stage: diagnostics.stageName,
                error: error,
                stackTrace: stackTrace,
                code: error is TimeoutException ? 'lan_sync_reverse_connect_timeout' : null,
              );
        diagnostics.fail(failure, partial: failure.code == 'device_sync_partial');
        await _recordResultSafely(device, PairedSyncResultState.failed);
        _showFailure(device, failure, automatic: automatic);
        if (automatic && failure.allowsAutomaticRetry) {
          _scheduleRetry(device.deviceId);
        }
      }
    } finally {
      _pendingWakeRequests.remove(requestId);
      if (_activeDeviceId == null && state.busyDeviceId == device.deviceId) {
        state = state.copyWith(busyDeviceId: null);
      }
    }
  }

  Future<void> _handleWakeRequest(PairedSyncWakeRequest request) async {
    final device = _device(request.endpoint.deviceId);
    if (device == null) {
      await _reportWakeFailure(
        request,
        PairedSyncFailure.fromException(
          stage: 'identity',
          error: StateError('device_sync_peer_state_missing'),
          stackTrace: StackTrace.current,
          code: 'device_sync_peer_state_missing',
        ),
      );
      return;
    }
    if (_activeDeviceId != null || state.busyDeviceId != null) {
      await _reportWakeFailure(
        request,
        PairedSyncFailure.fromException(
          stage: 'request',
          error: StateError('lan_sync_peer_busy'),
          stackTrace: StackTrace.current,
          code: 'lan_sync_peer_busy',
        ),
      );
      return;
    }
    _endpoints[device.deviceId] = request.endpoint;
    state = state.copyWith(onlineDeviceIds: _onlineIds());
    final failure = await _runOutbound(device, request.endpoint, operation: request.operation.reversed, requestId: request.requestId);
    if (failure == null) return;
    await _reportWakeFailure(request, failure);
  }

  Future<void> _reportWakeFailure(PairedSyncWakeRequest request, PairedSyncFailure failure) async {
    try {
      final identity = _identity ?? await ref.read(deviceIdentityStoreProvider).loadOrCreateIdentity();
      final secret = await ref.read(deviceIdentityStoreProvider).readPeerSecret(request.endpoint.deviceId);
      if (secret == null) return;
      await sendPairedSyncWakeFailure(
        identity: identity,
        endpoint: request.endpoint,
        sharedSecret: secret,
        requestId: request.requestId,
        code: failure.code,
        stage: failure.stage,
        errorText: failure.errorText,
      );
    } on Object {
      // 本机详细失败已经记录；远端回报失败不能覆盖原始终态。
    }
  }

  Future<void> _handleWakeFailure(PairedSyncWakeFailure failure) async {
    final pending = _pendingWakeRequests[failure.requestId];
    if (pending == null || pending.deviceId != failure.deviceId || pending.completion.isCompleted) return;
    pending.completion.completeError(
      PairedSyncRemoteFailureException(code: failure.code, stage: failure.stage, errorText: failure.errorText),
      StackTrace.current,
    );
  }

  Future<PairedSyncFailure?> _runOutbound(
    PairedDevice device,
    PairedSyncEndpoint endpoint, {
    required PairedSyncOperation operation,
    bool automatic = false,
    String? requestId,
  }) async {
    if (_activeDeviceId != null) return null;
    _activeDeviceId = device.deviceId;
    var authenticatedDevice = device;
    final diagnostics = _startPairedDiagnostics(
      device,
      operation: operation,
      automatic: automatic,
      role: requestId == null ? 'paired_outbound' : 'paired_reverse_responder',
    );
    PairedSyncFailure? terminalFailure;
    state = state.copyWith(
      busyDeviceId: device.deviceId,
      lastErrorCode: null,
      lastMessage: switch (operation) {
        PairedSyncOperation.bidirectional => '正在与 ${device.label} 双向同步',
        PairedSyncOperation.pull => '正在从 ${device.label} 拉取',
        PairedSyncOperation.push => '正在向 ${device.label} 推送',
      },
    );
    try {
      diagnostics.stage('identity');
      final secret = await ref.read(deviceIdentityStoreProvider).readPeerSecret(device.deviceId);
      final identity = _identity ?? await ref.read(deviceIdentityStoreProvider).loadOrCreateIdentity();
      if (secret == null) throw StateError('paired_secret_missing');
      diagnostics.stage('connect');
      final session = await PairedSyncClientSession.connectAny(
        endpoints: <PairedSyncEndpoint>[endpoint],
        identity: identity,
        peer: device,
        sharedSecret: secret,
      );
      authenticatedDevice = session.peer;
      final summary = await session.run(
        gateway: ref.read(lanSyncGatewayProvider),
        operation: operation,
        requestId: requestId,
        onStage: diagnostics.stage,
      );
      _retryTimers.remove(device.deviceId)?.cancel();
      _retryFailures.remove(device.deviceId);
      diagnostics.stage('result_persist');
      await _recordResultSafely(authenticatedDevice, PairedSyncResultState.success);
      final refreshFailure = await _refreshAfterSync();
      if (refreshFailure == null) {
        state = state.copyWith(lastMessage: _summaryMessage(authenticatedDevice.label, summary), lastErrorCode: null);
        diagnostics.complete(summary);
      } else {
        state = state.copyWith(
          lastMessage: '同步数据已完成，但首页书架刷新失败；原有内容已保留，可在首页下拉重试',
          lastErrorCode: refreshFailure.code,
          lastErrorDetails: refreshFailure.uiDetails,
        );
        diagnostics.fail(refreshFailure, partial: true);
      }
    } on Object catch (error, stackTrace) {
      final partial = error is PairedSyncPartialException;
      terminalFailure = PairedSyncFailure.fromException(stage: diagnostics.stageName, error: error, stackTrace: stackTrace);
      diagnostics.fail(terminalFailure, partial: partial);
      await _recordResultSafely(authenticatedDevice, partial ? PairedSyncResultState.partial : PairedSyncResultState.failed);
      _showFailure(authenticatedDevice, terminalFailure, automatic: automatic);
      if (automatic && terminalFailure.allowsAutomaticRetry) {
        _scheduleRetry(device.deviceId);
      }
    } finally {
      _activeDeviceId = null;
      state = state.copyWith(busyDeviceId: null);
    }
    return terminalFailure;
  }

  Future<void> _handleIncoming(PairedSyncServerSession session) async {
    var device = _device(session.peer.deviceId) ?? session.peer;
    final pending = _pendingWakeForDevice(device.deviceId);
    final busyDeviceId = state.busyDeviceId;
    final expectedReverseConnection = busyDeviceId == device.deviceId && pending != null;
    if (_activeDeviceId != null || (busyDeviceId != null && !expectedReverseConnection)) {
      await session.rejectBusy();
      return;
    }
    final diagnostics =
        pending?.diagnostics ??
        _startPairedDiagnostics(device, operation: PairedSyncOperation.bidirectional, automatic: false, role: 'paired_inbound');
    _activeDeviceId = device.deviceId;
    state = state.copyWith(busyDeviceId: device.deviceId, lastErrorCode: null, lastMessage: '正在与 ${device.label} 同步');
    try {
      final summary = await session.run(gateway: ref.read(lanSyncGatewayProvider), onStage: diagnostics.stage);
      device = session.peer;
      diagnostics.stage('result_persist');
      await _recordResultSafely(device, PairedSyncResultState.success);
      final refreshFailure = await _refreshAfterSync();
      if (refreshFailure == null) {
        state = state.copyWith(lastMessage: _summaryMessage(device.label, summary), lastErrorCode: null);
      } else {
        state = state.copyWith(
          lastMessage: '同步数据已完成，但首页书架刷新失败；原有内容已保留，可在首页下拉重试',
          lastErrorCode: refreshFailure.code,
          lastErrorDetails: refreshFailure.uiDetails,
        );
        diagnostics.fail(refreshFailure, partial: true);
      }
      if (!_completeWakeRequest(session.requestId, summary) && refreshFailure == null) diagnostics.complete(summary);
    } on Object catch (error, stackTrace) {
      await session.close();
      final partial = error is PairedSyncPartialException;
      final failure = PairedSyncFailure.fromException(stage: diagnostics.stageName, error: error, stackTrace: stackTrace);
      await _recordResultSafely(device, partial ? PairedSyncResultState.partial : PairedSyncResultState.failed);
      if (!_failWakeRequest(session.requestId, error, stackTrace)) {
        diagnostics.fail(failure, partial: partial);
        _showFailure(device, failure, automatic: true);
      }
    } finally {
      _activeDeviceId = null;
      state = state.copyWith(busyDeviceId: null);
    }
  }
}
