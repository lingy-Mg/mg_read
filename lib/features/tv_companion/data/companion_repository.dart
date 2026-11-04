/// Local companion policy, separate from paired-device trust. It stores no IP,
/// media URL or secret. Only DeviceIdentityStore owns existing per-peer keys.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crypto/crypto.dart' as companion_crypto;
import 'package:mg_read/core/persistence/persistence.dart';

final companionRepositoryProvider = Provider<CompanionRepository>((ref) => MemoryCompanionRepository());
const companionRecordKind = 'tv-companion-policy';
const companionScope = ScopeKey(kind: 'app', id: 'tv-companion-local');
final companionPolicyCodec = RecordDocumentCodec(
  recordKind: companionRecordKind,
  scopeKind: 'app',
  currentVersion: 1,
  validators: {
    1: (json) {
      if (json.keys.any((key) => !{'receiverEnabled', 'control', 'browseLibrary', 'label', 'selected', 'trustBinding'}.contains(key)) ||
          json.values.any((value) => value is! bool && value is! String) ||
          json.values.whereType<String>().any((value) => value.length > 128)) {
        throw const FormatException('companion_policy');
      }
    },
  },
);

final class CompanionPolicy {
  const CompanionPolicy({this.control = false, this.browseLibrary = false, this.label, this.trustBinding});
  final bool control, browseLibrary;
  final String? label;
  final String? trustBinding;
  CompanionPolicy boundTo(List<int> secret) => CompanionPolicy(
    control: control,
    browseLibrary: browseLibrary,
    label: label,
    trustBinding: companion_crypto.sha256.convert(secret).toString(),
  );
  bool allowsSecret(List<int> secret) => control && trustBinding == companion_crypto.sha256.convert(secret).toString();
  Map<String, Object?> toJson() => {
    'control': control,
    'browseLibrary': browseLibrary,
    if (label != null) 'label': label,
    if (trustBinding != null) 'trustBinding': trustBinding,
  };
  factory CompanionPolicy.fromJson(Map<String, Object?> json) => CompanionPolicy(
    control: json['control'] == true,
    browseLibrary: json['browseLibrary'] == true,
    label: json['label'] as String?,
    trustBinding: json['trustBinding'] as String?,
  );
}

abstract interface class CompanionRepository {
  Future<bool> receiverEnabled();
  Future<void> setReceiverEnabled(bool value);
  Future<CompanionPolicy> policy(String deviceId);
  Future<void> setPolicy(String deviceId, CompanionPolicy policy);
  Future<String?> selectedDevice();
  Future<void> setSelectedDevice(String? deviceId);
}

final class MemoryCompanionRepository implements CompanionRepository {
  bool enabled = false;
  String? selected;
  final policies = <String, CompanionPolicy>{};
  @override
  Future<bool> receiverEnabled() async => enabled;
  @override
  Future<void> setReceiverEnabled(bool value) async {
    enabled = value;
  }

  @override
  Future<CompanionPolicy> policy(String id) async => policies[id] ?? const CompanionPolicy();
  @override
  Future<void> setPolicy(String id, CompanionPolicy value) async {
    policies[id] = value;
  }

  @override
  Future<String?> selectedDevice() async => selected;
  @override
  Future<void> setSelectedDevice(String? id) async {
    selected = id;
  }
}

final class PersistentCompanionRepository implements CompanionRepository {
  PersistentCompanionRepository(this.getRecords);
  final Future<PersistenceRecordStore> Function() getRecords;
  Future<void> _tail = Future.value();
  Future<Map<String, Object?>> _read(String id) async =>
      (await (await getRecords()).read(id: 'companion:$id', scope: companionScope))?.document ?? {};
  Future<void> _write(String id, Map<String, Object?> json) {
    final result = _tail.then((_) async {
      final records = await getRecords();
      final old = await records.read(id: 'companion:$id', scope: companionScope);
      if (old == null) {
        await records.create(
          RecordDraft(id: 'companion:$id', recordKind: companionRecordKind, scope: companionScope, identityKey: id, document: json),
        );
      } else {
        await records.update(previous: old, document: json);
      }
    });
    _tail = result.catchError((Object _) {});
    return result;
  }

  @override
  Future<bool> receiverEnabled() async => (await _read('receiver'))['receiverEnabled'] == true;
  @override
  Future<void> setReceiverEnabled(bool value) => _write('receiver', {'receiverEnabled': value});
  @override
  Future<CompanionPolicy> policy(String id) async => CompanionPolicy.fromJson(await _read('peer:$id'));
  @override
  Future<void> setPolicy(String id, CompanionPolicy value) => _write('peer:$id', value.toJson());
  @override
  Future<String?> selectedDevice() async => (await _read('selected'))['selected'] as String?;
  @override
  Future<void> setSelectedDevice(String? id) => _write('selected', {'selected': ?id});
}
