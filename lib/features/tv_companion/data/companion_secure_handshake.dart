// Wire contract for companion secure-channel authentication (v1).
// Client hello: {type, version, clientId, serverId, session, clientNonce}.
// Server challenge: {type, version, session, serverNonce}.
// Client/server finished proofs HMAC the canonical transcript containing both
// identities, session and fresh 32-byte nonces; server proof also binds client
// proof. HKDF-SHA256 over the PSK and transcript hash yields independent AES-256
// keys and 32-bit nonce prefixes for each direction. No business JSON is sent
// until both proofs have been checked.
import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

const int _handshakeVersion = 1;
const int _maxHandshakeBytes = 4096;
const _protocol = 'mgread-companion-ws-v1';
final _random = Random.secure();
final _hmac = Hmac.sha256();
final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 72);

final class CompanionHandshakeKeys {
  const CompanionHandshakeKeys({
    required this.sessionId,
    required this.clientToServerKey,
    required this.serverToClientKey,
    required this.clientNoncePrefix,
    required this.serverNoncePrefix,
  });

  final String sessionId;
  final SecretKey clientToServerKey;
  final SecretKey serverToClientKey;
  final List<int> clientNoncePrefix;
  final List<int> serverNoncePrefix;
}

final class CompanionServerHandshakeResult {
  const CompanionServerHandshakeResult({required this.peerId, required this.keys});
  final String peerId;
  final CompanionHandshakeKeys keys;
}

final class CompanionHandshakeClientResult {
  const CompanionHandshakeClientResult(this.keys);
  final CompanionHandshakeKeys keys;
}

abstract final class CompanionSecureHandshake {
  static Future<CompanionHandshakeClientResult> client({
    required String localId,
    required String remoteId,
    required List<int> secret,
    required void Function(Object message) send,
    required Future<Object?> Function() receive,
    required Duration timeout,
  }) async {
    final sessionBytes = _randomBytes(16);
    final clientNonce = _randomBytes(32);
    final session = _encode(sessionBytes);
    final clientNonceText = _encode(clientNonce);
    send(<String, Object?>{
      'type': 'hello',
      'version': _handshakeVersion,
      'clientId': localId,
      'serverId': remoteId,
      'session': session,
      'clientNonce': clientNonceText,
    });
    final challenge = await _readObject(receive, timeout);
    if (challenge['type'] != 'challenge' || challenge['version'] != _handshakeVersion || challenge['session'] != session) {
      throw const _HandshakeFailure();
    }
    final serverNonce = _decode(challenge['serverNonce'], 32);
    final transcript = _transcript(localId, remoteId, session, clientNonceText, _encode(serverNonce));
    final clientProof = await _proof(secret, 'client-finished', transcript);
    send(<String, Object?>{'type': 'client-finished', 'proof': _encode(clientProof)});
    final serverFinished = await _readObject(receive, timeout);
    if (serverFinished['type'] != 'server-finished') throw const _HandshakeFailure();
    final expectedServerProof = await _proof(secret, 'server-finished', <int>[...transcript, ...clientProof]);
    final actualServerProof = _decode(serverFinished['proof'], 32);
    if (!_constantTimeEqual(expectedServerProof, actualServerProof)) throw const _HandshakeFailure();
    return CompanionHandshakeClientResult(await _derive(secret, transcript, session));
  }

  static Future<CompanionServerHandshakeResult> server({
    required String localId,
    required Future<List<int>?> Function(String peerId) resolvePeerSecret,
    required void Function(Object message) send,
    required Future<Object?> Function() receive,
    required Duration timeout,
  }) async {
    final hello = await _readObject(receive, timeout);
    if (hello['type'] != 'hello' || hello['version'] != _handshakeVersion || hello['serverId'] != localId) {
      throw const _HandshakeFailure();
    }
    final peerId = hello['clientId'];
    final session = hello['session'];
    if (peerId is! String || peerId.isEmpty || peerId.length > 128 || peerId == localId || session is! String) {
      throw const _HandshakeFailure();
    }
    final clientNonceText = hello['clientNonce'];
    _decode(clientNonceText, 32);
    if (_decode(session, 16).length != 16) throw const _HandshakeFailure();
    final secret = await resolvePeerSecret(peerId).timeout(timeout);
    if (secret == null || secret.length < 32 || secret.length > 128 || secret.any((b) => b < 0 || b > 255)) {
      throw const _HandshakeFailure();
    }
    final serverNonce = _randomBytes(32);
    final serverNonceText = _encode(serverNonce);
    send(<String, Object?>{'type': 'challenge', 'version': _handshakeVersion, 'session': session, 'serverNonce': serverNonceText});
    final transcript = _transcript(peerId, localId, session, clientNonceText as String, serverNonceText);
    final clientFinished = await _readObject(receive, timeout);
    if (clientFinished['type'] != 'client-finished') throw const _HandshakeFailure();
    final clientProof = _decode(clientFinished['proof'], 32);
    final expectedClientProof = await _proof(secret, 'client-finished', transcript);
    if (!_constantTimeEqual(expectedClientProof, clientProof)) throw const _HandshakeFailure();
    final serverProof = await _proof(secret, 'server-finished', <int>[...transcript, ...clientProof]);
    final keys = await _derive(secret, transcript, session);
    send(<String, Object?>{'type': 'server-finished', 'proof': _encode(serverProof)});
    return CompanionServerHandshakeResult(peerId: peerId, keys: keys);
  }

  static Future<Map<String, Object?>> _readObject(Future<Object?> Function() receive, Duration timeout) async {
    final value = await receive().timeout(timeout);
    if (value is! String || utf8.encode(value).length > _maxHandshakeBytes) throw const _HandshakeFailure();
    final decoded = jsonDecode(value);
    if (decoded is! Map<String, dynamic>) throw const _HandshakeFailure();
    return Map<String, Object?>.from(decoded);
  }

  static List<int> encodeMessage(Object value) {
    final bytes = utf8.encode(jsonEncode(value));
    if (bytes.length > _maxHandshakeBytes) throw const _HandshakeFailure();
    return bytes;
  }

  static Future<List<int>> _proof(List<int> secret, String label, List<int> transcript) async =>
      (await _hmac.calculateMac(<int>[...utf8.encode('$_protocol\u0000$label\u0000'), ...transcript], secretKey: SecretKey(secret))).bytes;

  static Future<CompanionHandshakeKeys> _derive(List<int> secret, List<int> transcript, String session) async {
    final salt = (await Sha256().hash(transcript)).bytes;
    final material = await _hkdf.deriveKey(
      secretKey: SecretKey(secret),
      nonce: salt,
      info: utf8.encode('$_protocol\u0000keys\u0000$session'),
    );
    final bytes = await material.extractBytes();
    return CompanionHandshakeKeys(
      sessionId: session,
      clientToServerKey: SecretKey(bytes.sublist(0, 32)),
      clientNoncePrefix: List<int>.unmodifiable(bytes.sublist(32, 36)),
      serverToClientKey: SecretKey(bytes.sublist(36, 68)),
      serverNoncePrefix: List<int>.unmodifiable(bytes.sublist(68, 72)),
    );
  }

  static List<int> _transcript(String clientId, String serverId, String session, String clientNonce, String serverNonce) =>
      utf8.encode(jsonEncode(<String>[_protocol, 'client', clientId, 'server', serverId, session, clientNonce, serverNonce]));

  static List<int> _randomBytes(int length) => List<int>.generate(length, (_) => _random.nextInt(256));
  static String _encode(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');
  static List<int> _decode(Object? value, int length) {
    if (value is! String || value.length > 128) throw const _HandshakeFailure();
    try {
      final decoded = base64Url.decode(base64Url.normalize(value));
      if (decoded.length != length) throw const _HandshakeFailure();
      return decoded;
    } catch (_) {
      throw const _HandshakeFailure();
    }
  }

  static bool _constantTimeEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var difference = 0;
    for (var i = 0; i < a.length; i++) {
      difference |= a[i] ^ b[i];
    }
    return difference == 0;
  }
}

final class _HandshakeFailure implements Exception {
  const _HandshakeFailure();
}
