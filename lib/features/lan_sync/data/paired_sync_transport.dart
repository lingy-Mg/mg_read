/// 已配对设备的动态发现、认证连接与双向同步协议。
///
/// 职责：
/// - 广播稳定设备 ID 和本次前台端口，IP 始终取自收到的数据包。
/// - 使用逐设备共享密钥建立认证加密会话，并按双方策略同步插件和书架。
/// - 支持自动双向同步与接收端主动“只拉取一次”。
///
/// 注意：
/// - 广播不包含密钥、书名、插件名或持久地址。
/// - 删除不传播；书架冲突沿用 smartMerge，开发书源冲突由 Runtime 计划明确跳过。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:mg_read/features/lan_sync/application/device_identity_store.dart';
import 'package:mg_read/features/lan_sync/application/lan_sync_gateway.dart';
import 'package:mg_read/features/lan_sync/application/paired_device_repository.dart';
import 'package:mg_read/features/lan_sync/data/lan_sync_transport.dart';
import 'package:mg_read/features/lan_sync/data/paired_secure_connection.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_models.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_qr_payload.dart';
import 'package:mg_read/features/lan_sync/domain/paired_device_models.dart';

part 'paired_sync_payload.dart';

const int pairedSyncProtocolVersion = 2;
const int pairedSyncDiscoveryPort = 47232;
const Duration pairedSyncPeerLifetime = Duration(seconds: 8);

final class PairedSyncEndpoint {
  const PairedSyncEndpoint({
    required this.address,
    required this.deviceId,
    required this.expiresAtUtc,
    required this.label,
    required this.port,
  });

  final String address;
  final String deviceId;
  final DateTime expiresAtUtc;
  final String label;
  final int port;
}

final class PairedSyncRunSummary {
  const PairedSyncRunSummary({
    required this.receivedBooks,
    required this.receivedPlugins,
    required this.sentBooks,
    required this.sentPlugins,
    required this.developmentConflicts,
  });

  const PairedSyncRunSummary.empty() : receivedBooks = 0, receivedPlugins = 0, sentBooks = 0, sentPlugins = 0, developmentConflicts = 0;

  final int receivedBooks;
  final int receivedPlugins;
  final int sentBooks;
  final int sentPlugins;
  final int developmentConflicts;
}

/// The connection failed after at least one side confirmed durable changes.
final class PairedSyncPartialException implements Exception {
  const PairedSyncPartialException(this.cause);

  final Object cause;
}

final class PairedSyncHost {
  PairedSyncHost._({
    required this.identity,
    required this._server,
    required this._socket,
    required this._devices,
    required this._identityStore,
    required this._onIncoming,
  });

  final LocalDeviceIdentity identity;
  final ServerSocket _server;
  final RawDatagramSocket _socket;
  final PairedDeviceRepository _devices;
  final DeviceIdentityStore _identityStore;
  final Future<void> Function(PairedSyncServerSession session) _onIncoming;
  final StreamController<PairedSyncEndpoint> _endpoints = StreamController<PairedSyncEndpoint>.broadcast();
  final Set<Socket> _connections = <Socket>{};
  Timer? _announcer;
  bool _closed = false;

  Stream<PairedSyncEndpoint> get endpoints => _endpoints.stream;
  int get port => _server.port;

  static Future<PairedSyncHost> start({
    required LocalDeviceIdentity identity,
    required PairedDeviceRepository devices,
    required DeviceIdentityStore identityStore,
    required Future<void> Function(PairedSyncServerSession session) onIncoming,
  }) async {
    final server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, pairedSyncDiscoveryPort, reuseAddress: true);
      socket.broadcastEnabled = true;
      final host = PairedSyncHost._(
        identity: identity,
        server: server,
        socket: socket,
        devices: devices,
        identityStore: identityStore,
        onIncoming: onIncoming,
      );
      host._start();
      return host;
    } on Object {
      socket?.close();
      await server.close();
      rethrow;
    }
  }

  void _start() {
    _server.listen(_accept, onError: (_) => unawaited(close()), cancelOnError: false);
    _socket.listen(_onDatagram, onError: (_) {}, cancelOnError: false);
    _announce();
    _announcer = Timer.periodic(const Duration(seconds: 2), (_) => _announce());
  }

  void _announce() {
    if (_closed) return;
    final bytes = utf8.encode(
      jsonEncode(<String, Object?>{
        'kind': 'mgread-paired-sync',
        'protocolVersion': pairedSyncProtocolVersion,
        'deviceId': identity.deviceId,
        'label': identity.label,
        'port': _server.port,
      }),
    );
    try {
      _socket.send(bytes, InternetAddress('255.255.255.255'), pairedSyncDiscoveryPort);
    } on Object {
      // 下一次周期广播会重试；已知 endpoint 仍可继续当前会话。
    }
  }

  void _onDatagram(RawSocketEvent event) {
    if (event != RawSocketEvent.read || _closed) return;
    Datagram? datagram;
    while ((datagram = _socket.receive()) != null) {
      final packet = datagram!;
      try {
        if (!isLanSyncPrivateIpv4(packet.address.address)) continue;
        final raw = jsonDecode(utf8.decode(packet.data));
        if (raw is! Map || raw['kind'] != 'mgread-paired-sync' || raw['protocolVersion'] != pairedSyncProtocolVersion) {
          continue;
        }
        final deviceId = raw['deviceId'];
        final label = raw['label'];
        final port = raw['port'];
        if (deviceId is! String ||
            deviceId == identity.deviceId ||
            !isValidPairedDeviceId(deviceId) ||
            label is! String ||
            label.trim().isEmpty ||
            label.length > 128 ||
            port is! int ||
            port < 1 ||
            port > 65535) {
          continue;
        }
        _endpoints.add(
          PairedSyncEndpoint(
            address: packet.address.address,
            deviceId: deviceId,
            expiresAtUtc: DateTime.now().toUtc().add(pairedSyncPeerLifetime),
            label: label,
            port: port,
          ),
        );
      } on Object {
        // 未认证广播不可信，格式错误直接忽略。
      }
    }
  }

  Future<void> _accept(Socket socket) async {
    if (_closed || _connections.length >= 4 || !_eligiblePeer(socket.remoteAddress)) {
      socket.destroy();
      return;
    }
    _connections.add(socket);
    LanSyncFramedConnection? raw;
    PairedSecureConnection? secure;
    try {
      raw = LanSyncFramedConnection(socket);
      final hello = await raw.readControl().timeout(lanSyncHandshakeTimeout);
      final peerDeviceId = hello['deviceId'];
      final clientNonce = hello['clientNonce'];
      if (hello['type'] != 'pairedHello' ||
          hello['protocolVersion'] != pairedSyncProtocolVersion ||
          hello['targetDeviceId'] != identity.deviceId ||
          peerDeviceId is! String ||
          !isValidPairedDeviceId(peerDeviceId) ||
          !_validNonce(clientNonce)) {
        throw const LanSyncTransportException('lan_sync_handshake_invalid');
      }
      final peer = await _devices.read(peerDeviceId);
      final secret = await _identityStore.readPeerSecret(peerDeviceId);
      if (peer == null || secret == null) {
        throw const LanSyncTransportException('lan_sync_peer_not_paired');
      }
      final serverNonce = _randomToken(16);
      await raw.sendControl(<String, Object?>{
        'type': 'pairedChallenge',
        'protocolVersion': pairedSyncProtocolVersion,
        'serverNonce': serverNonce,
      });
      secure = await PairedSecureConnection.server(
        raw: raw,
        sharedSecret: secret,
        clientNonce: clientNonce! as String,
        serverNonce: serverNonce,
      );
      await secure.sendControl(<String, Object?>{'type': 'pairedReady', 'deviceId': identity.deviceId, 'label': identity.label});
      final session = PairedSyncServerSession._(connection: secure, peer: peer);
      secure = null;
      await _onIncoming(session);
    } on Object {
      await (secure?.close() ?? raw?.close() ?? Future<void>.value());
    } finally {
      _connections.remove(socket);
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _announcer?.cancel();
    _socket.close();
    for (final socket in _connections.toList(growable: false)) {
      socket.destroy();
    }
    _connections.clear();
    await _server.close();
    await _endpoints.close();
  }
}

final class PairedSyncClientSession {
  PairedSyncClientSession._({required this.peer, required this._connection});

  final PairedDevice peer;
  final PairedSecureConnection _connection;

  static Future<PairedSyncClientSession> connectAny({
    required Iterable<PairedSyncEndpoint> endpoints,
    required LocalDeviceIdentity identity,
    required PairedDevice peer,
    required List<int> sharedSecret,
  }) async {
    final candidates = endpoints.where((item) => item.deviceId == peer.deviceId).toList(growable: false);
    if (candidates.isEmpty) throw const LanSyncTransportException('lan_sync_peer_offline');
    final result = Completer<PairedSyncClientSession>();
    final timeout = Timer(const Duration(seconds: 8), () {
      if (!result.isCompleted) {
        result.completeError(const LanSyncTransportException('lan_sync_connect_failed'));
      }
    });
    var remaining = candidates.length;
    for (final endpoint in candidates) {
      unawaited(() async {
        try {
          final session = await _connect(endpoint, identity, peer, sharedSecret);
          if (result.isCompleted) {
            await session.close();
          } else {
            result.complete(session);
          }
        } on Object catch (error, stackTrace) {
          remaining--;
          if (remaining == 0 && !result.isCompleted) result.completeError(error, stackTrace);
        }
      }());
    }
    try {
      return await result.future;
    } finally {
      timeout.cancel();
    }
  }

  static Future<PairedSyncClientSession> _connect(
    PairedSyncEndpoint endpoint,
    LocalDeviceIdentity identity,
    PairedDevice peer,
    List<int> sharedSecret,
  ) async {
    if (!isLanSyncPrivateIpv4(endpoint.address)) {
      throw const LanSyncTransportException('lan_sync_address_not_private');
    }
    LanSyncFramedConnection? raw;
    PairedSecureConnection? secure;
    try {
      final socket = await Socket.connect(endpoint.address, endpoint.port, timeout: const Duration(seconds: 5));
      raw = LanSyncFramedConnection(socket);
      final clientNonce = _randomToken(16);
      await raw.sendControl(<String, Object?>{
        'type': 'pairedHello',
        'protocolVersion': pairedSyncProtocolVersion,
        'deviceId': identity.deviceId,
        'targetDeviceId': peer.deviceId,
        'clientNonce': clientNonce,
      });
      final challenge = await raw.readControl().timeout(lanSyncHandshakeTimeout);
      final serverNonce = challenge['serverNonce'];
      if (challenge['type'] != 'pairedChallenge' ||
          challenge['protocolVersion'] != pairedSyncProtocolVersion ||
          !_validNonce(serverNonce)) {
        throw const LanSyncTransportException('lan_sync_handshake_invalid');
      }
      secure = await PairedSecureConnection.client(
        raw: raw,
        sharedSecret: sharedSecret,
        clientNonce: clientNonce,
        serverNonce: serverNonce! as String,
      );
      final ready = await secure.readControl().timeout(lanSyncHandshakeTimeout);
      if (ready['type'] != 'pairedReady' || ready['deviceId'] != peer.deviceId) {
        throw const LanSyncTransportException('lan_sync_handshake_invalid');
      }
      return PairedSyncClientSession._(peer: peer, connection: secure);
    } on Object {
      await (secure?.close() ?? raw?.close() ?? Future<void>.value());
      rethrow;
    }
  }

  Future<PairedSyncRunSummary> run({required LanSyncGateway gateway, required bool pullOnly}) async {
    var committed = false;
    try {
      final localPolicy = _WirePolicy.fromDevice(peer, pullOnly: pullOnly);
      await _connection.sendControl(<String, Object?>{'type': 'syncRequest', ...localPolicy.toJson()});
      final ready = await _connection.readControl().timeout(lanSyncHandshakeTimeout);
      if (ready['type'] == 'syncBusy') throw const LanSyncTransportException('lan_sync_peer_busy');
      if (ready['type'] != 'syncReady') throw const LanSyncTransportException('lan_sync_handshake_invalid');
      final remotePolicy = _WirePolicy.fromJson(ready);

      final localManifest = await _createPairedManifest(
        gateway,
        includePlugins: localPolicy.canSend && localPolicy.syncPlugins && remotePolicy.canReceive && remotePolicy.syncPlugins,
        includeShelf: localPolicy.canSend && localPolicy.syncBookshelf && remotePolicy.canReceive && remotePolicy.syncBookshelf,
        deferPluginArtifacts: true,
      );
      await _sendManifest(_connection, localManifest);
      final remoteManifest = await _readManifest(_connection);
      final receivePlan = await _planImport(gateway, remoteManifest);
      await _sendSelection(_connection, receivePlan.selection);
      final sendSelection = await _readSelection(_connection, localManifest);

      final received = await _receivePayload(_connection, gateway, remoteManifest, receivePlan);
      committed = received.books > 0 || received.plugins > 0;
      await _connection.sendControl(<String, Object?>{'type': 'receiveApplied', ...received.toJson()});
      final reverseReady = await _connection.readControl().timeout(lanSyncTransferIdleTimeout);
      if (reverseReady['type'] != 'reverseReady') throw const LanSyncTransportException('lan_sync_frame_unexpected');
      await _sendPayload(_connection, gateway, localManifest, sendSelection);
      final remoteApplied = _AppliedSummary.fromJson(
        await _connection.readControl().timeout(lanSyncTransferIdleTimeout),
        expectedType: 'receiveApplied',
      );
      await _connection.sendControl(<String, Object?>{'type': 'sessionComplete'});
      final complete = await _connection.readControl().timeout(lanSyncHandshakeTimeout);
      if (complete['type'] != 'sessionComplete') throw const LanSyncTransportException('lan_sync_frame_unexpected');
      return PairedSyncRunSummary(
        receivedBooks: received.books,
        receivedPlugins: received.plugins,
        sentBooks: remoteApplied.books,
        sentPlugins: remoteApplied.plugins,
        developmentConflicts: receivePlan.developmentConflicts + remoteApplied.developmentConflicts,
      );
    } on PairedSyncPartialException {
      rethrow;
    } on Object catch (error, stackTrace) {
      if (committed) throw PairedSyncPartialException(error);
      Error.throwWithStackTrace(error, stackTrace);
    } finally {
      await close();
    }
  }

  Future<void> close() => _connection.close();
}

final class PairedSyncServerSession {
  PairedSyncServerSession._({required this.peer, required this._connection});

  final PairedDevice peer;
  final PairedSecureConnection _connection;

  Future<void> rejectBusy() async {
    try {
      await _connection.sendControl(<String, Object?>{'type': 'syncBusy'});
    } finally {
      await close();
    }
  }

  Future<PairedSyncRunSummary> run({required LanSyncGateway gateway}) async {
    var committed = false;
    try {
      final request = await _connection.readControl().timeout(lanSyncHandshakeTimeout);
      if (request['type'] != 'syncRequest') throw const LanSyncTransportException('lan_sync_handshake_invalid');
      final remotePolicy = _WirePolicy.fromJson(request);
      final localPolicy = _WirePolicy.fromDevice(peer);
      await _connection.sendControl(<String, Object?>{'type': 'syncReady', ...localPolicy.toJson()});

      final remoteManifest = await _readManifest(_connection);
      final localManifest = await _createPairedManifest(
        gateway,
        includePlugins: localPolicy.canSend && localPolicy.syncPlugins && remotePolicy.canReceive && remotePolicy.syncPlugins,
        includeShelf: localPolicy.canSend && localPolicy.syncBookshelf && remotePolicy.canReceive && remotePolicy.syncBookshelf,
        deferPluginArtifacts: true,
      );
      await _sendManifest(_connection, localManifest);
      final sendSelection = await _readSelection(_connection, localManifest);
      final receivePlan = await _planImport(gateway, remoteManifest);
      await _sendSelection(_connection, receivePlan.selection);

      await _sendPayload(_connection, gateway, localManifest, sendSelection);
      final remoteApplied = _AppliedSummary.fromJson(
        await _connection.readControl().timeout(lanSyncTransferIdleTimeout),
        expectedType: 'receiveApplied',
      );
      committed = remoteApplied.books > 0 || remoteApplied.plugins > 0;
      await _connection.sendControl(<String, Object?>{'type': 'reverseReady'});
      final received = await _receivePayload(_connection, gateway, remoteManifest, receivePlan);
      committed = committed || received.books > 0 || received.plugins > 0;
      await _connection.sendControl(<String, Object?>{'type': 'receiveApplied', ...received.toJson()});
      final complete = await _connection.readControl().timeout(lanSyncHandshakeTimeout);
      if (complete['type'] != 'sessionComplete') throw const LanSyncTransportException('lan_sync_frame_unexpected');
      await _connection.sendControl(<String, Object?>{'type': 'sessionComplete'});
      return PairedSyncRunSummary(
        receivedBooks: received.books,
        receivedPlugins: received.plugins,
        sentBooks: remoteApplied.books,
        sentPlugins: remoteApplied.plugins,
        developmentConflicts: receivePlan.developmentConflicts + remoteApplied.developmentConflicts,
      );
    } on PairedSyncPartialException {
      rethrow;
    } on Object catch (error, stackTrace) {
      if (committed) throw PairedSyncPartialException(error);
      Error.throwWithStackTrace(error, stackTrace);
    } finally {
      await close();
    }
  }

  Future<void> close() => _connection.close();
}

final class _WirePolicy {
  const _WirePolicy({required this.canReceive, required this.canSend, required this.syncBookshelf, required this.syncPlugins});

  final bool canReceive;
  final bool canSend;
  final bool syncBookshelf;
  final bool syncPlugins;

  factory _WirePolicy.fromDevice(PairedDevice device, {bool pullOnly = false}) => _WirePolicy(
    canReceive: device.canReceive,
    canSend: device.canSend && !pullOnly,
    syncBookshelf: device.syncBookshelf,
    syncPlugins: device.syncPlugins,
  );

  factory _WirePolicy.fromJson(Map<String, Object?> json) {
    final values = <Object?>[json['canReceive'], json['canSend'], json['syncBookshelf'], json['syncPlugins']];
    if (values.any((value) => value is! bool)) throw const LanSyncTransportException('lan_sync_policy_invalid');
    return _WirePolicy(
      canReceive: json['canReceive']! as bool,
      canSend: json['canSend']! as bool,
      syncBookshelf: json['syncBookshelf']! as bool,
      syncPlugins: json['syncPlugins']! as bool,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'canReceive': canReceive,
    'canSend': canSend,
    'syncBookshelf': syncBookshelf,
    'syncPlugins': syncPlugins,
  };
}

bool _eligiblePeer(InternetAddress address) => address.type == InternetAddressType.IPv4 && isLanSyncPrivateIpv4(address.address);

bool _validNonce(Object? value) =>
    value is String && value.length >= 20 && value.length <= 64 && RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value);

String _randomToken(int length) {
  final random = Random.secure();
  return base64Url.encode(List<int>.generate(length, (_) => random.nextInt(256), growable: false)).replaceAll('=', '');
}
