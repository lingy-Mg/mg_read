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

import 'package:mg_read/features/lan_sync/data/lan_pairing_authentication.dart';
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
    required this.companionOnly,
  });
  final String pairingCode;
  final PairedDevice peer;
  final List<int> sharedSecret;
  final String requestId;
  final LocalDeviceIdentity localIdentity;
  final bool companionOnly;
  final Completer<Map<String, Object?>> decision = Completer<Map<String, Object?>>();
  final Completer<void> committed = Completer<void>();
  final Completer<void> rejected = Completer<void>();
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
      final outcome = await Future.any<bool>(<Future<bool>>[
        committed.future.then((_) => true),
        rejected.future.then((_) => false),
      ]).timeout(lanSyncHandshakeTimeout);
      if (!outcome) throw const LanSyncTransportException('lan_sync_pairing_rejected');
    } finally {
      if (!completion.isCompleted) completion.complete();
    }
  }

  Future<void> reject() async {
    if (completion.isCompleted) return;
    responding = true;
    if (!rejected.isCompleted) rejected.complete();
    if (!decision.isCompleted) decision.complete(<String, Object?>{'status': 'rejected'});
    completion.complete();
  }
}

final class LanPairingServer {
  LanPairingServer._(this.offer, this._server, this._identity, this.manualPairingCode);
  final LanPairingOffer offer;
  final HttpServer _server;
  final LocalDeviceIdentity _identity;
  final String? manualPairingCode;
  final requestsController = StreamController<LanPairingRequest>.broadcast();
  final pending = <String, LanPairingRequest>{};
  final nonces = <String, int>{};
  final v4Nonces = <String, int>{};
  final failedV4Attempts = <String, List<int>>{};
  final completion = Completer<void>();
  Timer? expiry;
  bool closed = false;
  Stream<LanPairingRequest> get requests => requestsController.stream;
  Future<void> get done => completion.future;

  static Future<LanPairingServer> start(
    LocalDeviceIdentity identity, {
    bool companionOnly = false,
    Duration requestLifetime = const Duration(minutes: 2),
    Duration sessionLifetime = lanSyncSessionLifetime,
  }) async {
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    final addresses = await eligibleLanSyncAddresses();
    if (addresses.isEmpty) {
      await server.close(force: true);
      throw const LanSyncTransportException('lan_sync_address_not_private');
    }
    final sessionId = _randomToken(18);
    final manualSeed = companionOnly ? _randomBytes(16) : null;
    final pairingSecret = manualSeed == null ? _randomBytes(32) : await deriveCompanionManualSecret(manualSeed, sessionId);
    final offer = LanPairingOffer(
      addresses: addresses,
      deviceId: identity.deviceId,
      label: identity.label,
      port: server.port,
      secret: pairingSecret,
      sessionId: sessionId,
      companionOnly: companionOnly,
    );
    final result = LanPairingServer._(offer, server, identity, manualSeed == null ? null : encodeCompanionManualSeed(manualSeed));
    server.listen((request) => result._handle(request, requestLifetime), onError: (_) => unawaited(result.close()));
    result.expiry = Timer(sessionLifetime, () => unawaited(result.close()));
    return result;
  }

  Future<void> _handle(HttpRequest request, Duration requestLifetime) async {
    try {
      final remoteAddress = request.connectionInfo?.remoteAddress.address ?? '';
      if (request.method == 'GET' && request.uri.path == '/v4/pairing-offer') {
        if (!offer.companionOnly || !isLanSyncPrivateIpv4(remoteAddress)) {
          return await _json(request.response, HttpStatus.notFound, <String, Object?>{'error': 'not_found'});
        }
        return await _json(request.response, HttpStatus.ok, <String, Object?>{
          'version': 4,
          'sessionId': offer.sessionId,
          'deviceId': offer.deviceId,
          'label': offer.label,
        });
      }
      if (!isLanSyncPrivateIpv4(remoteAddress)) {
        return await _json(request.response, HttpStatus.unauthorized, <String, Object?>{'error': 'unauthorized'});
      }
      if (request.uri.path.startsWith('/v4/')) {
        if (!offer.companionOnly || _v4IsRateLimited(remoteAddress)) {
          return await _json(
            request.response,
            _v4IsRateLimited(remoteAddress) ? HttpStatus.tooManyRequests : HttpStatus.notFound,
            <String, Object?>{'error': 'not_found'},
          );
        }
        final rawBytes = await _readBytes(request);
        final proof = CompanionPairingAuthentication.verifyRequest(
          request,
          sharedSecret: offer.secret,
          body: rawBytes,
          acceptedNonces: v4Nonces,
        );
        if (proof == null) {
          _recordV4Failure(remoteAddress);
          return await _json(request.response, HttpStatus.unauthorized, <String, Object?>{'error': 'unauthorized'});
        }
        try {
          return await _handleV4(request, rawBytes, proof, requestLifetime);
        } on Object {
          return await _v4Json(request.response, HttpStatus.badRequest, <String, Object?>{'error': 'invalid_request'}, proof);
        }
      }
      if (offer.companionOnly || !LanSyncHttpAuthentication.verify(request, sharedSecret: offer.secret, acceptedNonces: nonces)) {
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
          companionOnly: false,
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

  bool _v4IsRateLimited(String address) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final attempts = failedV4Attempts[address];
    if (attempts == null) return false;
    attempts.removeWhere((time) => now - time > 60000);
    if (attempts.isEmpty) failedV4Attempts.remove(address);
    return attempts.length >= 5;
  }

  void _recordV4Failure(String address) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!failedV4Attempts.containsKey(address) && failedV4Attempts.length >= 1024) {
      final oldestAddress = failedV4Attempts.entries.reduce((a, b) => a.value.first <= b.value.first ? a : b).key;
      failedV4Attempts.remove(oldestAddress);
    }
    final attempts = failedV4Attempts.putIfAbsent(address, () => <int>[]);
    attempts.removeWhere((time) => now - time > 60000);
    if (attempts.length < 5) attempts.add(now);
  }

  Future<void> _handleV4(HttpRequest request, List<int> rawBytes, CompanionPairingAuthContext proof, Duration requestLifetime) async {
    final segments = request.uri.pathSegments;
    if (request.method == 'POST' && request.uri.path == '/v4/pair') {
      final body = _decodeJson(rawBytes);
      final deviceId = body['deviceId'];
      final label = body['label'];
      final platform = _platform(body['platform']);
      final clientNonce = body['clientNonce'];
      if (pending.length >= 8 ||
          body['sessionId'] != offer.sessionId ||
          body['version'] != 4 ||
          deviceId is! String ||
          deviceId != proof.deviceId ||
          !isValidPairedDeviceId(deviceId) ||
          deviceId == _identity.deviceId ||
          label is! String ||
          label.trim().isEmpty ||
          label.length > 128 ||
          platform == null ||
          !_validNonce(clientNonce)) {
        return await _v4Json(request.response, HttpStatus.badRequest, <String, Object?>{'error': 'invalid_request'}, proof);
      }
      final requestId = _randomToken(18);
      final serverNonce = _randomToken(16);
      final code = _pairingCode(offer.secret, '${offer.sessionId}|$clientNonce|$serverNonce|${_identity.deviceId}|$deviceId');
      final item = LanPairingRequest._(
        pairingCode: code,
        peer: PairedDevice(
          autoSync: false,
          createdAtUtc: DateTime.now().toUtc(),
          deviceId: deviceId,
          label: label,
          mode: PairedSyncMode.bidirectional,
          platform: platform,
          syncBookshelf: false,
          syncPlugins: false,
        ),
        sharedSecret: offer.secret,
        requestId: requestId,
        localIdentity: _identity,
        companionOnly: true,
      );
      pending[requestId] = item;
      requestsController.add(item);
      unawaited(Future<void>.delayed(requestLifetime).then((_) => item.reject()));
      unawaited(item.done.whenComplete(() => pending.remove(requestId)));
      return await _v4Json(request.response, HttpStatus.created, <String, Object?>{
        'requestId': requestId,
        'serverNonce': serverNonce,
        'pairingCode': code,
      }, proof);
    }
    if (segments.length == 4 && segments[0] == 'v4' && segments[1] == 'pair' && segments[3] == 'status' && request.method == 'GET') {
      final item = pending[segments[2]];
      if (item == null) {
        return await _v4Json(request.response, HttpStatus.notFound, <String, Object?>{'status': 'expired'}, proof);
      }
      final value = await item.decision.future.timeout(requestLifetime, onTimeout: () => <String, Object?>{'status': 'expired'});
      return await _v4Json(request.response, HttpStatus.ok, value, proof);
    }
    if (segments.length == 4 && segments[0] == 'v4' && segments[1] == 'pair' && request.method == 'POST') {
      final item = pending[segments[2]];
      if (segments[3] == 'commit') {
        if (item == null || !item.decision.isCompleted) {
          return await _v4Json(request.response, HttpStatus.conflict, <String, Object?>{'error': 'not_approved'}, proof);
        }
        await _v4Json(request.response, HttpStatus.ok, <String, Object?>{'status': 'complete'}, proof);
        if (!item.committed.isCompleted) item.committed.complete();
        return;
      }
      if (segments[3] == 'cancel') {
        if (item != null) await item.reject();
        return await _v4Json(request.response, HttpStatus.ok, <String, Object?>{'status': 'cancelled'}, proof);
      }
    }
    return await _v4Json(request.response, HttpStatus.notFound, <String, Object?>{'error': 'not_found'}, proof);
  }

  Future<void> _v4Json(HttpResponse response, int status, Map<String, Object?> value, CompanionPairingAuthContext proof) async {
    final bytes = utf8.encode(jsonEncode(value));
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.contentLength = bytes.length;
    CompanionPairingAuthentication.signResponseWithSecret(
      response,
      sharedSecret: offer.secret,
      request: proof,
      status: status,
      body: bytes,
    );
    response.add(bytes);
    await response.close();
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
  LanPairingClientConnection._(
    this.pairingCode,
    this.peer,
    this.sharedSecret,
    this._baseUri,
    this._requestId,
    this._localDeviceId,
    this.companionOnly,
  );
  final String pairingCode;
  final PairedDevice peer;
  final List<int> sharedSecret;
  final Uri _baseUri;
  final String _requestId;
  final String _localDeviceId;
  final bool companionOnly;
  final HttpClient _client = createLanSyncHttpClient();
  final Completer<void> _userConfirmation = Completer<void>();
  bool _committed = false;
  bool _closed = false;

  static Future<LanPairingOffer> fetchManualOffer({required String address, required int port, required String code}) async {
    if (!isLanSyncPrivateIpv4(address) || port < 1 || port > 65535) {
      throw const LanSyncTransportException('device_pairing_manual_address_invalid');
    }
    late final List<int> seed;
    try {
      seed = decodeCompanionManualSeed(code.trim().toUpperCase());
    } on FormatException {
      throw const LanSyncTransportException('device_pairing_manual_code_invalid');
    }
    final client = createLanSyncHttpClient();
    try {
      final base = Uri(scheme: 'http', host: address, port: port);
      final response = await client
          .getUrl(base.resolve('/v4/pairing-offer'))
          .then((request) => request.close())
          .timeout(const Duration(seconds: 5));
      final bytes = await _readResponseBytes(response).timeout(const Duration(seconds: 5));
      final decoded = _decodeJson(bytes);
      final sessionId = decoded['sessionId'];
      final deviceId = decoded['deviceId'];
      final label = decoded['label'];
      if (response.statusCode != HttpStatus.ok ||
          decoded['version'] != 4 ||
          sessionId is! String ||
          deviceId is! String ||
          !isValidPairedDeviceId(deviceId) ||
          label is! String ||
          label.trim().isEmpty ||
          label.length > 128) {
        throw const LanSyncTransportException('device_pairing_manual_offer_invalid');
      }
      final secret = await deriveCompanionManualSecret(seed, sessionId);
      return LanPairingOffer(
        addresses: <String>[address],
        deviceId: deviceId,
        label: label,
        port: port,
        secret: secret,
        sessionId: sessionId,
        companionOnly: true,
      );
    } on LanSyncTransportException {
      rethrow;
    } on Object catch (error) {
      throw LanSyncTransportException('device_pairing_manual_connect_failed', reason: error.runtimeType.toString());
    } finally {
      client.close(force: true);
    }
  }

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
      final companionOnly = offer.companionOnly;
      if (companionOnly) body['version'] = 4;
      final result = companionOnly
          ? await _requestJsonV4(client, base.resolve('/v4/pair'), 'POST', body, identity.deviceId, offer.secret)
          : await _requestJson(client, base.resolve('/v3/pair'), 'POST', body, identity.deviceId, offer.secret);
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
          autoSync: !companionOnly,
          createdAtUtc: DateTime.now().toUtc(),
          deviceId: offer.deviceId,
          label: offer.label,
          mode: PairedSyncMode.bidirectional,
          platform: PairedDevicePlatform.unknown,
          syncBookshelf: !companionOnly,
          syncPlugins: !companionOnly,
        ),
        offer.secret,
        base,
        requestId! as String,
        identity.deviceId,
        companionOnly,
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<PairedDevice> waitForApproval() async {
    final result = await _requestJsonForMode(_baseUri.resolve('/${companionOnly ? 'v4' : 'v3'}/pair/$_requestId/status'), 'GET', null);
    if (result['status'] == 'rejected') throw const LanSyncTransportException('lan_sync_pairing_rejected');
    final platform = _platform(result['platform']);
    final label = result['label'];
    if (result['status'] != 'approved' || result['deviceId'] != peer.deviceId || platform == null || label is! String) {
      throw const LanSyncTransportException('lan_sync_handshake_invalid');
    }
    if (companionOnly) {
      await _userConfirmation.future.timeout(
        lanSyncHandshakeTimeout,
        onTimeout: () {
          throw const LanSyncTransportException('device_pairing_user_confirmation_timeout');
        },
      );
      if (_closed) throw const LanSyncTransportException('device_pairing_cancelled');
    }
    return peer.copyWith(label: label, platform: platform);
  }

  void confirmCode() {
    if (companionOnly && !_userConfirmation.isCompleted && !_closed) _userConfirmation.complete();
  }

  Future<void> confirmCommitted() async {
    final result = await _requestJsonForMode(
      _baseUri.resolve('/${companionOnly ? 'v4' : 'v3'}/pair/$_requestId/commit'),
      'POST',
      const <String, Object?>{},
    );
    if (result['status'] != 'complete') throw const LanSyncTransportException('lan_sync_handshake_invalid');
    _committed = true;
    await close();
  }

  Future<Map<String, Object?>> _requestJsonForMode(Uri uri, String method, Map<String, Object?>? value) => companionOnly
      ? _requestJsonV4(_client, uri, method, value, _localDeviceId, sharedSecret)
      : _requestJson(_client, uri, method, value, _localDeviceId, sharedSecret);

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (companionOnly && !_userConfirmation.isCompleted) {
      _userConfirmation.complete();
    }
    if (companionOnly && !_committed) {
      try {
        await _requestJsonV4(
          _client,
          _baseUri.resolve('/v4/pair/$_requestId/cancel'),
          'POST',
          const <String, Object?>{},
          _localDeviceId,
          sharedSecret,
        ).timeout(const Duration(seconds: 1));
      } on Object {
        // The server expires unconfirmed requests if cancellation cannot arrive.
      }
    }
    _client.close(force: true);
  }
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
    contentChecksum: LanSyncHttpAuthentication.bodyHash(body),
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

Future<Map<String, Object?>> _requestJsonV4(
  HttpClient client,
  Uri uri,
  String method,
  Map<String, Object?>? value,
  String deviceId,
  List<int> secret,
) async {
  final body = value == null ? const <int>[] : utf8.encode(jsonEncode(value));
  if (body.length > 64 * 1024) throw const LanSyncTransportException('lan_sync_control_too_large');
  final request = await client.openUrl(method, uri).timeout(const Duration(seconds: 5));
  final auth = CompanionPairingAuthentication.signRequest(request, deviceId: deviceId, sharedSecret: secret, body: body);
  request.headers.contentType = ContentType.json;
  request.contentLength = body.length;
  request.add(body);
  final response = await request.close().timeout(const Duration(minutes: 2));
  final responseBytes = await _readResponseBytes(response);
  if (!CompanionPairingAuthentication.verifyResponse(response, sharedSecret: secret, request: auth, body: responseBytes)) {
    throw const LanSyncTransportException('lan_sync_pairing_response_auth_failed');
  }
  final decoded = _decodeJson(responseBytes);
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw LanSyncTransportException('lan_sync_http_failed', reason: 'status_${response.statusCode}');
  }
  return decoded;
}

Future<List<int>> _readResponseBytes(HttpClientResponse response) async {
  final bytes = <int>[];
  await for (final chunk in response) {
    if (bytes.length + chunk.length > 64 * 1024) {
      throw const LanSyncTransportException('lan_sync_control_too_large');
    }
    bytes.addAll(chunk);
  }
  return bytes;
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
