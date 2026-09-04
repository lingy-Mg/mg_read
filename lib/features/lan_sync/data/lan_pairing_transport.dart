/// 首次设备配对的前台认证传输。
///
/// 职责：
/// - 通过配对二维码中的预共享密钥建立首次 AES-GCM 会话。
/// - 在双方显示相同确认码后，由展示二维码的一端执行唯一一次授权。
///
/// 注意：
/// - 本层不持久化配对关系；调用方必须先将 metadata 和逐设备共享密钥分别保存，再提交批准。
/// - 失败、拒绝和过期时必须关闭 socket，不能留下未提交的配对关系。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'package:mg_read/features/lan_sync/data/lan_sync_transport.dart';
import 'package:mg_read/features/lan_sync/data/paired_secure_connection.dart';
import 'package:mg_read/features/lan_sync/domain/lan_endpoint_policy.dart';
import 'package:mg_read/features/lan_sync/domain/lan_pairing_payload.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_models.dart';
import 'package:mg_read/features/lan_sync/domain/paired_device_models.dart';

final class LanPairingRequest {
  LanPairingRequest._({
    required this.pairingCode,
    required this.peer,
    required this.sharedSecret,
    required this._connection,
    required this._localIdentity,
  });

  final String pairingCode;
  final PairedDevice peer;
  final List<int> sharedSecret;
  final PairedSecureConnection _connection;
  final LocalDeviceIdentity _localIdentity;
  final Completer<void> _completion = Completer<void>();
  bool _completed = false;
  bool _responding = false;

  Future<void> get done => _completion.future;
  bool get isActive => !_completed && !_responding;

  Future<void> approve() async {
    if (!isActive) {
      throw const LanSyncTransportException('lan_sync_pairing_expired');
    }
    _responding = true;
    try {
      await _connection.sendControl(<String, Object?>{
        'type': 'paired',
        'deviceId': _localIdentity.deviceId,
        'label': _localIdentity.label,
        'platform': _localPlatform.name,
      });
      final committed = await _connection.readControl().timeout(lanSyncHandshakeTimeout);
      if (committed['type'] != 'pairCommitted' || committed['deviceId'] != peer.deviceId) {
        throw const LanSyncTransportException('lan_sync_handshake_invalid');
      }
      await _connection.sendControl(<String, Object?>{'type': 'pairComplete'});
    } finally {
      _completed = true;
      await _connection.close();
      if (!_completion.isCompleted) _completion.complete();
    }
  }

  Future<void> reject() async {
    if (_completed || _responding) return;
    _responding = true;
    _completed = true;
    try {
      await _connection.sendControl(<String, Object?>{'type': 'pairRejected'});
    } finally {
      await _connection.close();
      if (!_completion.isCompleted) _completion.complete();
    }
  }
}

final class LanPairingServer {
  LanPairingServer._({
    required this.offer,
    required this._server,
    required this._identity,
    required this._requestLifetime,
    required this._sessionLifetime,
  });

  final LanPairingOffer offer;
  final ServerSocket _server;
  final LocalDeviceIdentity _identity;
  final Duration _requestLifetime;
  final Duration _sessionLifetime;
  final StreamController<LanPairingRequest> _requests = StreamController<LanPairingRequest>.broadcast();
  final Set<Socket> _sockets = <Socket>{};
  final Set<LanPairingRequest> _pendingRequests = <LanPairingRequest>{};
  final Completer<void> _completion = Completer<void>();
  Timer? _expiry;
  bool _closed = false;

  Stream<LanPairingRequest> get requests => _requests.stream;
  Future<void> get done => _completion.future;

  static Future<LanPairingServer> start(
    LocalDeviceIdentity identity, {
    Duration requestLifetime = const Duration(minutes: 2),
    Duration sessionLifetime = lanSyncSessionLifetime,
  }) async {
    final server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    final addresses = await eligibleLanSyncAddresses();
    if (addresses.isEmpty) {
      await server.close();
      throw const LanSyncTransportException('lan_sync_address_not_private');
    }
    final pairing = LanPairingServer._(
      offer: LanPairingOffer(
        addresses: addresses,
        deviceId: identity.deviceId,
        label: identity.label,
        port: server.port,
        secret: _randomBytes(32),
        sessionId: _randomToken(18),
      ),
      server: server,
      identity: identity,
      requestLifetime: requestLifetime,
      sessionLifetime: sessionLifetime,
    );
    pairing._start();
    return pairing;
  }

  void _start() {
    _server.listen(_accept, onError: (_) => unawaited(close()), cancelOnError: false);
    _expiry = Timer(_sessionLifetime, () => unawaited(close()));
  }

  Future<void> _accept(Socket socket) async {
    if (_closed || _sockets.length >= 4 || !isLanSyncPrivateIpv4(socket.remoteAddress.address)) {
      socket.destroy();
      return;
    }
    _sockets.add(socket);
    final raw = LanSyncFramedConnection(socket);
    PairedSecureConnection? secure;
    try {
      final hello = await raw.readControl().timeout(lanSyncHandshakeTimeout);
      final clientNonce = hello['clientNonce'];
      if (hello['type'] != 'pairHello' ||
          hello['protocolVersion'] != 1 ||
          hello['sessionId'] != offer.sessionId ||
          !_isNonce(clientNonce)) {
        throw const LanSyncTransportException('lan_sync_handshake_invalid');
      }
      final serverNonce = _randomToken(16);
      await raw.sendControl(<String, Object?>{'type': 'pairChallenge', 'protocolVersion': 1, 'serverNonce': serverNonce});
      secure = await PairedSecureConnection.server(
        raw: raw,
        sharedSecret: offer.secret,
        clientNonce: clientNonce! as String,
        serverNonce: serverNonce,
      );
      final identity = await secure.readControl().timeout(lanSyncHandshakeTimeout);
      final deviceId = identity['deviceId'];
      final label = identity['label'];
      final platform = _platform(identity['platform']);
      if (identity['type'] != 'pairIdentity' ||
          deviceId is! String ||
          !isValidPairedDeviceId(deviceId) ||
          deviceId == _identity.deviceId ||
          label is! String ||
          label.trim().isEmpty ||
          label.length > 128 ||
          platform == null) {
        throw const LanSyncTransportException('lan_sync_handshake_invalid');
      }
      final code = await _pairingCode(offer.secret, '${offer.sessionId}|$clientNonce|$serverNonce|${_identity.deviceId}|$deviceId');
      final request = LanPairingRequest._(
        pairingCode: code,
        peer: PairedDevice(
          autoSync: true,
          createdAtUtc: DateTime.now().toUtc(),
          deviceId: deviceId,
          label: label,
          mode: PairedSyncMode.bidirectional,
          platform: platform,
          syncBookshelf: true,
          syncPlugins: true,
        ),
        sharedSecret: offer.secret,
        connection: secure,
        localIdentity: _identity,
      );
      _pendingRequests.add(request);
      _requests.add(request);
      try {
        await request.done.timeout(_requestLifetime);
      } on TimeoutException {
        await request.reject();
      } finally {
        _pendingRequests.remove(request);
      }
    } on Object {
      await (secure?.close() ?? raw.close());
    } finally {
      _sockets.remove(socket);
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _expiry?.cancel();
    for (final request in _pendingRequests.toList(growable: false)) {
      try {
        await request.reject();
      } on Object {
        // Continue closing the remaining sockets and request stream.
      }
    }
    _pendingRequests.clear();
    for (final socket in _sockets.toList(growable: false)) {
      socket.destroy();
    }
    _sockets.clear();
    await _server.close();
    await _requests.close();
    if (!_completion.isCompleted) _completion.complete();
  }
}

final class LanPairingClientConnection {
  LanPairingClientConnection._({
    required this.pairingCode,
    required this.peer,
    required this.sharedSecret,
    required this._connection,
    required this._localDeviceId,
  });

  final String pairingCode;
  final PairedDevice peer;
  final List<int> sharedSecret;
  final PairedSecureConnection _connection;
  final String _localDeviceId;

  static Future<LanPairingClientConnection> connect(LanPairingOffer offer, LocalDeviceIdentity identity) async {
    final result = Completer<LanPairingClientConnection>();
    final timeout = Timer(const Duration(seconds: 8), () {
      if (!result.isCompleted) {
        result.completeError(const LanSyncTransportException('lan_sync_connect_failed'));
      }
    });
    var remaining = offer.addresses.length;
    for (final address in offer.addresses) {
      unawaited(() async {
        try {
          final connection = await _connectAddress(offer, identity, address);
          if (!result.isCompleted) {
            result.complete(connection);
          } else {
            await connection.close();
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

  static Future<LanPairingClientConnection> _connectAddress(LanPairingOffer offer, LocalDeviceIdentity identity, String address) async {
    LanSyncFramedConnection? raw;
    PairedSecureConnection? secure;
    try {
      final socket = await Socket.connect(address, offer.port, timeout: const Duration(seconds: 5));
      raw = LanSyncFramedConnection(socket);
      final clientNonce = _randomToken(16);
      await raw.sendControl(<String, Object?>{
        'type': 'pairHello',
        'protocolVersion': 1,
        'sessionId': offer.sessionId,
        'clientNonce': clientNonce,
      });
      final challenge = await raw.readControl().timeout(lanSyncHandshakeTimeout);
      final serverNonce = challenge['serverNonce'];
      if (challenge['type'] != 'pairChallenge' || challenge['protocolVersion'] != 1 || !_isNonce(serverNonce)) {
        throw const LanSyncTransportException('lan_sync_handshake_invalid');
      }
      secure = await PairedSecureConnection.client(
        raw: raw,
        sharedSecret: offer.secret,
        clientNonce: clientNonce,
        serverNonce: serverNonce! as String,
      );
      await secure.sendControl(<String, Object?>{
        'type': 'pairIdentity',
        'deviceId': identity.deviceId,
        'label': identity.label,
        'platform': _localPlatform.name,
      });
      final code = await _pairingCode(offer.secret, '${offer.sessionId}|$clientNonce|$serverNonce|${offer.deviceId}|${identity.deviceId}');
      return LanPairingClientConnection._(
        pairingCode: code,
        peer: PairedDevice(
          autoSync: true,
          createdAtUtc: DateTime.now().toUtc(),
          deviceId: offer.deviceId,
          label: offer.label,
          mode: PairedSyncMode.bidirectional,
          platform: PairedDevicePlatform.unknown,
          syncBookshelf: true,
          syncPlugins: true,
        ),
        sharedSecret: offer.secret,
        connection: secure,
        localDeviceId: identity.deviceId,
      );
    } on Object {
      await (secure?.close() ?? raw?.close() ?? Future<void>.value());
      rethrow;
    }
  }

  Future<PairedDevice> waitForApproval() async {
    final result = await _connection.readControl().timeout(const Duration(minutes: 2));
    if (result['type'] == 'pairRejected') {
      throw const LanSyncTransportException('lan_sync_pairing_rejected');
    }
    final platform = _platform(result['platform']);
    final label = result['label'];
    if (result['type'] != 'paired' ||
        result['deviceId'] != peer.deviceId ||
        platform == null ||
        label is! String ||
        label.trim().isEmpty ||
        label.length > 128) {
      throw const LanSyncTransportException('lan_sync_handshake_invalid');
    }
    return peer.copyWith(label: label, platform: platform);
  }

  Future<void> confirmCommitted() async {
    await _connection.sendControl(<String, Object?>{'type': 'pairCommitted', 'deviceId': _localDeviceId});
    final complete = await _connection.readControl().timeout(lanSyncHandshakeTimeout);
    if (complete['type'] != 'pairComplete') {
      throw const LanSyncTransportException('lan_sync_handshake_invalid');
    }
    await _connection.close();
  }

  Future<void> close() => _connection.close();
}

PairedDevicePlatform get _localPlatform => Platform.isWindows
    ? PairedDevicePlatform.windows
    : Platform.isMacOS
    ? PairedDevicePlatform.macos
    : Platform.isAndroid
    ? PairedDevicePlatform.android
    : PairedDevicePlatform.unknown;

PairedDevicePlatform? _platform(Object? value) => switch (value) {
  'android' => PairedDevicePlatform.android,
  'windows' => PairedDevicePlatform.windows,
  'macos' => PairedDevicePlatform.macos,
  'unknown' => PairedDevicePlatform.unknown,
  _ => null,
};

bool _isNonce(Object? value) => value is String && value.length >= 20 && value.length <= 64 && RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value);

String _randomToken(int bytes) => base64Url.encode(_randomBytes(bytes)).replaceAll('=', '');

List<int> _randomBytes(int length) {
  final random = Random.secure();
  return List<int>.generate(length, (_) => random.nextInt(256), growable: false);
}

Future<String> _pairingCode(List<int> secret, String transcript) async {
  final mac = await Hmac.sha256().calculateMac(utf8.encode(transcript), secretKey: SecretKey(secret));
  final value = ByteData.sublistView(Uint8List.fromList(mac.bytes)).getUint32(0, Endian.big) % 1000000;
  return value.toString().padLeft(6, '0');
}
