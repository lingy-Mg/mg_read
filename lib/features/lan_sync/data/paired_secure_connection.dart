/// 已配对设备会话的 AES-256-GCM 帧封装。
///
/// 职责：从逐设备共享密钥和本次握手随机数派生临时会话密钥，并为每个控制/二进制帧提供认证加密。
/// 注意：方向和单调计数器共同形成唯一 nonce；任何重放、乱序或篡改都稳定失败。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'package:mg_read/features/lan_sync/data/lan_sync_transport.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_models.dart';

final class PairedSecureConnection {
  PairedSecureConnection._(this._raw, this._secretKey, this._sendDirection, this._receiveDirection);

  static const int _macBytes = 16;
  static const int _controlKind = 0;
  static const int _binaryKind = 1;
  static final AesGcm _cipher = AesGcm.with256bits();

  final LanSyncFramedConnection _raw;
  final SecretKey _secretKey;
  final int _sendDirection;
  final int _receiveDirection;
  int _sendCounter = 0;
  int _receiveCounter = 0;

  static Future<PairedSecureConnection> client({
    required LanSyncFramedConnection raw,
    required List<int> sharedSecret,
    required String clientNonce,
    required String serverNonce,
  }) async => PairedSecureConnection._(raw, await _deriveKey(sharedSecret, clientNonce, serverNonce), 1, 2);

  static Future<PairedSecureConnection> server({
    required LanSyncFramedConnection raw,
    required List<int> sharedSecret,
    required String clientNonce,
    required String serverNonce,
  }) async => PairedSecureConnection._(raw, await _deriveKey(sharedSecret, clientNonce, serverNonce), 2, 1);

  Future<void> sendControl(Map<String, Object?> value, {int maxBytes = lanSyncMaxControlFrameBytes}) async {
    final bytes = utf8.encode(jsonEncode(value));
    if (bytes.length > maxBytes) throw const LanSyncTransportException('lan_sync_control_too_large');
    await _send(_controlKind, bytes, maxBytes: maxBytes);
  }

  Future<void> sendBinary(Uint8List bytes, {int maxBytes = lanSyncMaxBinaryChunkBytes}) async {
    if (bytes.isEmpty || bytes.length > maxBytes) {
      throw const LanSyncTransportException('lan_sync_binary_too_large');
    }
    await _send(_binaryKind, bytes, maxBytes: maxBytes);
  }

  Future<void> _send(int kind, List<int> bytes, {required int maxBytes}) async {
    final counter = _sendCounter++;
    final nonce = _nonce(_sendDirection, counter);
    final clear = Uint8List(bytes.length + 1)
      ..[0] = kind
      ..setRange(1, bytes.length + 1, bytes);
    final box = await _cipher.encrypt(clear, secretKey: _secretKey, nonce: nonce, aad: _aad(_sendDirection, counter));
    final encrypted = Uint8List(box.cipherText.length + _macBytes)
      ..setRange(0, box.cipherText.length, box.cipherText)
      ..setRange(box.cipherText.length, box.cipherText.length + _macBytes, box.mac.bytes);
    await _raw.sendBinary(encrypted, maxBytes: maxBytes + _macBytes + 1);
  }

  Future<Map<String, Object?>> readControl({int maxBytes = lanSyncMaxControlFrameBytes}) async {
    final frame = await readFrame(controlMaxBytes: maxBytes);
    if (frame is! LanSyncControlFrame) throw const LanSyncTransportException('lan_sync_control_expected');
    return frame.value;
  }

  Future<LanSyncFrame> readFrame({
    int binaryMaxBytes = lanSyncMaxBinaryChunkBytes,
    int controlMaxBytes = lanSyncMaxControlFrameBytes,
  }) async {
    final maximum = binaryMaxBytes > controlMaxBytes ? binaryMaxBytes : controlMaxBytes;
    final encrypted = await _raw.readFrame(binaryMaxBytes: maximum + _macBytes + 1);
    if (encrypted is! LanSyncBinaryFrame || encrypted.bytes.length <= _macBytes) {
      throw const LanSyncTransportException('lan_sync_secure_frame_invalid');
    }
    final counter = _receiveCounter++;
    final nonce = _nonce(_receiveDirection, counter);
    final cipherLength = encrypted.bytes.length - _macBytes;
    final box = SecretBox(
      Uint8List.sublistView(encrypted.bytes, 0, cipherLength),
      nonce: nonce,
      mac: Mac(Uint8List.sublistView(encrypted.bytes, cipherLength)),
    );
    final List<int> clear;
    try {
      clear = await _cipher.decrypt(box, secretKey: _secretKey, aad: _aad(_receiveDirection, counter));
    } on SecretBoxAuthenticationError {
      throw const LanSyncTransportException('lan_sync_secure_frame_invalid');
    }
    if (clear.length < 2) throw const LanSyncTransportException('lan_sync_secure_frame_invalid');
    final kind = clear[0];
    final body = Uint8List.fromList(clear.sublist(1));
    if (kind == _binaryKind) {
      if (body.length > binaryMaxBytes) throw const LanSyncTransportException('lan_sync_binary_too_large');
      return LanSyncBinaryFrame(body);
    }
    if (kind != _controlKind || body.length > controlMaxBytes) {
      throw const LanSyncTransportException('lan_sync_control_invalid');
    }
    try {
      final decoded = jsonDecode(utf8.decode(body));
      if (decoded is! Map) throw const FormatException();
      return LanSyncControlFrame(
        decoded.map<String, Object?>((key, value) {
          if (key is! String) throw const FormatException();
          return MapEntry(key, value);
        }),
      );
    } on Object {
      throw const LanSyncTransportException('lan_sync_control_invalid');
    }
  }

  Future<void> close() => _raw.close();
}

Future<SecretKeyData> _deriveKey(List<int> secret, String clientNonce, String serverNonce) {
  if (secret.length != 32) throw const LanSyncTransportException('lan_sync_pairing_secret_invalid');
  return Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
    secretKey: SecretKey(secret),
    nonce: utf8.encode('$clientNonce\u001f$serverNonce'),
    info: utf8.encode('mgread-paired-session-v1'),
  );
}

Uint8List _nonce(int direction, int counter) {
  final data = ByteData(12)
    ..setUint32(0, direction, Endian.big)
    ..setUint64(4, counter, Endian.big);
  return data.buffer.asUint8List();
}

List<int> _aad(int direction, int counter) => utf8.encode('mgread-frame-v1|$direction|$counter');
