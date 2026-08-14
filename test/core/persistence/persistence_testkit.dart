import 'dart:io';

import 'package:mg_read/core/persistence/persistence.dart';

final class PersistenceTestkit {
  PersistenceTestkit._(this.root, this.store);

  final Directory root;
  final PersistenceRecordStore store;

  static Future<PersistenceTestkit> open({
    RecordDocumentRegistry? registry,
  }) async {
    final root = await Directory.systemTemp.createTemp('mg-read-persistence-');
    final store = await PersistenceRecordStore.open(
      dataRoot: root,
      registry: registry ?? defaultRegistry,
    );
    return PersistenceTestkit._(root, store);
  }

  Future<void> dispose() async {
    await store.close();
    await root.delete(recursive: true);
  }
}

final ScopeKey localScope = ScopeKey(kind: 'local', id: 'primary');

RecordDocumentRegistry get defaultRegistry => RecordDocumentRegistry([
  RecordDocumentCodec(
    recordKind: 'app_setting',
    scopeKind: 'local',
    currentVersion: 2,
    validators: {1: _validateV1, 2: _validateV2},
    upgraders: {1: _upgradeV1},
  ),
]);

RecordDraft settingDraft(
  String id, {
  String value = 'initial',
  Object? extra,
}) => RecordDraft(
  id: id,
  recordKind: 'app_setting',
  scope: localScope,
  document: {'value': value, 'futureExtension': ?extra},
  stateKey: 'active',
);

void _validateV1(JsonObject value) {
  if (value['value'] is! String) {
    throw const PersistenceValidationError('value must be a string');
  }
}

void _validateV2(JsonObject value) {
  _validateV1(value);
  if (value.containsKey('enabled') &&
      value['enabled'] is! bool &&
      value['enabled'] != null) {
    throw const PersistenceValidationError('enabled must be bool or null');
  }
}

JsonObject _upgradeV1(JsonObject old) => {
  ...old,
  if (!old.containsKey('enabled')) 'enabled': true,
};
