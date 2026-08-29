import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:io';

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
    final updated = await kit.store.update(previous: created, document: {'value': 'dark', 'enabled': null});
    expect(updated.revision, 2);
    expect((await kit.store.read(id: 'theme', scope: localScope))!.document['enabled'], isNull);
    await kit.store.delete(previous: updated);
    expect(await kit.store.read(id: 'theme', scope: localScope), isNull);
  });

  test('operation diagnostics exclude record IDs and document content', () async {
    const secretCanary = 'Bearer PERSISTENCE-SECRET-CANARY';
    const privateRecordId = 'private-record-identifier';
    await kit.dispose();
    final diagnostics = DiagnosticsTestkit();
    addTearDown(diagnostics.dispose);
    kit = await PersistenceTestkit.open(diagnostics: diagnostics.manager);

    final created = await kit.store.create(settingDraft(privateRecordId, value: secretCanary));
    await kit.store.read(id: privateRecordId, scope: localScope);
    await kit.store.update(previous: created, document: {'value': secretCanary, 'enabled': true});

    final eventNames = diagnostics.sink.events.map((event) => event.eventName);
    expect(eventNames, contains('persistence.open.complete'));
    expect(eventNames, contains('persistence.operation.complete'));
    final encoded = jsonEncode(diagnostics.sink.events.map(const DiagnosticEventCodec().encode).toList(growable: false));
    expect(encoded, isNot(contains(privateRecordId)));
    expect(encoded, isNot(contains(secretCanary)));
  });

  test('persists across close and reopen', () async {
    await kit.store.create(settingDraft('theme', value: 'dark'));
    final root = kit.root;
    await kit.store.close();
    final reopened = await PersistenceRecordStore.open(dataRoot: root, registry: defaultRegistry);
    addTearDown(reopened.close);
    expect((await reopened.read(id: 'theme', scope: localScope))!.document['value'], 'dark');
  });

  test('WAL retains committed data and rolls back an abruptly terminated transaction', () async {
    await kit.dispose();
    try {
      final root = await Directory.systemTemp.createTemp('mg-read-persistence-crash-');
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final helper =
          '${Directory.current.path}${Platform.pathSeparator}test${Platform.pathSeparator}'
          'core${Platform.pathSeparator}persistence${Platform.pathSeparator}persistence_crash_probe.dart';

      final dart = _dartExecutable();
      final committed = await Process.run(dart, <String>['run', helper, root.path, 'committed', 'committed-row']);
      expect(committed.exitCode, 0, reason: '${committed.stdout}\n${committed.stderr}');

      final uncommitted = await Process.start(dart, <String>['run', helper, root.path, 'uncommitted', 'uncommitted-row']);
      final ready = await uncommitted.stdout.transform(utf8.decoder).transform(const LineSplitter()).first;
      expect(ready, 'uncommitted-ready');
      expect(uncommitted.kill(), isTrue);
      await uncommitted.exitCode.timeout(const Duration(seconds: 10));

      final reopened = await PersistenceRecordStore.open(dataRoot: root, registry: defaultRegistry);
      try {
        expect(await reopened.debugPragmaForTest('journal_mode'), 'wal');
        expect(await reopened.debugPragmaForTest('quick_check'), 'ok');
        expect(await reopened.debugPragmaForTest('integrity_check'), 'ok');
        expect(await reopened.read(id: 'committed-row', scope: localScope), isNotNull);
        expect(await reopened.read(id: 'uncommitted-row', scope: localScope), isNull);
      } finally {
        await reopened.close();
      }
    } finally {
      kit = await PersistenceTestkit.open();
    }
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
      RecordDraft(id: 'other', recordKind: 'app_setting', scope: localScope, identityKey: 'other', document: const {'value': 'system'}),
    );

    final records = await kit.store.listByIdentityKeys(
      recordKind: 'app_setting',
      scope: localScope,
      identityKeys: const <String>['appearance', 'missing', 'appearance'],
    );

    expect(records.map((record) => record.id), <String>['first', 'second']);
    final filtered = await kit.store.listByIdentityKeys(
      recordKind: 'app_setting',
      scope: localScope,
      identityKeys: const <String>['appearance'],
      stateKey: 'selected',
    );
    expect(filtered, isEmpty);
    expect(await kit.store.listByIdentityKeys(recordKind: 'app_setting', scope: localScope, identityKeys: const <String>[]), isEmpty);
  });

  test('decodes bounded metadata inline and large documents in a worker', () async {
    final codec = defaultRegistry.require('app_setting', localScope.kind);

    final documents = await codec.decodeAndUpgradeMany(
      documents: const <({int version, String payloadJson})>[
        (version: 2, payloadJson: '{"value":"first","enabled":true}'),
        (version: 2, payloadJson: '{"value":"second","enabled":false}'),
        (version: 2, payloadJson: '{"value":"third"}'),
      ],
    );

    expect(documents.map((document) => document.document['value']), <String>['first', 'second', 'third']);
    expect(documents.first.document['enabled'], isTrue);
    expect(documents[1].document['enabled'], isFalse);
    expect(documents.map((document) => document.workerIsolateId).toSet(), hasLength(1));
    expect(documents.first.workerIsolateId, Isolate.current.hashCode);

    final large = await codec.decodeAndUpgrade(version: 2, payloadJson: jsonEncode(<String, Object?>{'value': 'x' * (5 * 1024)}));
    expect(large.workerIsolateId, isNot(Isolate.current.hashCode));
  });

  test('encodes a metadata write batch in one worker invocation', () async {
    final codec = defaultRegistry.require('app_setting', localScope.kind);

    final documents = await codec.prepareCurrentMany(
      documents: const <JsonObject>[
        {'value': 'first'},
        {'value': 'second'},
        {'value': 'third'},
      ],
    );

    expect(documents, hasLength(3));
    expect(documents.map((document) => document.document['value']), <String>['first', 'second', 'third']);
    expect(documents.map((document) => document.workerIsolateId).toSet(), hasLength(1));
    expect(documents.first.workerIsolateId, isNot(Isolate.current.hashCode));
  });

  test('explicit bounded write policy inlines small documents and falls back by structure', () async {
    final codec = RecordDocumentCodec(
      recordKind: 'inline_setting',
      scopeKind: 'local',
      currentVersion: 1,
      validators: {1: _validateStringValue},
      inlinePreparationPolicy: const JsonInlinePreparationPolicy(
        maxDocuments: 2,
        maxTotalNodes: 16,
        maxDepth: 4,
        maxCollectionLength: 4,
        maxTotalTextCodeUnits: 128,
      ),
    );

    final inline = await codec.prepareCurrent(const {'value': 'small'});
    expect(inline.executionIsolateId, Isolate.current.hashCode);
    await expectLater(codec.prepareCurrent(const {'value': 7}), throwsA(isA<PersistenceValidationError>()));

    final structurallyWide = await codec.prepareCurrent({'value': 'small', 'items': List<int>.generate(5, (index) => index)});
    expect(structurallyWide.executionIsolateId, isNot(Isolate.current.hashCode));

    final oversizedBatch = await codec.prepareCurrentMany(
      documents: const [
        {'value': 'first'},
        {'value': 'second'},
        {'value': 'third'},
      ],
    );
    expect(oversizedBatch.map((document) => document.executionIsolateId).toSet(), hasLength(1));
    expect(oversizedBatch.first.executionIsolateId, isNot(Isolate.current.hashCode));
  });

  test('upgrades a large decode batch in one worker invocation', () async {
    final codec = defaultRegistry.require('app_setting', localScope.kind);
    final payload = jsonEncode(<String, Object?>{'value': 'x' * (5 * 1024), 'unknown': 7});

    final documents = await codec.decodeAndUpgradeMany(
      documents: <({int version, String payloadJson})>[(version: 1, payloadJson: payload), (version: 1, payloadJson: payload)],
    );

    expect(documents, hasLength(2));
    expect(documents.every((document) => document.document['enabled'] == true), isTrue);
    expect(documents.first.document['unknown'], 7);
    expect(documents.map((document) => document.workerIsolateId).toSet(), hasLength(1));
    expect(documents.first.workerIsolateId, isNot(Isolate.current.hashCode));
  });

  test('preserves validation errors for large upgraded documents', () async {
    final codec = defaultRegistry.require('app_setting', localScope.kind);
    final payload = jsonEncode(<String, Object?>{'value': 7, 'padding': 'x' * (5 * 1024)});

    await expectLater(codec.decodeAndUpgrade(version: 1, payloadJson: payload), throwsA(isA<PersistenceValidationError>()));
  });

  test('keeps corruption semantics when decode falls back to a worker', () async {
    final codec = defaultRegistry.require('app_setting', localScope.kind);
    final malformedLargePayload = '{bad${' ' * (5 * 1024)}';

    await expectLater(codec.decodeAndUpgrade(version: 2, payloadJson: malformedLargePayload), throwsA(isA<PersistenceCorruptionError>()));
  });

  test('prepares a CAS write batch through one codec worker', () async {
    final results = await kit.store.writeDocumentsCas([
      RecordDocumentWrite(
        id: 'first',
        recordKind: 'app_setting',
        scope: localScope,
        expectedRevision: null,
        document: {'value': 'x' * (5 * 1024)},
      ),
      RecordDocumentWrite(
        id: 'second',
        recordKind: 'app_setting',
        scope: localScope,
        expectedRevision: null,
        document: {'value': 'y' * (5 * 1024)},
      ),
    ]);

    expect(results.map((result) => result.id), ['first', 'second']);
    expect(kit.store.lastCodecWorkerIsolateIdForTest, isNot(Isolate.current.hashCode));
  });

  test('processes a mixed-codec registry batch in one worker', () async {
    final registry = RecordDocumentRegistry([
      RecordDocumentCodec(recordKind: 'first', scopeKind: 'local', currentVersion: 1, validators: {1: _validateStringValue}),
      RecordDocumentCodec(recordKind: 'second', scopeKind: 'local', currentVersion: 1, validators: {1: _validateStringValue}),
    ]);
    final documents = <({String recordKind, String scopeKind, JsonObject document})>[
      (recordKind: 'first', scopeKind: 'local', document: {'value': 'x' * (5 * 1024)}),
      (recordKind: 'second', scopeKind: 'local', document: {'value': 'y' * (5 * 1024)}),
    ];

    final encoded = await registry.prepareCurrentMany(documents: documents);
    expect(encoded.map((document) => document.workerIsolateId).toSet(), hasLength(1));
    expect(encoded.first.workerIsolateId, isNot(Isolate.current.hashCode));

    final decoded = await registry.decodeAndUpgradeMany(
      documents: <({String recordKind, String scopeKind, int version, String payloadJson})>[
        (recordKind: 'first', scopeKind: 'local', version: 1, payloadJson: encoded.first.payloadJson),
        (recordKind: 'second', scopeKind: 'local', version: 1, payloadJson: encoded.last.payloadJson),
      ],
    );
    expect(decoded.map((document) => document.workerIsolateId).toSet(), hasLength(1));
    expect(decoded.first.workerIsolateId, isNot(Isolate.current.hashCode));
  });

  test('rejects stale revisions', () async {
    final created = await kit.store.create(settingDraft('theme'));
    await kit.store.update(previous: created, document: {'value': 'dark', 'enabled': true});
    await expectLater(
      kit.store.update(previous: created, document: {'value': 'light', 'enabled': true}),
      throwsA(isA<PersistenceConflictError>()),
    );
  });

  test('reports corrupt JSON with a stable error', () async {
    await kit.store.create(settingDraft('theme'));
    await kit.store.debugReplacePayloadForTest(id: 'theme', scope: localScope, version: 2, payloadJson: '{bad');
    await expectLater(kit.store.read(id: 'theme', scope: localScope), throwsA(isA<PersistenceCorruptionError>()));
  });

  test('protects future document versions as read-only', () async {
    await kit.store.create(settingDraft('theme'));
    await kit.store.debugReplacePayloadForTest(id: 'theme', scope: localScope, version: 3, payloadJson: '{"value":"dark"}');
    await expectLater(kit.store.read(id: 'theme', scope: localScope), throwsA(isA<PersistenceFutureVersionError>()));
  });

  test('keeps unknown fields and distinguishes null from missing', () async {
    final created = await kit.store.create(settingDraft('theme', extra: {'flag': null}));
    final updated = await kit.store.update(previous: created, document: {...created.document, 'value': 'dark', 'enabled': null});
    expect(updated.document['futureExtension'], {'flag': null});
    expect(updated.document.containsKey('enabled'), isTrue);
  });

  test('applies a deterministic upgrade chain', () async {
    await kit.store.create(settingDraft('theme'));
    await kit.store.debugReplacePayloadForTest(id: 'theme', scope: localScope, version: 1, payloadJson: '{"value":"dark","unknown":7}');
    final record = await kit.store.read(id: 'theme', scope: localScope);
    expect(record!.formatVersion, 2);
    expect(record.document, {'value': 'dark', 'unknown': 7, 'enabled': true});
  });

  test('batch creation is atomic', () async {
    await expectLater(kit.store.createBatch([settingDraft('one'), settingDraft('one')]), throwsA(isA<PersistenceConflictError>()));
    expect(await kit.store.read(id: 'one', scope: localScope), isNull);
  });

  test('creates and CAS-deletes the maximum batch with one public operation', () async {
    final drafts = <RecordDraft>[
      for (var index = 0; index < PersistenceRecordStore.maxWriteBatchSize; index++) settingDraft('batch-$index'),
    ];
    await kit.store.createBatch(drafts);
    final records = (await kit.store.readMany(ids: drafts.map((draft) => draft.id), scope: localScope)).records.values.toList();
    expect(records, hasLength(PersistenceRecordStore.maxWriteBatchSize));

    await kit.store.deleteBatch(records);

    expect((await kit.store.readMany(ids: drafts.map((draft) => draft.id), scope: localScope)).records, isEmpty);
  });

  test('CAS delete batch rejects duplicates and rolls back every matched row on conflict', () async {
    final first = await kit.store.create(settingDraft('delete-first'));
    final second = await kit.store.create(settingDraft('delete-second'));
    await expectLater(kit.store.deleteBatch(<RecordEnvelope>[first, first]), throwsA(isA<PersistenceValidationError>()));

    await kit.store.update(previous: first, document: const <String, Object?>{'value': 'new'});
    await expectLater(kit.store.deleteBatch(<RecordEnvelope>[first, second]), throwsA(isA<PersistenceConflictError>()));

    expect(await kit.store.read(id: 'delete-first', scope: localScope), isNotNull);
    expect(await kit.store.read(id: 'delete-second', scope: localScope), isNotNull);
  });

  test('uses a background executor and has a defined close boundary', () async {
    expect(kit.store.usesBackgroundExecutor, isTrue);
    await kit.store.close();
    await expectLater(kit.store.read(id: 'theme', scope: localScope), throwsA(isA<PersistenceClosedError>()));
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
    await expectLater(kit.store.read(id: 'theme', scope: localScope), throwsA(isA<PersistenceClosedError>()));
  });
}

String _dartExecutable() {
  var directory = File(Platform.resolvedExecutable).parent;
  while (true) {
    final candidate = File(
      '${directory.path}${Platform.pathSeparator}bin${Platform.pathSeparator}cache${Platform.pathSeparator}'
      'dart-sdk${Platform.pathSeparator}bin${Platform.pathSeparator}dart.exe',
    );
    if (candidate.existsSync()) return candidate.path;
    final parent = directory.parent;
    if (parent.path == directory.path) break;
    directory = parent;
  }
  throw StateError('Unable to locate the Flutter-bundled Dart executable.');
}

void _validateStringValue(JsonObject document) {
  if (document['value'] is! String) {
    throw const PersistenceValidationError('value must be a string');
  }
}
