/// AppPersistence 上的配对设备强类型仓储。
///
/// 职责：保存稳定设备身份、同步策略和非敏感结果摘要。
/// 注意：共享密钥、配对码、IP 和书名不得写入本记录。
library;

import 'package:mg_read/core/persistence/persistence.dart';
import 'package:mg_read/features/lan_sync/application/paired_device_repository.dart';
import 'package:mg_read/features/lan_sync/domain/paired_device_models.dart';

const String pairedDeviceRecordKind = 'device-sync-paired-device';
const ScopeKey pairedDeviceScope = ScopeKey(kind: 'app', id: 'primary');

final pairedDeviceRecordDocumentCodec = RecordDocumentCodec(
  recordKind: pairedDeviceRecordKind,
  scopeKind: pairedDeviceScope.kind,
  currentVersion: 1,
  validators: <int, JsonValidator>{1: _validatePairedDeviceDocument},
  inlinePreparationPolicy: const JsonInlinePreparationPolicy(
    maxDocuments: 8,
    maxTotalNodes: 256,
    maxDepth: 4,
    maxCollectionLength: 16,
    maxTotalTextCodeUnits: 4096,
  ),
);

final class PersistentPairedDeviceRepository implements PairedDeviceRepository {
  const PersistentPairedDeviceRepository(this._records);

  final PersistenceRecordStore _records;

  @override
  Future<List<PairedDevice>> list() async {
    final page = await _records.list(const RecordQuery(recordKind: pairedDeviceRecordKind, scope: pairedDeviceScope, limit: 32));
    final devices = page.records.map(_fromRecord).toList(growable: false)..sort((left, right) => left.label.compareTo(right.label));
    return List<PairedDevice>.unmodifiable(devices);
  }

  @override
  Future<PairedDevice?> read(String deviceId) async {
    if (!isValidPairedDeviceId(deviceId)) return null;
    final page = await _records.list(
      RecordQuery(recordKind: pairedDeviceRecordKind, scope: pairedDeviceScope, identityKey: deviceId, limit: 1),
    );
    return page.records.isEmpty ? null : _fromRecord(page.records.single);
  }

  @override
  Future<void> remove(String deviceId) async {
    final current = await read(deviceId);
    if (current == null) return;
    final record = await _records.read(id: _recordId(deviceId), scope: pairedDeviceScope);
    if (record != null) await _records.delete(previous: record);
  }

  @override
  Future<void> upsert(PairedDevice device) async {
    if (!isValidPairedDeviceId(device.deviceId)) {
      throw ArgumentError.value(device.deviceId, 'device.deviceId');
    }
    final document = _toDocument(device);
    final existing = await _records.read(id: _recordId(device.deviceId), scope: pairedDeviceScope);
    if (existing == null) {
      await _records.create(
        RecordDraft(
          id: _recordId(device.deviceId),
          recordKind: pairedDeviceRecordKind,
          scope: pairedDeviceScope,
          identityKey: device.deviceId,
          stateKey: 'active',
          orderKey: device.label.toLowerCase(),
          document: document,
        ),
      );
      return;
    }
    await _records.update(previous: existing, document: document);
  }
}

final class DeferredPairedDeviceRepository implements PairedDeviceRepository {
  DeferredPairedDeviceRepository(this._getPersistence);

  final Future<AppPersistence> Function() _getPersistence;
  Future<PersistentPairedDeviceRepository>? _delegate;

  Future<PersistentPairedDeviceRepository> _resolve() =>
      _delegate ??= _getPersistence().then((value) => PersistentPairedDeviceRepository(value.metadataRecords));

  @override
  Future<List<PairedDevice>> list() async => (await _resolve()).list();

  @override
  Future<PairedDevice?> read(String deviceId) async => (await _resolve()).read(deviceId);

  @override
  Future<void> remove(String deviceId) async => (await _resolve()).remove(deviceId);

  @override
  Future<void> upsert(PairedDevice device) async => (await _resolve()).upsert(device);
}

String _recordId(String deviceId) => 'paired-device:$deviceId';

JsonObject _toDocument(PairedDevice device) => <String, Object?>{
  'autoSync': device.autoSync,
  'createdAtUtc': device.createdAtUtc.toUtc().toIso8601String(),
  'deviceId': device.deviceId,
  'label': device.label,
  'mode': device.mode.name,
  'platform': device.platform.name,
  'syncBookshelf': device.syncBookshelf,
  'syncPlugins': device.syncPlugins,
  if (device.lastSeenAtUtc != null) 'lastSeenAtUtc': device.lastSeenAtUtc!.toUtc().toIso8601String(),
  if (device.lastSyncAtUtc != null) 'lastSyncAtUtc': device.lastSyncAtUtc!.toUtc().toIso8601String(),
  if (device.lastSyncResult != null) 'lastSyncResult': device.lastSyncResult!.name,
};

PairedDevice _fromRecord(RecordEnvelope record) {
  final document = record.document;
  return PairedDevice(
    autoSync: document['autoSync']! as bool,
    createdAtUtc: DateTime.parse(document['createdAtUtc']! as String).toUtc(),
    deviceId: document['deviceId']! as String,
    label: document['label']! as String,
    mode: PairedSyncMode.values.byName(document['mode']! as String),
    platform: PairedDevicePlatform.values.byName(document['platform']! as String),
    syncBookshelf: document['syncBookshelf']! as bool,
    syncPlugins: document['syncPlugins']! as bool,
    lastSeenAtUtc: _date(document['lastSeenAtUtc']),
    lastSyncAtUtc: _date(document['lastSyncAtUtc']),
    lastSyncResult: document['lastSyncResult'] == null ? null : PairedSyncResultState.values.byName(document['lastSyncResult']! as String),
  );
}

DateTime? _date(Object? value) => value is String ? DateTime.parse(value).toUtc() : null;

void _validatePairedDeviceDocument(JsonObject document) {
  const requiredKeys = <String>{'autoSync', 'createdAtUtc', 'deviceId', 'label', 'mode', 'platform', 'syncBookshelf', 'syncPlugins'};
  const optionalKeys = <String>{'lastSeenAtUtc', 'lastSyncAtUtc', 'lastSyncResult'};
  if (!document.keys.toSet().containsAll(requiredKeys) ||
      document.keys.any((key) => !requiredKeys.contains(key) && !optionalKeys.contains(key)) ||
      document['autoSync'] is! bool ||
      document['syncBookshelf'] is! bool ||
      document['syncPlugins'] is! bool ||
      document['deviceId'] is! String ||
      !isValidPairedDeviceId(document['deviceId']! as String) ||
      document['label'] is! String ||
      (document['label']! as String).trim().isEmpty ||
      (document['label']! as String).length > 128 ||
      !_enumName(document['mode'], PairedSyncMode.values) ||
      !_enumName(document['platform'], PairedDevicePlatform.values) ||
      !_optionalEnumName(document['lastSyncResult'], PairedSyncResultState.values) ||
      !_utcDate(document['createdAtUtc']) ||
      !_optionalUtcDate(document['lastSeenAtUtc']) ||
      !_optionalUtcDate(document['lastSyncAtUtc'])) {
    throw const FormatException('invalid_paired_device');
  }
}

bool _enumName<T extends Enum>(Object? value, List<T> values) => value is String && values.any((item) => item.name == value);

bool _optionalEnumName<T extends Enum>(Object? value, List<T> values) => value == null || _enumName(value, values);

bool _optionalUtcDate(Object? value) => value == null || _utcDate(value);

bool _utcDate(Object? value) => value is String && DateTime.tryParse(value)?.isUtc == true;
