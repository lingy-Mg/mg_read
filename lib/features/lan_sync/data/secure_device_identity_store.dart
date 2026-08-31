/// Windows/Android 安全存储上的设备身份与配对密钥。
///
/// 普通 metadata 只保存设备策略；随机设备 ID 与逐设备 256-bit 密钥由平台安全存储持有。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:mg_read/features/lan_sync/application/device_identity_store.dart';
import 'package:mg_read/features/lan_sync/domain/paired_device_models.dart';

final class SecureDeviceIdentityStore implements DeviceIdentityStore {
  SecureDeviceIdentityStore({FlutterSecureStorage? storage, Future<String?> Function()? deviceLabelResolver})
    : _storage = storage ?? const FlutterSecureStorage(),
      _deviceLabelResolver = deviceLabelResolver ?? _readPlatformDeviceLabel;

  static const _deviceIdKey = 'mgread.device-sync.device-id.v1';
  static const _deviceLabelKey = 'mgread.device-sync.device-label.v1';
  static const _peerPrefix = 'mgread.device-sync.peer-secret.v1.';

  final FlutterSecureStorage _storage;
  final Future<String?> Function() _deviceLabelResolver;
  Future<LocalDeviceIdentity>? _identity;

  @override
  Future<void> deletePeerSecret(String peerDeviceId) => _storage.delete(key: '$_peerPrefix$peerDeviceId');

  @override
  Future<LocalDeviceIdentity> loadOrCreateIdentity() => _identity ??= _loadOrCreateIdentity();

  Future<LocalDeviceIdentity> _loadOrCreateIdentity() async {
    var deviceId = await _storage.read(key: _deviceIdKey);
    if (deviceId == null || !isValidPairedDeviceId(deviceId)) {
      deviceId = base64Url.encode(_randomBytes(18)).replaceAll('=', '');
      await _storage.write(key: _deviceIdKey, value: deviceId);
    }
    var label = await _storage.read(key: _deviceLabelKey);
    final resolvedLabel = await _resolveDeviceLabel();
    if (resolvedLabel != null && resolvedLabel != label) {
      label = resolvedLabel;
      await _storage.write(key: _deviceLabelKey, value: label);
    } else if (!_isUsableDeviceLabel(label)) {
      label = _normalizeDeviceLabel(Platform.localHostname) ?? (Platform.isWindows ? 'Windows 设备' : 'Android 设备');
      await _storage.write(key: _deviceLabelKey, value: label);
    }
    return LocalDeviceIdentity(deviceId: deviceId, label: label!);
  }

  Future<String?> _resolveDeviceLabel() async {
    try {
      return _normalizeDeviceLabel(await _deviceLabelResolver());
    } on Object {
      return null;
    }
  }

  @override
  Future<List<int>?> readPeerSecret(String peerDeviceId) async {
    final encoded = await _storage.read(key: '$_peerPrefix$peerDeviceId');
    if (encoded == null) return null;
    try {
      final bytes = base64Url.decode(base64Url.normalize(encoded));
      return bytes.length == 32 ? List<int>.unmodifiable(bytes) : null;
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> writePeerSecret(String peerDeviceId, List<int> secret) async {
    if (!isValidPairedDeviceId(peerDeviceId) || secret.length != 32) {
      throw ArgumentError('Invalid paired-device secret.');
    }
    await _storage.write(key: '$_peerPrefix$peerDeviceId', value: base64Url.encode(secret).replaceAll('=', ''));
  }
}

const MethodChannel _deviceIdentityChannel = MethodChannel('mgread/device_identity');

Future<String?> _readPlatformDeviceLabel() async {
  if (!Platform.isAndroid) return null;
  return _deviceIdentityChannel.invokeMethod<String>('getDeviceLabel');
}

bool _isUsableDeviceLabel(String? value) {
  return _normalizeDeviceLabel(value) != null;
}

String? _normalizeDeviceLabel(String? value) {
  if (value == null) return null;
  var normalized = value.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (normalized.isEmpty) return null;
  if (<String>{'localhost', 'localhost.localdomain', '127.0.0.1', '::1', 'android 设备', 'windows 设备'}.contains(normalized.toLowerCase())) {
    return null;
  }
  if (normalized.length > 128) normalized = normalized.substring(0, 128);
  return normalized;
}

List<int> _randomBytes(int length) {
  final random = Random.secure();
  return List<int>.generate(length, (_) => random.nextInt(256), growable: false);
}
