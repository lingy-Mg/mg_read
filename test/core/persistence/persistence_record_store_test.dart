import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/core/persistence/persistence.dart';

import '../diagnostics/diagnostics_testkit.dart';
import 'persistence_testkit.dart';

void main() {
  late PersistenceTestkit kit;

  setUp(() async => kit = await PersistenceTestkit.open());
  tearDown(() async => kit.dispose());

  test('CRUD and revision CAS preserve the stable envelope', () async {
    final created = await kit.store.create(settingDraft('theme'));
    expect(created.revision, 1);
    final updated = await kit.store.update(
      previous: created,
      document: {'value': 'dark', 'enabled': null},
    );
    expect(updated.revision, 2);
    expect(
      (await kit.store.read(
        id: 'theme',
        scope: localScope,
      ))!.document['enabled'],
      isNull,
    );
    await kit.store.delete(previous: updated);
    expect(await kit.store.read(id: 'theme', scope: localScope), isNull);
  });

  test(
    'operation diagnostics exclude record IDs and document content',
    () async {
      const secretCanary = 'Bearer PERSISTENCE-SECRET-CANARY';
      const privateRecordId = 'private-record-identifier';
      await kit.dispose();
      final diagnostics = DiagnosticsTestkit();
      addTearDown(diagnostics.dispose);
      kit = await PersistenceTestkit.open(diagnostics: diagnostics.manager);

      final created = await kit.store.create(
        settingDraft(privateRecordId, value: secretCanary),
      );
      await kit.store.read(id: privateRecordId, scope: localScope);
      await kit.store.update(
        previous: created,
        document: {'value': secretCanary, 'enabled': true},
      );

      final eventNames = diagnostics.sink.events.map(
        (event) => event.eventName,
      );
      expect(eventNames, contains('persistence.open.complete'));
      expect(eventNames, contains('persistence.operation.complete'));
      final encoded = jsonEncode(
        diagnostics.sink.events
            .map(const DiagnosticEventCodec().encode)
            .toList(growable: false),
      );
      expect(encoded, isNot(contains(privateRecordId)));
      expect(encoded, isNot(contains(secretCanary)));
    },
  );

  test('persists across close and reopen', () async {
    await kit.store.create(settingDraft('theme', value: 'dark'));
    final root = kit.root;
    await kit.store.close();
    final reopened = await PersistenceRecordStore.open(
      dataRoot: root,
      registry: defaultRegistry,
    );
    addTearDown(reopened.close);
    expect(
      (await reopened.read(id: 'theme', scope: localScope))!.document['value'],
      'dark',
    );
  });

  test('isolates records by complete scope key', () async {
    await kit.store.create(settingDraft('theme'));
    expect(
      await kit.store.read(
        id: 'theme',
        scope: const ScopeKey(kind: 'local', id: 'secondary'),
      ),
      isNull,
    );
  });

  test('reads a bounded identity-key set with one ordered query', () async {
    await kit.store.create(
      RecordDraft(
        id: 'second',
        recordKind: 'app_setting',
        scope: localScope,
        identityKey: 'appearance',
        orderKey: '2',
        document: const {'value': 'dark'},
      ),
    );
    await kit.store.create(
      RecordDraft(
        id: 'first',
        recordKind: 'app_setting',
        scope: localScope,
        identityKey: 'appearance',
        orderKey: '1',
        document: const {'value': 'light'},
      ),
    );
    await kit.store.create(
      RecordDraft(
        id: 'other',
        recordKind: 'app_setting',
        scope: localScope,
        identityKey: 'other',
        document: const {'value': 'system'},
      ),
    );

    final records = await kit.store.listByIdentityKeys(
      recordKind: 'app_setting',
      scope: localScope,
      identityKeys: const <String>['appearance', 'missing', 'appearance'],
    );

    expect(records.map((record) => record.id), <String>['first', 'second']);
    expect(
      await kit.store.listByIdentityKeys(
        recordKind: 'app_setting',
        scope: localScope,
        identityKeys: const <String>[],
      ),
      isEmpty,
    );
  });

  test('rejects stale revisions', () async {
    final created = await kit.store.create(settingDraft('theme'));
    await kit.store.update(
      previous: created,
      document: {'value': 'dark', 'enabled': true},
    );
    await expectLater(
      kit.store.update(
        previous: created,
        document: {'value': 'light', 'enabled': true},
      ),
      throwsA(isA<PersistenceConflictError>()),
    );
  });

  test('reports corrupt JSON with a stable error', () async {
    await kit.store.create(settingDraft('theme'));
    await kit.store.debugReplacePayloadForTest(
      id: 'theme',
      scope: localScope,
      version: 2,
      payloadJson: '{bad',
    );
    await expectLater(
      kit.store.read(id: 'theme', scope: localScope),
      throwsA(isA<PersistenceCorruptionError>()),
    );
  });

  test('protects future document versions as read-only', () async {
    await kit.store.create(settingDraft('theme'));
    await kit.store.debugReplacePayloadForTest(
      id: 'theme',
      scope: localScope,
      version: 3,
      payloadJson: '{"value":"dark"}',
    );
    await expectLater(
      kit.store.read(id: 'theme', scope: localScope),
      throwsA(isA<PersistenceFutureVersionError>()),
    );
  });

  test('keeps unknown fields and distinguishes null from missing', () async {
    final created = await kit.store.create(
      settingDraft('theme', extra: {'flag': null}),
    );
    final updated = await kit.store.update(
      previous: created,
      document: {...created.document, 'value': 'dark', 'enabled': null},
    );
    expect(updated.document['futureExtension'], {'flag': null});
    expect(updated.document.containsKey('enabled'), isTrue);
  });

  test('applies a deterministic upgrade chain', () async {
    await kit.store.create(settingDraft('theme'));
    await kit.store.debugReplacePayloadForTest(
      id: 'theme',
      scope: localScope,
      version: 1,
      payloadJson: '{"value":"dark","unknown":7}',
    );
    final record = await kit.store.read(id: 'theme', scope: localScope);
    expect(record!.formatVersion, 2);
    expect(record.document, {'value': 'dark', 'unknown': 7, 'enabled': true});
  });

  test('batch creation is atomic', () async {
    await expectLater(
      kit.store.createBatch([settingDraft('one'), settingDraft('one')]),
      throwsA(isA<PersistenceConflictError>()),
    );
    expect(await kit.store.read(id: 'one', scope: localScope), isNull);
  });

  test('uses a background executor and has a defined close boundary', () async {
    expect(kit.store.usesBackgroundExecutor, isTrue);
    await kit.store.close();
    await expectLater(
      kit.store.read(id: 'theme', scope: localScope),
      throwsA(isA<PersistenceClosedError>()),
    );
  });

  test('close waits for an already-started transaction', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    var transactionFinished = false;
    final transaction = kit.store.transaction(() async {
      entered.complete();
      await release.future;
      transactionFinished = true;
    });

    await entered.future;
    final close = kit.store.close();
    await Future<void>.delayed(Duration.zero);
    expect(transactionFinished, isFalse);

    release.complete();
    await transaction;
    await close;
    expect(transactionFinished, isTrue);
    await expectLater(
      kit.store.read(id: 'theme', scope: localScope),
      throwsA(isA<PersistenceClosedError>()),
    );
  });
}
