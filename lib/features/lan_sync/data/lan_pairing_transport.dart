/// 首次设备配对的 HTTP 前台认证流程。
///
/// 二维码预共享密钥只用于 HMAC 请求认证；身份、审批状态和提交确认均通过
/// 有界 JSON HTTP API 交换，不再建立自定义 TCP/加密帧连接。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'package:mg_read/features/lan_sync/data/lan_sync_http_artifact.dart';
import 'package:mg_read/features/lan_sync/data/lan_sync_http_client.dart';
import 'package:mg_read/features/lan_sync/data/lan_sync_transport.dart';
import 'package:mg_read/features/lan_sync/domain/lan_endpoint_policy.dart';
import 'package:mg_read/features/lan_sync/domain/lan_pairing_payload.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_models.dart';
import 'package:mg_read/features/lan_sync/domain/paired_device_models.dart';

final class LanPairingRequest {
  LanPairingRequest._({
    required this.pairingCode,
    required this.peer,
    required this.sharedSecret,
    required this.requestId,
    required this.localIdentity,
  });
  final String pairingCode;
  final PairedDevice peer;
  final List<int> sharedSecret;
  final String requestId;
  final LocalDeviceIdentity localIdentity;
  final Completer<Map<String, Object?>> decision = Completer<Map<String, Object?>>();
  final Completer<void> committed = Completer<void>();
  final Completer<void> completion = Completer<void>();
  bool responding = false;
  Future<void> get done => completion.future;
  bool get isActive => !completion.isCompleted && !responding;

  Future<void> approve() async {
    if (!isActive) throw const LanSyncTransportException('lan_sync_pairing_expired');
    responding = true;
    decision.complete(<String, Object?>{
      'status': 'approved',
      'deviceId': localIdentity.deviceId,
      'label': localIdentity.label,
      'platform': _localPlatform.name,
    });
    try {
      await committed.future.timeout(lanSyncHandshakeTimeout);
    } finally {
      if (!completion.isCompleted) completion.complete();
    }
  }

  Future<void> reject() async {
    if (completion.isCompleted) return;
    responding = true;
    if (!decision.isCompleted) decision.complete(<String, Object?>{'status': 'rejected'});
    completion.complete();
  }
}

final class LanPairingServer {
  LanPairingServer._(this.offer, this._server, this._identity);
  final LanPairingOffer offer;
  final HttpServer _server;
  final LocalDeviceIdentity _identity;
  final requestsController = StreamController<LanPairingRequest>.broadcast();
  final pending = <String, LanPairingRequest>{};
  final nonces = <String, int>{};
  final completion = Completer<void>();
  Timer? expiry;
  bool closed = false;
  Stream<LanPairingRequest> get requests => requestsController.stream;
  Future<void> get done => completion.future;

  static Future<LanPairingServer> start(
    LocalDeviceIdentity identity, {
    Duration requestLifetime = const Duration(minutes: 2),
    Duration sessionLifetime = lanSyncSessionLifetime,
  }) async {
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    final addresses = await eligibleLanSyncAddresses();
    if (addresses.isEmpty) {
      await server.close(force: true);
      throw const LanSyncTransportException('lan_sync_address_not_private');
    }
    final offer = LanPairingOffer(
      addresses: addresses,
      deviceId: identity.deviceId,
      label: identity.label,
      port: server.port,
      secret: _randomBytes(32),
      sessionId: _randomToken(18),
    );
    final result = LanPairingServer._(offer, server, identity);
    server.listen((request) => result._handle(request, requestLifetime), onError: (_) => unawaited(result.close()));
    result.expiry = Timer(sessionLifetime, () => unawaited(result.close()));
    return result;
  }

  Future<void> _handle(HttpRequest request, Duration requestLifetime) async {
    try {
      if (!isLanSyncPrivateIpv4(request.connectionInfo?.remoteAddress.address ?? '') ||
          !LanSyncHttpAuthentication.verify(request, sharedSecret: offer.secret, acceptedNonces: nonces)) {
        return await _json(request.response, HttpStatus.unauthorized, <String, Object?>{'error': 'unauthorized'});
      }
      final segments = request.uri.pathSegments;
      if (request.method == 'POST' && request.uri.path == '/v3/pair') {
        final rawBytes = await _readBytes(request);
        if (LanSyncHttpAuthentication.bodyHash(rawBytes) != request.headers.value(LanSyncHttpAuthentication.contentHashHeader)) {
          return await _json(request.response, HttpStatus.badRequest, <String, Object?>{'error': 'content_hash'});
        }
        final body = _decodeJson(rawBytes);
        final deviceId = body['deviceId'];
        final label = body['label'];
        final platform = _platform(body['platform']);
        final clientNonce = body['clientNonce'];
        if (body['sessionId'] != offer.sessionId ||
            deviceId is! String ||
            !isValidPairedDeviceId(deviceId) ||
            deviceId == _identity.deviceId ||
            label is! String ||
            label.trim().isEmpty ||
            label.length > 128 ||
            platform == null ||
            !_validNonce(clientNonce)) {
          return await _json(request.response, HttpStatus.badRequest, <String, Object?>{'error': 'invalid_request'});
        }
        final requestId = _randomToken(18);
        final serverNonce = _randomToken(16);
        final code = _pairingCode(offer.secret, '${offer.sessionId}|$clientNonce|$serverNonce|${_identity.deviceId}|$deviceId');
        final item = LanPairingRequest._(
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
          requestId: requestId,
          localIdentity: _identity,
        );
        pending[requestId] = item;
        requestsController.add(item);
        unawaited(Future<void>.delayed(requestLifetime).then((_) => item.reject()));
        unawaited(item.done.whenComplete(() => pending.remove(requestId)));
        return await _json(request.response, HttpStatus.created, <String, Object?>{
          'requestId': requestId,
          'serverNonce': serverNonce,
          'pairingCode': code,
        });
      }
      if (request.method == 'GET' && segments.length == 4 && segments[0] == 'v3' && segments[1] == 'pair' && segments[3] == 'status') {
        final item = pending[segments[2]];
        if (item == null) {
          return await _json(request.response, HttpStatus.notFound, <String, Object?>{'status': 'expired'});
        }
        final value = await item.decision.future.timeout(requestLifetime, onTimeout: () => <String, Object?>{'status': 'expired'});
        return await _json(request.response, HttpStatus.ok, value);
      }
      if (request.method == 'POST' && segments.length == 4 && segments[0] == 'v3' && segments[1] == 'pair' && segments[3] == 'commit') {
        final item = pending[segments[2]];
        if (item == null || !item.decision.isCompleted) {
          return await _json(request.response, HttpStatus.conflict, <String, Object?>{'error': 'not_approved'});
        }
        await _json(request.response, HttpStatus.ok, <String, Object?>{'status': 'complete'});
        if (!item.committed.isCompleted) item.committed.complete();
        return;
      }
      return await _json(request.response, HttpStatus.notFound, <String, Object?>{'error': 'not_found'});
    } on Object {
      try {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
      } on Object {
        // The peer may have closed after the response was committed.
      }
    }
  }

  Future<void> close() async {
    if (closed) return;
    closed = true;
    expiry?.cancel();
    for (final item in pending.values.toList()) {
      await item.reject();
    }
    pending.clear();
    await _server.close(force: true);
    await requestsController.close();
    if (!completion.isCompleted) completion.complete();
  }
}

final class LanPairingClientConnection {
  LanPairingClientConnection._(this.pairingCode, this.peer, this.sharedSecret, this._baseUri, this._requestId, this._localDeviceId);
  final String pairingCode;
  final PairedDevice peer;
  final List<int> sharedSecret;
  final Uri _baseUri;
  final String _requestId;
  final String _localDeviceId;
  final HttpClient _client = createLanSyncHttpClient();

  static Future<LanPairingClientConnection> connect(LanPairingOffer offer, LocalDeviceIdentity identity) async {
    final result = Completer<LanPairingClientConnection>();
    final timeout = Timer(const Duration(seconds: 8), () {
      if (!result.isCompleted) {
        result.completeError(const LanSyncTransportException('lan_sync_connect_timeout'));
      }
    });
    Object? lastError;
    StackTrace? lastStackTrace;
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
          lastError = error;
          lastStackTrace = stackTrace;
          remaining--;
          if (remaining == 0 && !result.isCompleted) {
            result.completeError(lastError!, lastStackTrace!);
          }
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
    final client = createLanSyncHttpClient();
    try {
      final base = Uri.parse('http://$address:${offer.port}');
      final clientNonce = _randomToken(16);
      final body = <String, Object?>{
        'sessionId': offer.sessionId,
        'deviceId': identity.deviceId,
        'label': identity.label,
        'platform': _localPlatform.name,
        'clientNonce': clientNonce,
      };
      final result = await _requestJson(client, base.resolve('/v3/pair'), 'POST', body, identity.deviceId, offer.secret);
      final serverNonce = result['serverNonce'];
      final code = result['pairingCode'];
      final requestId = result['requestId'];
      final expected = _pairingCode(offer.secret, '${offer.sessionId}|$clientNonce|$serverNonce|${offer.deviceId}|${identity.deviceId}');
      if (!_validNonce(serverNonce) || !_validNonce(requestId) || code != expected) {
        throw const LanSyncTransportException('lan_sync_pairing_invalid');
      }
      return LanPairingClientConnection._(
        code! as String,
        PairedDevice(
          autoSync: true,
          createdAtUtc: DateTime.now().toUtc(),
          deviceId: offer.deviceId,
          label: offer.label,
          mode: PairedSyncMode.bidirectional,
          platform: PairedDevicePlatform.unknown,
          syncBookshelf: true,
          syncPlugins: true,
        ),
        offer.secret,
        base,
        requestId! as String,
        identity.deviceId,
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<PairedDevice> waitForApproval() async {
    final result = await _requestJson(_client, _baseUri.resolve('/v3/pair/$_requestId/status'), 'GET', null, _localDeviceId, sharedSecret);
    if (result['status'] == 'rejected') throw const LanSyncTransportException('lan_sync_pairing_rejected');
    final platform = _platform(result['platform']);
    final label = result['label'];
    if (result['status'] != 'approved' || result['deviceId'] != peer.deviceId || platform == null || label is! String) {
      throw const LanSyncTransportException('lan_sync_handshake_invalid');
    }
    return peer.copyWith(label: label, platform: platform);
  }

  Future<void> confirmCommitted() async {
    final result = await _requestJson(
      _client,
      _baseUri.resolve('/v3/pair/$_requestId/commit'),
      'POST',
      const <String, Object?>{},
      _localDeviceId,
      sharedSecret,
    );
    if (result['status'] != 'complete') throw const LanSyncTransportException('lan_sync_handshake_invalid');
    await close();
  }

  Future<void> close() async => _client.close(force: true);
}

Future<Map<String, Object?>> _requestJson(
  HttpClient client,
  Uri uri,
  String method,
  Map<String, Object?>? value,
  String deviceId,
  List<int> secret,
) async {
  final body = value == null ? const <int>[] : utf8.encode(jsonEncode(value));
  final request = await client.openUrl(method, uri);
  LanSyncHttpAuthentication.sign(
    request,
    deviceId: deviceId,
    sharedSecret: secret,
    contentSha256: LanSyncHttpAuthentication.bodyHash(body),
  );
  request.headers.contentType = ContentType.json;
  request.contentLength = body.length;
  request.add(body);
  final response = await request.close().timeout(const Duration(minutes: 2));
  final decoded = jsonDecode(await utf8.decodeStream(response));
  if (response.statusCode < 200 || response.statusCode >= 300 || decoded is! Map) {
    throw LanSyncTransportException('lan_sync_http_failed', reason: 'status_${response.statusCode}');
  }
  return decoded.map<String, Object?>((key, value) => MapEntry(key as String, value));
}

Future<List<int>> _readBytes(HttpRequest request) => request.fold<List<int>>(<int>[], (all, chunk) {
  if (all.length + chunk.length > 64 * 1024) throw const LanSyncTransportException('lan_sync_control_too_large');
  return all..addAll(chunk);
});
Map<String, Object?> _decodeJson(List<int> bytes) {
  final value = jsonDecode(utf8.decode(bytes));
  if (value is! Map) throw const FormatException();
  return value.map<String, Object?>((key, value) => MapEntry(key as String, value));
}

Future<void> _json(HttpResponse response, int status, Map<String, Object?> value) async {
  final bytes = utf8.encode(jsonEncode(value));
  response.statusCode = status;
  response.headers.contentType = ContentType.json;
  response.contentLength = bytes.length;
  response.add(bytes);
  await response.close();
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
bool _validNonce(Object? value) =>
    value is String && value.length >= 20 && value.length <= 64 && RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value);
String _randomToken(int bytes) => base64Url.encode(_randomBytes(bytes)).replaceAll('=', '');
List<int> _randomBytes(int length) {
  final random = Random.secure();
  return List<int>.generate(length, (_) => random.nextInt(256));
}

String _pairingCode(List<int> secret, String transcript) {
  final bytes = Hmac(sha256, secret).convert(utf8.encode(transcript)).bytes;
  final value = ByteData.sublistView(Uint8List.fromList(bytes)).getUint32(0, Endian.big) % 1000000;
  return value.toString().padLeft(6, '0');
}
