/// 首次配对流程的应用编排。
///
/// 持有十分钟配对会话、双方确认和逐设备密钥提交；已配对同步、发现与网络频率
/// 分别由上层操作和网络基类负责。
part of 'device_sync_controller.dart';

abstract base class _DeviceSyncPairingBase extends _DeviceSyncNetworkBase {
  int get _pairingGeneration;
  set _pairingGeneration(int value);
  LanPairingServer? get _pairingServer;
  set _pairingServer(LanPairingServer? value);
  set _pairingSubscription(StreamSubscription<LanPairingRequest>? value);
  LanPairingRequest? get _pairingRequest;
  set _pairingRequest(LanPairingRequest? value);
  set _pairingClient(LanPairingClientConnection? value);

  Future<void> _closePairingResources();
  Future<void> _savePairing(PairedDevice peer, List<int> secret);
  Future<void> _deletePairing(String deviceId);
  Future<void> reloadDevices();
  void _pairingFailed(String code);

  Future<void> beginPairing() async {
    if (!await _readNetworkAvailability()) {
      _failPairingWithoutLocalNetwork();
      return;
    }
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
      unawaited(
        server.done.then((_) {
          if (generation == _pairingGeneration && identical(_pairingServer, server)) {
            _pairingServer = null;
            _pairingFailed('device_pairing_offer_expired');
          }
        }),
      );
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
    unawaited(
      request.done.then((_) {
        if (identical(_pairingRequest, request)) {
          _pairingRequest = null;
          state = state.copyWith(
            pairingPhase: _pairingServer == null ? DevicePairingPhase.failed : DevicePairingPhase.showingOffer,
            pairingCode: null,
            pairingPeer: null,
            lastErrorCode: _pairingServer == null ? 'device_pairing_offer_expired' : 'device_pairing_request_expired',
          );
        }
      }),
    );
  }

  Future<void> approvePairing() async {
    final request = _pairingRequest;
    if (request == null || !request.isActive || state.pairingPhase != DevicePairingPhase.confirming) {
      return;
    }
    var saved = false;
    try {
      await _savePairing(request.peer, request.sharedSecret);
      saved = true;
      _pairingRequest = null;
      await request.approve();
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
      if (saved) await _deletePairing(request.peer.deviceId);
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
    if (!await _readNetworkAvailability()) {
      _failPairingWithoutLocalNetwork();
      return;
    }
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
      await _savePairing(peer, client.sharedSecret);
      try {
        await client.confirmCommitted();
      } on Object {
        await _deletePairing(peer.deviceId);
        rethrow;
      }
      _pairingClient = null;
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

  void _failPairingWithoutLocalNetwork() {
    final code = Platform.isAndroid ? 'lan_sync_wifi_required' : 'lan_sync_local_network_unavailable';
    _pairingFailed(code);
    state = state.copyWith(lastMessage: Platform.isAndroid ? '请先连接 Wi-Fi 再添加设备' : '请先连接 Wi-Fi 或网线再添加设备');
  }
}
