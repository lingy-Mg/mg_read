/// V4 companion-pairing authentication and manual-code key derivation.
///
/// Every authenticated request and response covers the exact method, path,
/// status where applicable, full SHA-256 body digest, device identity and fresh
/// request nonce. This is separate from legacy v3 CRC32 request authentication.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart' as cryptography show Hkdf, Hmac, SecretKey;

const String _deviceHeader = 'x-mgread-v4-device';
const String _nonceHeader = 'x-mgread-v4-nonce';
const String _requestHashHeader = 'x-mgread-v4-body-sha256';
const String _requestAuthHeader = 'x-mgread-v4-authorization';
const String _responseNonceHeader = 'x-mgread-v4-response-nonce';
const String _responseStatusHeader = 'x-mgread-v4-response-status';
const String _responseHashHeader = 'x-mgread-v4-response-sha256';
const String _responseAuthHeader = 'x-mgread-v4-response-auth';
const String _manualCodeAlphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
const String _manualPairingInfo = 'mgread-companion-manual-pairing-v1';

final class CompanionPairingAuthContext {
  const CompanionPairingAuthContext({
    required this.deviceId,
    required this.nonce,
    required this.method,
    required this.path,
    required this.bodyHash,
  });

  final String deviceId;
  final String nonce;
  final String method;
  final String path;
  final String bodyHash;
}

abstract final class CompanionPairingAuthentication {
  static CompanionPairingAuthContext signRequest(
    HttpClientRequest request, {
    required String deviceId,
    required List<int> sharedSecret,
    required List<int> body,
  }) {
    final nonce = _newNonce();
    final path = _path(request.uri);
    final bodyHash = _sha256Hex(body);
    final signature = _mac(sharedSecret, 'request\n4\n${request.method}\n$path\n$deviceId\n$nonce\n$bodyHash');
    request.headers
      ..set(_deviceHeader, deviceId)
      ..set(_nonceHeader, nonce)
      ..set(_requestHashHeader, bodyHash)
      ..set(_requestAuthHeader, signature);
    return CompanionPairingAuthContext(deviceId: deviceId, nonce: nonce, method: request.method, path: path, bodyHash: bodyHash);
  }

  static CompanionPairingAuthContext? verifyRequest(
    HttpRequest request, {
    required List<int> sharedSecret,
    required List<int> body,
    required Map<String, int> acceptedNonces,
    DateTime? now,
  }) {
    final deviceId = request.headers.value(_deviceHeader);
    final nonce = request.headers.value(_nonceHeader);
    final bodyHash = request.headers.value(_requestHashHeader);
    final signature = request.headers.value(_requestAuthHeader);
    if (deviceId == null ||
        deviceId.isEmpty ||
        deviceId.length > 128 ||
        !_validNonce(nonce) ||
        bodyHash == null ||
        !_constantTimeEquals(bodyHash, _sha256Hex(body)) ||
        signature == null) {
      return null;
    }
    final path = _path(request.uri);
    final expected = _mac(sharedSecret, 'request\n4\n${request.method}\n$path\n$deviceId\n$nonce\n$bodyHash');
    if (!_constantTimeEquals(signature, expected)) return null;
    final current = (now ?? DateTime.now().toUtc()).millisecondsSinceEpoch ~/ 1000;
    acceptedNonces.removeWhere((_, seenAt) => current - seenAt > 120);
    if (acceptedNonces.containsKey(nonce)) return null;
    if (acceptedNonces.length >= 1024) {
      final oldestNonce = acceptedNonces.entries.reduce((a, b) => a.value <= b.value ? a : b).key;
      acceptedNonces.remove(oldestNonce);
    }
    acceptedNonces[nonce!] = current;
    return CompanionPairingAuthContext(deviceId: deviceId, nonce: nonce, method: request.method, path: path, bodyHash: bodyHash);
  }

  static void signResponseWithSecret(
    HttpResponse response, {
    required List<int> sharedSecret,
    required CompanionPairingAuthContext request,
    required int status,
    required List<int> body,
  }) {
    final bodyHash = _sha256Hex(body);
    final signature = _mac(
      sharedSecret,
      'response\n4\n${request.method}\n${request.path}\n$status\n${request.deviceId}\n${request.nonce}\n$bodyHash',
    );
    response.headers
      ..set(_responseNonceHeader, request.nonce)
      ..set(_responseStatusHeader, status.toString())
      ..set(_responseHashHeader, bodyHash)
      ..set(_responseAuthHeader, signature);
  }

  static bool verifyResponse(
    HttpClientResponse response, {
    required List<int> sharedSecret,
    required CompanionPairingAuthContext request,
    required List<int> body,
  }) {
    final responseNonce = response.headers.value(_responseNonceHeader);
    final statusText = response.headers.value(_responseStatusHeader);
    final bodyHash = response.headers.value(_responseHashHeader);
    final signature = response.headers.value(_responseAuthHeader);
    final expectedHash = _sha256Hex(body);
    if (responseNonce == null ||
        !_constantTimeEquals(responseNonce, request.nonce) ||
        statusText != response.statusCode.toString() ||
        bodyHash == null ||
        !_constantTimeEquals(bodyHash, expectedHash) ||
        signature == null) {
      return false;
    }
    final expected = _mac(
      sharedSecret,
      'response\n4\n${request.method}\n${request.path}\n${response.statusCode}\n${request.deviceId}\n${request.nonce}\n$bodyHash',
    );
    return _constantTimeEquals(signature, expected);
  }

  static String _path(Uri uri) => uri.path + (uri.hasQuery ? '?${uri.query}' : '');

  static String _sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

  static String _mac(List<int> secret, String value) =>
      base64Url.encode(Hmac(sha256, secret).convert(utf8.encode(value)).bytes).replaceAll('=', '');

  static String _newNonce() {
    final random = Random.secure();
    return base64Url.encode(List<int>.generate(18, (_) => random.nextInt(256))).replaceAll('=', '');
  }

  static bool _validNonce(String? value) =>
      value != null && value.length >= 20 && value.length <= 64 && RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value);

  static bool _constantTimeEquals(String left, String right) {
    if (left.length != right.length) return false;
    var diff = 0;
    for (var i = 0; i < left.length; i++) {
      diff |= left.codeUnitAt(i) ^ right.codeUnitAt(i);
    }
    return diff == 0;
  }
}

String encodeCompanionManualSeed(List<int> seed) {
  if (seed.length != 16 || seed.any((byte) => byte < 0 || byte > 255)) {
    throw ArgumentError.value(seed, 'seed', 'A manual-pairing seed must contain 128 bits.');
  }
  var buffer = 0;
  var bits = 0;
  final output = StringBuffer();
  for (final byte in seed) {
    buffer = (buffer << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      bits -= 5;
      output.write(_manualCodeAlphabet[(buffer >> bits) & 31]);
    }
    buffer &= (1 << bits) - 1;
  }
  if (bits > 0) output.write(_manualCodeAlphabet[(buffer << (5 - bits)) & 31]);
  return output.toString();
}

List<int> decodeCompanionManualSeed(String code) {
  if (code.length != 26 || !RegExp(r'^[A-Z2-7]{26}$').hasMatch(code)) {
    throw const FormatException('Invalid manual-pairing code.');
  }
  var buffer = 0;
  var bits = 0;
  final output = <int>[];
  for (final character in code.codeUnits) {
    final value = character >= 65 ? character - 65 : character - 24;
    buffer = (buffer << 5) | value;
    bits += 5;
    if (bits >= 8) {
      bits -= 8;
      output.add((buffer >> bits) & 255);
      buffer &= (1 << bits) - 1;
    }
  }
  if (output.length != 16 || bits != 2 || (buffer & 3) != 0) {
    throw const FormatException('Non-canonical manual-pairing code.');
  }
  return output;
}

Future<List<int>> deriveCompanionManualSecret(List<int> seed, String sessionId) async {
  if (seed.length != 16 || sessionId.isEmpty || sessionId.length > 128) {
    throw ArgumentError('Invalid manual-pairing derivation input.');
  }
  final key = await cryptography.Hkdf(
    hmac: cryptography.Hmac.sha256(),
    outputLength: 32,
  ).deriveKey(secretKey: cryptography.SecretKey(seed), nonce: utf8.encode(sessionId), info: utf8.encode(_manualPairingInfo));
  return key.extractBytes();
}
