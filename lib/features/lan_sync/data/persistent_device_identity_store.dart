/// 应用本地持久化中的设备身份与逐设备共享密钥。
///
/// 职责：在 Windows、macOS 和 Android 上统一使用 AppPersistence 保存本机设备 ID、标签和
/// 256-bit 配对密钥，不接入系统钥匙串或凭据存储。
///
/// 注意：这些记录是普通应用数据，不具备额外的静态加密保护；不得写入日志、导出或同步。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';

import 'package:mg_read/core/persistence/persistence.dart';
import 'package:mg_read/features/lan_sync/application/device_identity_store.dart';
import 'package:mg_read/features/lan_sync/domain/paired_device_models.dart';

const String deviceSyncLocalIdentityRecordKind = 'device-sync-local-identity';
const String deviceSyncPeerSecretRecordKind = 'device-sync-peer-secret';
const ScopeKey deviceSyncLocalScope = ScopeKey(kind: 'app', id: 'device-sync-local');

final List<RecordDocumentCodec> deviceIdentityRecordDocumentCodecs = <RecordDocumentCodec>[
  RecordDocumentCodec(
    recordKind: deviceSyncLocalIdentityRecordKind,
    scopeKind: deviceSyncLocalScope.kind,
    currentVersion: 1,
    validators: <int, JsonValidator>{1: _validateIdentityDocument},
    inlinePreparationPolicy: const JsonInlinePreparationPolicy(
      maxDocuments: 1,
      maxTotalNodes: 8,
      maxDepth: 2,
      maxCollectionLength: 4,
      maxTotalTextCodeUnits: 512,
    ),
  ),
  RecordDocumentCodec(
    recordKind: deviceSyncPeerSecretRecordKind,
    scopeKind: deviceSyncLocalScope.kind,
    currentVersion: 1,
    validators: <int, JsonValidator>{1: _validatePeerSecretDocument},
    inlinePreparationPolicy: const JsonInlinePreparationPolicy(
      maxDocuments: 1,
      maxTotalNodes: 8,
      maxDepth: 2,
      maxCollectionLength: 4,
      maxTotalTextCodeUnits: 512,
    ),
  ),
];

final class PersistentDeviceIdentityStore implements DeviceIdentityStore {
  PersistentDeviceIdentityStore(this._records, {Future<String?> Function()? deviceLabelResolver})
    : _deviceLabelResolver = deviceLabelResolver ?? _readLocalDeviceLabel;

  static const _identityRecordId = 'device-sync-local:identity';

  final PersistenceRecordStore _records;
  final Future<String?> Function() _deviceLabelResolver;
  Future<LocalDeviceIdentity>? _identity;

  @override
  Future<void> deletePeerSecret(String peerDeviceId) async {
    if (!isValidPairedDeviceId(peerDeviceId)) return;
    final existing = await _records.read(id: _peerSecretRecordId(peerDeviceId), scope: deviceSyncLocalScope);
    if (existing != null) await _records.delete(previous: existing);
  }

  @override
  Future<LocalDeviceIdentity> loadOrCreateIdentity() => _identity ??= _loadOrCreateIdentity();

  Future<LocalDeviceIdentity> _loadOrCreateIdentity() async {
    final existing = await _records.read(id: _identityRecordId, scope: deviceSyncLocalScope);
    final resolvedLabel = await _resolveDeviceLabel();
    if (existing != null) {
      final deviceId = existing.document['deviceId']! as String;
      final storedLabel = existing.document['label']! as String;
      final label = resolvedLabel ?? storedLabel;
      if (label != storedLabel) {
        await _records.update(previous: existing, document: _identityDocument(deviceId, label));
      }
      return LocalDeviceIdentity(deviceId: deviceId, label: label);
    }
    final identity = LocalDeviceIdentity(
      deviceId: base64Url.encode(_randomBytes(18)).replaceAll('=', ''),
      label: resolvedLabel ?? _fallbackDeviceLabel,
    );
    await _records.create(
      RecordDraft(
        id: _identityRecordId,
        recordKind: deviceSyncLocalIdentityRecordKind,
        scope: deviceSyncLocalScope,
        identityKey: 'local',
        stateKey: 'active',
        document: _identityDocument(identity.deviceId, identity.label),
      ),
    );
    return identity;
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
    if (!isValidPairedDeviceId(peerDeviceId)) return null;
    final record = await _records.read(id: _peerSecretRecordId(peerDeviceId), scope: deviceSyncLocalScope);
    if (record == null) return null;
    final bytes = base64Url.decode(base64Url.normalize(record.document['secret']! as String));
    return List<int>.unmodifiable(bytes);
  }

  @override
  Future<void> writePeerSecret(String peerDeviceId, List<int> secret) async {
    if (!isValidPairedDeviceId(peerDeviceId) || secret.length != 32) {
      throw ArgumentError('Invalid paired-device secret.');
    }
    final id = _peerSecretRecordId(peerDeviceId);
    final document = <String, Object?>{'peerDeviceId': peerDeviceId, 'secret': base64Url.encode(secret).replaceAll('=', '')};
    final existing = await _records.read(id: id, scope: deviceSyncLocalScope);
    if (existing == null) {
      await _records.create(
        RecordDraft(
          id: id,
          recordKind: deviceSyncPeerSecretRecordKind,
          scope: deviceSyncLocalScope,
          identityKey: peerDeviceId,
          stateKey: 'active',
          document: document,
        ),
      );
    } else {
      await _records.update(previous: existing, document: document);
    }
  }
}

final class DeferredPersistentDeviceIdentityStore implements DeviceIdentityStore {
  DeferredPersistentDeviceIdentityStore(this._getPersistence);

  final Future<AppPersistence> Function() _getPersistence;
  Future<PersistentDeviceIdentityStore>? _delegate;

  Future<PersistentDeviceIdentityStore> _resolve() =>
      _delegate ??= _getPersistence().then((value) => PersistentDeviceIdentityStore(value.metadataRecords));

  @override
  Future<void> deletePeerSecret(String peerDeviceId) async => (await _resolve()).deletePeerSecret(peerDeviceId);

  @override
  Future<LocalDeviceIdentity> loadOrCreateIdentity() async => (await _resolve()).loadOrCreateIdentity();

  @override
  Future<List<int>?> readPeerSecret(String peerDeviceId) async => (await _resolve()).readPeerSecret(peerDeviceId);

  @override
  Future<void> writePeerSecret(String peerDeviceId, List<int> secret) async => (await _resolve()).writePeerSecret(peerDeviceId, secret);
}

String _peerSecretRecordId(String peerDeviceId) => 'device-sync-local:peer:$peerDeviceId';

JsonObject _identityDocument(String deviceId, String label) => <String, Object?>{'deviceId': deviceId, 'label': label};

const MethodChannel _deviceIdentityChannel = MethodChannel('mgread/device_identity');

Future<String?> _readLocalDeviceLabel() async {
  if (Platform.isAndroid) return _deviceIdentityChannel.invokeMethod<String>('getDeviceLabel');
  return Platform.localHostname;
}

String get _fallbackDeviceLabel => Platform.isWindows
    ? 'Windows 设备'
    : Platform.isMacOS
    ? 'Mac 设备'
    : Platform.isAndroid
    ? 'Android 设备'
    : '本机设备';

String? _normalizeDeviceLabel(String? value) {
  if (value == null) return null;
  final normalized = value.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (normalized.isEmpty || normalized.length > 128) return null;
  if (<String>{'localhost', 'localhost.localdomain', '127.0.0.1', '::1'}.contains(normalized.toLowerCase())) return null;
  return normalized;
}

List<int> _randomBytes(int length) {
  final random = Random.secure();
  return List<int>.generate(length, (_) => random.nextInt(256), growable: false);
}

void _validateIdentityDocument(JsonObject document) {
  const keys = <String>{'deviceId', 'label'};
  if (document.length != keys.length ||
      !document.keys.toSet().containsAll(keys) ||
      document['deviceId'] is! String ||
      !isValidPairedDeviceId(document['deviceId']! as String) ||
      document['label'] is! String ||
      _normalizeDeviceLabel(document['label']! as String) == null) {
    throw const FormatException('invalid_device_sync_local_identity');
  }
}

void _validatePeerSecretDocument(JsonObject document) {
  const keys = <String>{'peerDeviceId', 'secret'};
  final peerDeviceId = document['peerDeviceId'];
  final encoded = document['secret'];
  if (document.length != keys.length ||
      !document.keys.toSet().containsAll(keys) ||
      peerDeviceId is! String ||
      !isValidPairedDeviceId(peerDeviceId) ||
      encoded is! String ||
      !_isEncodedSecret(encoded)) {
    throw const FormatException('invalid_device_sync_peer_secret');
  }
}

bool _isEncodedSecret(String value) {
  try {
    return base64Url.decode(base64Url.normalize(value)).length == 32;
  } on FormatException {
    return false;
  }
}
