import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/persistence/persistence.dart';
import 'package:mg_read/core/settings/settings.dart';

import 'settings_testkit.dart';

const testScope = ScopeKey(kind: 'app', id: 'settings-test');

void main() {
  late Directory root;
  final closeables = <Future<void> Function()>[];

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mg-read-settings-');
  });

  tearDown(() async {
    for (final close in closeables.reversed) {
      await close();
    }
    closeables.clear();
    await root.delete(recursive: true);
  });

  test('real SQLite batch-loads once, persists, and reopens', () async {
    final firstRecords = await _openRecords(root, settingsTestRegistry);
    final first = _manager(firstRecords, settingsTestRegistry);
    closeables.add(first.close);
    closeables.add(firstRecords.close);
    await first.initialize();

    expect(firstRecords.batchReadCountForTest, 1);
    await first.transaction((editor) {
      editor.set(themeKey, 'dark');
      editor.set(pageStepKey, 12);
    });
    expect((await first.flush()).persisted, isTrue);
    expect(firstRecords.lastCodecExecutionIsolateIdForTest, Isolate.current.hashCode);
    await first.close();
    await firstRecords.close();
    closeables.clear();

    final reopenedRecords = await _openRecords(root, settingsTestRegistry);
    final reopened = _manager(reopenedRecords, settingsTestRegistry);
    closeables.add(reopenedRecords.close);
    closeables.add(reopened.close);
    await reopened.initialize();

    expect(reopenedRecords.batchReadCountForTest, 1);
    expect(reopened.get(themeKey), 'dark');
    expect(reopened.get(pageStepKey), 12);
  });

  test('real batch isolates future and corrupt document groups', () async {
    final records = await _openRecords(root, settingsTestRegistry);
    closeables.add(records.close);
    await records.create(
      RecordDraft(id: appearanceDocument.id, recordKind: appearanceDocument.kind, scope: testScope, document: {themeKey.id: 'dark'}),
    );
    await records.create(
      RecordDraft(id: behaviorDocument.id, recordKind: behaviorDocument.kind, scope: testScope, document: {pageStepKey.id: 5}),
    );
    await records.debugReplacePayloadForTest(
      id: appearanceDocument.id,
      scope: testScope,
      version: 2,
      payloadJson: '{"${themeKey.id}":"dark"}',
    );
    await records.debugReplacePayloadForTest(id: behaviorDocument.id, scope: testScope, version: 1, payloadJson: '{bad');

    final manager = _manager(records, settingsTestRegistry);
    closeables.add(manager.close);
    await manager.initialize();

    expect(records.batchReadCountForTest, 1);
    expect(manager.state, SettingsState.degraded);
    expect(manager.get(themeKey), 'system');
    expect(manager.get(pageStepKey), 1);
    expect(manager.status.degradedDocumentKinds, {appearanceDocument.kind, behaviorDocument.kind});
  });

  test('real version upgrade preserves unknown fields and explicit null', () async {
    final registry = _upgradingRegistry();
    final records = await _openRecords(root, registry);
    closeables.add(records.close);
    await records.create(
      RecordDraft(
        id: appearanceDocument.id,
        recordKind: appearanceDocument.kind,
        scope: testScope,
        document: {themeKey.id: 'system', nullableLabelKey.id: null},
      ),
    );
    await records.debugReplacePayloadForTest(
      id: appearanceDocument.id,
      scope: testScope,
      version: 1,
      payloadJson: '{"${themeKey.id}":"light","unknown":{"nullable":null},"padding":"${'x' * (5 * 1024)}"}',
    );
    final manager = _manager(records, registry);
    closeables.add(manager.close);

    await manager.initialize();
    expect(manager.get(themeKey), 'light');
    expect(manager.get(nullableLabelKey), isNull);
    await manager.set(themeKey, 'dark');
    await manager.flush();

    final saved = await records.read(id: appearanceDocument.id, scope: testScope);
    expect(saved!.formatVersion, 2);
    expect(saved.document['unknown'], {'nullable': null});
    expect(saved.document.containsKey(nullableLabelKey.id), isTrue);
    expect(saved.document[nullableLabelKey.id], isNull);
  });

  test('two SQLite writers resolve create CAS by reload and patch merge', () async {
    final recordsA = await _openRecords(root, settingsTestRegistry);
    closeables.add(recordsA.close);
    final manager = _manager(recordsA, settingsTestRegistry);
    closeables.add(manager.close);
    await manager.initialize();
    await manager.set(themeKey, 'dark');

    final writerB = PersistentSettingsStore(records: recordsA, scope: testScope, registry: settingsTestRegistry);
    await writerB.writeAll([
      SettingsDocument(
        id: appearanceDocument.id,
        kind: appearanceDocument.kind,
        values: {themeKey.id: 'light', nullableLabelKey.id: 'external', 'unknown': 7},
      ),
    ]);

    expect((await manager.flush()).persisted, isTrue);
    final saved = await recordsA.read(id: appearanceDocument.id, scope: testScope);
    expect(saved!.revision, 2);
    expect(saved.document[themeKey.id], 'dark');
    expect(saved.document[nullableLabelKey.id], 'external');
    expect(saved.document['unknown'], 7);
  });

  test('settings JSON accepts arbitrary keys and bounds oversized payloads', () async {
    final records = await _openRecords(root, settingsTestRegistry);
    closeables.add(records.close);
    final store = PersistentSettingsStore(records: records, scope: testScope, registry: settingsTestRegistry);

    await store.writeAll([
      SettingsDocument(id: appearanceDocument.id, kind: appearanceDocument.kind, values: {'api.token': 'allowed'}),
    ]);
    final saved = await records.read(id: appearanceDocument.id, scope: testScope);
    expect(saved!.document['api.token'], 'allowed');

    final oversized = <String, Object?>{for (var index = 0; index < 10; index++) 'extension$index': List.filled(7000, 'x').join()};
    await expectLater(
      store.writeAll([SettingsDocument(id: appearanceDocument.id, kind: appearanceDocument.kind, values: oversized)]),
      throwsA(isA<SettingsStoreFailure>()),
    );
  });

  test('small settings writes stay inline while structurally wider values use a worker', () async {
    final codec = settingsRecordDocumentCodecs(settingsTestRegistry, scopeKind: testScope.kind).first;

    final inline = await codec.prepareCurrent(<String, Object?>{themeKey.id: 'dark'});
    expect(inline.executionIsolateId, Isolate.current.hashCode);

    final background = await codec.prepareCurrent(<String, Object?>{'extension': List<int>.generate(65, (index) => index)});
    expect(background.executionIsolateId, isNot(Isolate.current.hashCode));
  });

  test('oversized CAS batches are rejected before codec workers spawn', () async {
    final records = await _openRecords(root, settingsTestRegistry);
    closeables.add(records.close);
    final writes = List.generate(
      PersistenceRecordStore.maxWriteBatchSize + 1,
      (index) => RecordDocumentWrite(
        id: '${appearanceDocument.id}:$index',
        recordKind: appearanceDocument.kind,
        scope: testScope,
        expectedRevision: null,
        document: {themeKey.id: 'system'},
      ),
    );

    await expectLater(records.writeDocumentsCas(writes), throwsA(isA<PersistenceValidationError>()));
    expect(records.lastCodecWorkerIsolateIdForTest, isNull);
  });
}

Future<PersistenceRecordStore> _openRecords(Directory root, SettingsRegistry registry) => PersistenceRecordStore.open(
  dataRoot: root,
  registry: RecordDocumentRegistry(settingsRecordDocumentCodecs(registry, scopeKind: testScope.kind)),
);

AppSettingsManager _manager(PersistenceRecordStore records, SettingsRegistry registry) => AppSettingsManager(
  store: PersistentSettingsStore(records: records, scope: testScope, registry: registry),
  registry: registry,
  policy: const SettingsPersistencePolicy(debounce: Duration(milliseconds: 20), retryBaseDelay: Duration(milliseconds: 20)),
);

SettingsRegistry _upgradingRegistry() => SettingsRegistry(
  keys: const [themeKey, nullableLabelKey],
  documents: [
    SettingsDocumentDefinition(
      id: appearanceDocument.id,
      kind: appearanceDocument.kind,
      currentVersion: 2,
      validators: const {1: _validateUpgradeV1, 2: _validateUpgradeV2},
      upgraders: const {1: _upgradeAppearanceV1},
    ),
  ],
);

void _validateUpgradeV1(Map<String, Object?> document) {
  if (document[themeKey.id] is! String) {
    throw const PersistenceValidationError('theme must be a string');
  }
}

void _validateUpgradeV2(Map<String, Object?> document) {
  _validateUpgradeV1(document);
  if (document.containsKey(nullableLabelKey.id) && document[nullableLabelKey.id] is! String && document[nullableLabelKey.id] != null) {
    throw const PersistenceValidationError('label must be nullable string');
  }
}

Map<String, Object?> _upgradeAppearanceV1(Map<String, Object?> document) => {
  ...document,
  if (!document.containsKey(nullableLabelKey.id)) nullableLabelKey.id: null,
};
