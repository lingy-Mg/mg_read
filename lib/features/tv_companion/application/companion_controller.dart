/// App-lifetime phone/TV coordinator over existing device trust. The peer host
/// owns sockets; media routes own playback; this service owns leases, pending
/// commands, discovery projections and reconnect state, never media resources.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:mg_read_video_player/mg_read_video_player.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/lan_sync/application/device_identity_store.dart';
import 'package:mg_read/features/lan_sync/application/paired_device_repository.dart';
import 'package:mg_read/features/lan_sync/application/lan_peer_service.dart';
import 'package:mg_read/features/lan_sync/domain/paired_device_models.dart';
import 'package:mg_read/features/lan_sync/domain/lan_endpoint_policy.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/discovery/application/batch_search.dart';
import '../data/companion_repository.dart';
import '../data/companion_network.dart';
import '../data/companion_secure_channel.dart';
import '../domain/companion_models.dart';
import '../domain/companion_command.dart';
import 'companion_media_host.dart';
import 'companion_text_input.dart';
import 'companion_command_engine.dart';

part 'companion_client.dart';
part 'companion_receiver.dart';
part 'companion_catalog.dart';

typedef CompanionHandoffLauncher = Future<void> Function(CompanionContentRef content, CompanionExecutionContext context);
final companionHandoffLauncherProvider = Provider<CompanionHandoffLauncher>(
  (ref) => (_, _) async {
    throw const CompanionFailure('media_host_unavailable');
  },
);
final companionLibraryProvider = Provider<Future<ContentLibrary> Function()?>((ref) => null);
final companionLocalResumeLauncherProvider = Provider<Future<void> Function(VideoHistoryCheckpoint)>(
  (ref) => (_) async {
    throw const CompanionFailure('media_host_unavailable');
  },
);
final companionOpenDeviceSyncProvider = Provider<Future<void> Function()>(
  (ref) => () async {
    throw const CompanionFailure('navigation_unavailable');
  },
);
final companionNetworkProvider = Provider<CompanionNetwork>((ref) => const CompanionNetwork());
typedef CompanionChannelConnector =
    Future<CompanionSecureChannel> Function({
      required Uri uri,
      required String localDeviceId,
      required String remoteDeviceId,
      required List<int> sharedSecret,
    });
final companionChannelConnectorProvider = Provider<CompanionChannelConnector>((ref) => CompanionSecureChannel.connect);
final companionControllerProvider = Provider<CompanionController>((ref) {
  final service = CompanionController(ref);
  ref.onDispose(service.dispose);
  return service;
});

String companionToken() {
  final random = Random.secure();
  return base64Url.encode(List.generate(18, (_) => random.nextInt(256))).replaceAll('=', '');
}

final class CompanionController extends ChangeNotifier implements LanPeerService {
  CompanionController(this.ref) {
    _textInput = ref.read(companionTextInputProvider);
    _engine = CompanionCommandEngine(hostEpoch: hostEpoch, handler: _dispatchCommand, nowMs: () => _clock.elapsedMilliseconds);
    _receiptSubscription = _engine.receipts.listen((receipt) {
      final peer = _peers[receipt.peerId];
      if (peer != null) unawaited(_sendPeer(peer, {'kind': 'receipt', 'receipt': receipt.toJson()}));
      notifyListeners();
    });
    _media.addListener(_mediaChanged);
  }
  final Ref ref;
  final String hostEpoch = companionToken();
  final Stopwatch _clock = Stopwatch()..start();
  late final CompanionCommandEngine _engine;
  late final StreamSubscription<CompanionReceipt> _receiptSubscription;
  late final CompanionMediaHost _media = ref.read(companionMediaHostProvider);
  late final CompanionTextInput _textInput;
  late final CompanionRepository _repository = ref.read(companionRepositoryProvider);
  late final DeviceIdentityStore _identities = ref.read(deviceIdentityStoreProvider);
  late final PairedDeviceRepository _devices = ref.read(pairedDeviceRepositoryProvider);
  late final CompanionNetwork _network = ref.read(companionNetworkProvider);
  LocalDeviceIdentity? identity;
  bool initialized = false, receiverEnabled = false, _foreground = true, _disposed = false, _ticking = false;
  int _discoveryUsers = 0, _snapshotSequence = 0, _clientSeq = 0, _pendingHandshakes = 0;
  int _remoteMediaMutation = 0;
  int _connectionGeneration = 0;
  int _policyGeneration = 0;
  int _receiverIntent = 0;
  Future<void> _receiverTail = Future.value();
  final Map<String, int> _policyIntents = {};
  final Map<String, Future<void>> _policyTails = {};
  final Set<String> pendingControlRequests = {};
  int? hostPort;
  List<String> localAddresses = [];
  final endpoints = <String, CompanionEndpoint>{};
  final Map<String, _CompanionPeer> _peers = {};
  final Set<String> _revokedPeers = {};
  List<String> get connectedControllerIds => List.unmodifiable(_peers.keys);
  final Map<String, PluginInvocationCancellation> _searchCancellations = {};
  final Map<String, _TvSearchSession> _searchSessions = {};
  Timer? _timer, _reconnectTimer;
  Future<void>? _initializing;
  String? _mediaSelection, _selectedId, _clientEpoch;
  int _reconnectAttempts = 0;
  CompanionSecureChannel? _client;
  StreamSubscription<Map<String, Object?>>? _clientSubscription;
  CompanionConnectionStatus connectionStatus = CompanionConnectionStatus.disconnected;
  CompanionPlaybackSnapshot? remoteState;
  DateTime? remoteStateAt;
  int? _remoteStateTick, _lastClientTick;
  Future<CompanionReceipt>? _controlAcquisition;
  final Map<String, String> _knownLabels = {};
  String get selectedLabel => policies[_selectedId]?.label ?? _knownLabels[_selectedId] ?? selectedEndpoint?.label ?? 'TV';
  String deviceLabel(String id) =>
      policies[id]?.label ?? _knownLabels[id] ?? (id.length > 6 ? '其他设备 · ${id.substring(id.length - 6)}' : id);
  CompanionReceipt? lastReceipt;
  String? errorCode;
  String? get selectedDeviceId => _selectedId;
  CompanionEndpoint? get selectedEndpoint => endpoints[_selectedId];
  final Map<String, Completer<CompanionReceipt>> _commands = {};
  final Map<String, Completer<Map<String, Object?>>> _requests = {};
  final Map<String, int> _remoteProgressRevisions = {};
  final Map<String, String> _remoteProgressSessions = {};
  final Map<String, int> _remoteProgressSequences = {};
  final Map<String, CompanionPolicy> policies = {};
  bool get stale => _remoteStateTick == null || _clock.elapsedMilliseconds - _remoteStateTick! > 3000;
  bool get hasControl =>
      connectionStatus == CompanionConnectionStatus.connected && !stale && remoteState?.controllerId == identity?.deviceId;
  String? get controlOwnerId => _engine.controlOwnerId;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  bool get requiresHost => receiverEnabled || _discoveryUsers > 0;
  @override
  Map<String, Object?> get advertisement => {'companion': 1, 'receiving': receiverEnabled && _foreground};
  @override
  Future<bool> canUseNetwork() => _network.available();
  @override
  void hostChanged(int? port) {
    hostPort = port;
    if (port == null) _closeReceivers();
    if (!_disposed) notifyListeners();
  }

  @override
  void trustRevoked(String id) {
    _policyIntents[id] = (_policyIntents[id] ?? 0) + 1;
    _revokedPeers.add(id);
    _disconnectPeer(id);
    if (_selectedId == id) unawaited(disconnect());
    _notify();
  }

  @override
  Future<bool> handleRequest(HttpRequest request) => _acceptRequest(request);
  @override
  void discovered({
    required String deviceId,
    required String label,
    required String address,
    required int port,
    required Duration lifetime,
    required Map<String, Object?> services,
  }) {
    if (services['companion'] != 1) return;
    if (!endpoints.containsKey(deviceId) && endpoints.length >= 128) {
      final oldest = endpoints.keys.firstWhere((id) => id != _selectedId);
      endpoints.remove(oldest);
    }
    endpoints[deviceId] = CompanionEndpoint(
      deviceId: deviceId,
      label: label,
      address: address,
      port: port,
      expiresAt: DateTime.now().add(lifetime),
      receiving: services['receiving'] == true,
    );
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() => _initializing ??= _initialize();
  Future<void> _initialize() async {
    try {
      identity = await _identities.loadOrCreateIdentity();
      receiverEnabled = await _repository.receiverEnabled();
      _selectedId = await _repository.selectedDevice();
      for (final peer in await _devices.list()) {
        final policy = await _repository.policy(peer.deviceId);
        final secret = await _identities.readPeerSecret(peer.deviceId);
        policies[peer.deviceId] = secret != null && policy.allowsSecret(secret) ? policy : CompanionPolicy(label: policy.label);
        _knownLabels[peer.deviceId] = peer.label;
      }
      if (_disposed) return;
      localAddresses = await _network.addresses();
      initialized = true;
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => unawaited(_tick()));
    } on Object {
      errorCode = 'companion_start_failed';
      _initializing = null;
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> setReceiverEnabled(bool enabled) {
    final intent = ++_receiverIntent;
    if (!enabled) {
      receiverEnabled = false;
      _closeReceivers();
      _notify();
    }
    final operation = _receiverTail.then((_) async {
      await initialize();
      if (_disposed || intent != _receiverIntent) return;
      if (enabled && !await _network.ensurePermission()) throw const CompanionFailure('local_network_permission_required');
      if (_disposed || intent != _receiverIntent) return;
      await _repository.setReceiverEnabled(enabled);
      if (_disposed || intent != _receiverIntent) return;
      receiverEnabled = enabled;
      if (!enabled) _closeReceivers();
      _notify();
    });
    _receiverTail = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> setPolicy(String id, CompanionPolicy policy) {
    _policyGeneration++;
    final intent = (_policyIntents[id] ?? 0) + 1;
    _policyIntents[id] = intent;
    if (!policy.control) {
      _revokedPeers.add(id);
      _disconnectPeer(id);
    }
    final operation = (_policyTails[id] ?? Future<void>.value()).then((_) async {
      if (_disposed || _policyIntents[id] != intent) return;
      if (await _devices.read(id) == null) throw const CompanionFailure('not_paired');
      final secret = await _identities.readPeerSecret(id);
      if (_disposed || _policyIntents[id] != intent) return;
      if (secret == null) throw const CompanionFailure('not_paired');
      final bound = policy.boundTo(secret);
      await _repository.setPolicy(id, bound);
      if (_disposed || _policyIntents[id] != intent) return;
      if (bound.control) _revokedPeers.remove(id);
      policies[id] = bound;
      if (!policy.control) _disconnectPeer(id);
      _notify();
    });
    final settled = operation.catchError((Object _) {});
    _policyTails[id] = settled;
    unawaited(
      settled.then((_) {
        if (identical(_policyTails[id], settled)) _policyTails.remove(id);
      }),
    );
    return operation;
  }

  Future<void> refreshPolicies() async {
    final generation = ++_policyGeneration;
    final next = <String, CompanionPolicy>{};
    for (final peer in await _devices.list()) {
      final policy = await _repository.policy(peer.deviceId);
      final secret = await _identities.readPeerSecret(peer.deviceId);
      next[peer.deviceId] = secret != null && policy.allowsSecret(secret) ? policy : CompanionPolicy(label: policy.label);
      _knownLabels[peer.deviceId] = peer.label;
    }
    if (_disposed || generation != _policyGeneration) return;
    policies
      ..clear()
      ..addAll(next);
    notifyListeners();
  }

  Future<void> discover(bool enabled) async {
    await initialize();
    if (enabled && !await _network.ensurePermission()) throw const CompanionFailure('local_network_permission_required');
    _discoveryUsers = enabled ? _discoveryUsers + 1 : (_discoveryUsers - 1).clamp(0, 100);
    notifyListeners();
  }

  void setForeground(bool active) {
    _foreground = active;
    if (!active) {
      _closeReceivers();
      unawaited(disconnect(rememberSelection: true));
    } else {
      if (_selectedId != null) _scheduleReconnect();
    }
    if (!_disposed) notifyListeners();
  }

  void localInteraction() {
    if (!receiverEnabled) return;
    _engine.localInteraction();
    for (final id in _peers.keys) {
      ref.read(companionTextInputProvider).disconnect(id);
    }
    unawaited(_broadcastSnapshot());
  }

  void grantControl(String id) {
    final previous = _engine.controlOwnerId;
    if (previous != null && previous != id) _textInput.disconnect(previous);
    _engine.grantControl(id);
    unawaited(_broadcastSnapshot());
  }

  void _mediaChanged() {
    final selection = jsonEncode([_media.active?.sessionId, _media.content?.groupId, _media.content?.episodeId]);
    if (_mediaSelection != selection) {
      _mediaSelection = selection;
      if (_remoteMediaMutation == 0) _engine.playbackChanged();
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> _tick() async {
    if (_disposed || _ticking) return;
    _ticking = true;
    _textInput.expire();
    try {
      final now = DateTime.now();
      endpoints.removeWhere((_, endpoint) => endpoint.expiresAt.isBefore(now));
      for (final peer in _peers.values.toList()) {
        if (now.difference(peer.lastSeen) > const Duration(seconds: 10) || !await _trusted(peer.id)) {
          _disconnectPeer(peer.id);
          continue;
        }
        await _sendPeer(peer, {'kind': 'state', 'state': (await _snapshot()).toJson()});
        if (_clock.elapsedMilliseconds - peer.lastHistoryMs > 5000) {
          peer.lastHistoryMs = _clock.elapsedMilliseconds;
          unawaited(_pushHistory(peer));
        }
      }
      if (_client != null) {
        if (_lastClientTick != null && _clock.elapsedMilliseconds - _lastClientTick! > 10000) {
          await _lostConnection('connection_timeout');
        } else {
          await _client!.send({'kind': 'ping', 'control': hasControl});
        }
      }
      if (!_disposed) notifyListeners();
    } on Object {
      errorCode = 'network_unavailable';
    } finally {
      _ticking = false;
    }
  }

  Future<bool> _trusted(String id) async {
    if (!receiverEnabled || !_foreground || _revokedPeers.contains(id) || await _devices.read(id) == null) return false;
    final secret = await _identities.readPeerSecret(id);
    if (secret == null) return false;
    final policy = await _repository.policy(id);
    return !_disposed && receiverEnabled && _foreground && !_revokedPeers.contains(id) && policy.allowsSecret(secret);
  }

  Future<void> _sendPeer(_CompanionPeer peer, Map<String, Object?> value) async {
    try {
      await peer.channel.send(value);
    } on Object {
      _disconnectPeer(peer.id, expected: peer);
    }
  }

  void _disconnectPeer(String id, {_CompanionPeer? expected}) {
    if (expected != null && !identical(_peers[id], expected)) return;
    final peer = _peers.remove(id);
    _engine.disconnect(id);
    pendingControlRequests.remove(id);
    _searchCancellations.remove(id)?.cancel();
    _textInput.disconnect(id);
    _searchSessions.remove(id);
    if (peer != null) {
      unawaited(peer.subscription?.cancel());
      unawaited(peer.channel.close());
    }
  }

  void _closeReceivers() {
    for (final id in _peers.keys.toList()) {
      _disconnectPeer(id);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _reconnectTimer?.cancel();
    _closeReceivers();
    unawaited(_receiptSubscription.cancel());
    _engine.close();
    _media.removeListener(_mediaChanged);
    unawaited(disconnect(rememberSelection: true));
    super.dispose();
  }
}

final class _CompanionPeer {
  _CompanionPeer(this.id, this.channel);
  final String id;
  final CompanionSecureChannel channel;
  StreamSubscription<Map<String, Object?>>? subscription;
  DateTime lastSeen = DateTime.now();
  int lastHistoryMs = 0, requests = 0;
  final Stopwatch rateClock = Stopwatch()..start();
  int messageCount = 0;
  final Map<String, int> historyWatermarks = {};
}
