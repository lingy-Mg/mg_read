import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/settings/settings.dart';

import 'settings_testkit.dart';

void main() {
  late FakeSettingsStore store;
  late AppSettingsManager manager;

  setUp(() {
    store = FakeSettingsStore();
    manager = AppSettingsManager(
      store: store,
      registry: settingsTestRegistry,
      policy: const SettingsPersistencePolicy(
        debounce: Duration(milliseconds: 40),
        retryBaseDelay: Duration(milliseconds: 25),
        retryMaxDelay: Duration(milliseconds: 25),
        closeTimeout: Duration(seconds: 1),
      ),
    );
  });

  tearDown(() async {
    await manager.close();
  });

  test(
    'initializes with one registered batch and get stays store-free',
    () async {
      await manager.initialize();

      expect(manager.state, SettingsState.ready);
      expect(manager.get(themeKey), 'system');
      expect(manager.get(pageStepKey), 1);
      expect(store.loadCalls, 1);
      expect(store.writeCalls, 0);

      for (var index = 0; index < 1000; index++) {
        expect(manager.get(themeKey), 'system');
      }
      expect(store.loadCalls, 1);
      expect(store.writeCalls, 0, reason: 'defaults are memory-only');
    },
  );

  test(
    'close wins an in-flight factory initialization and closes its store',
    () async {
      await manager.close();
      final factoryGate = Completer<SettingsStore>();
      final lateStore = FakeSettingsStore();
      var factoryCalls = 0;
      manager = AppSettingsManager(
        storeFactory: () {
          factoryCalls++;
          return factoryGate.future;
        },
        registry: settingsTestRegistry,
        policy: const SettingsPersistencePolicy(
          closeTimeout: Duration(milliseconds: 100),
        ),
      );

      final initializing = manager.initialize();
      await waitUntil(() => factoryCalls == 1);
      final closing = manager.close();
      expect(manager.state, SettingsState.closing);
      factoryGate.complete(lateStore);

      await initializing;
      await closing;
      expect(manager.state, SettingsState.closed);
      expect(lateStore.loadCalls, 0);
      expect(lateStore.closeCalls, 1);
    },
  );

  test(
    'set is immediate, notifications are synchronous, writes coalesce',
    () async {
      await manager.initialize();
      var notifications = 0;
      bool? dirtyObservedByListener;
      final subscription = manager.changes.listen((_) {
        notifications++;
        dirtyObservedByListener = manager.status.isDirty;
      });
      addTearDown(subscription.cancel);

      final first = manager.set(themeKey, 'light');
      expect(manager.get(themeKey), 'light');
      expect(notifications, 1);
      expect(dirtyObservedByListener, isTrue);
      expect(manager.status.isDirty, isTrue);
      expect(store.writeCalls, 0);
      await first;

      await Future<void>.delayed(const Duration(milliseconds: 20));
      await manager.set(themeKey, 'dark');
      expect(manager.get(themeKey), 'dark');
      expect(notifications, 2);

      await waitUntil(() => store.writeCalls == 1);
      expect(
        store.documents[appearanceDocument.kind]!.values[themeKey.id],
        'dark',
      );
      expect(manager.status.isPersisted, isTrue);
    },
  );

  test('document groups use independent trailing debounce windows', () async {
    await manager.initialize();
    await manager.set(themeKey, 'dark');
    await Future<void>.delayed(const Duration(milliseconds: 25));
    await manager.set(pageStepKey, 9);

    await waitUntil(() => store.writeBatches.isNotEmpty);
    expect(store.writeBatches.first.map((document) => document.kind), [
      appearanceDocument.kind,
    ]);
    await waitUntil(() => store.writeCalls == 2);
    expect(store.documents[behaviorDocument.kind]!.values[pageStepKey.id], 9);
  });

  test('nullable null remains distinct from a missing field', () async {
    store.documents[appearanceDocument.kind] = SettingsDocument(
      id: appearanceDocument.id,
      kind: appearanceDocument.kind,
      values: {nullableLabelKey.id: null, 'futureExtension': null},
      revision: 1,
    );
    await manager.initialize();

    expect(manager.snapshot.contains(nullableLabelKey), isTrue);
    expect(manager.get(nullableLabelKey), isNull);

    await manager.reset(nullableLabelKey);
    expect(manager.snapshot.contains(nullableLabelKey), isFalse);
    expect(manager.get(nullableLabelKey), 'fallback');
    await manager.flush();
    final persisted = store.documents[appearanceDocument.kind]!.values;
    expect(persisted.containsKey(nullableLabelKey.id), isFalse);
    expect(persisted, containsPair('futureExtension', null));
  });

  test(
    'resetGroup removes registered keys but preserves unknown fields',
    () async {
      store.documents[appearanceDocument.kind] = SettingsDocument(
        id: appearanceDocument.id,
        kind: appearanceDocument.kind,
        values: {
          themeKey.id: 'dark',
          nullableLabelKey.id: null,
          'futureExtension': 9,
        },
        revision: 1,
      );
      await manager.initialize();

      await manager.resetGroup(appearanceDocument.kind);

      expect(manager.get(themeKey), 'system');
      expect(manager.get(nullableLabelKey), 'fallback');
      await manager.flush();
      expect(store.documents[appearanceDocument.kind]!.values, {
        'futureExtension': 9,
      });
    },
  );

  test(
    'transaction publishes atomically and only changes touched groups',
    () async {
      await manager.initialize();
      final snapshots = <SettingsSnapshot>[];
      final subscription = manager.changes.listen(snapshots.add);
      addTearDown(subscription.cancel);

      await manager.transaction((editor) {
        editor.set(themeKey, 'dark');
        editor.set(pageStepKey, 7);
      });

      expect(snapshots, hasLength(1));
      expect(snapshots.single.get(themeKey), 'dark');
      expect(snapshots.single.get(pageStepKey), 7);
      await manager.flush();
      expect(store.writeBatches.last.map((document) => document.kind).toSet(), {
        appearanceDocument.kind,
        behaviorDocument.kind,
      });
    },
  );

  test('a mutation encodes only keys in the changed document group', () async {
    var appearanceEncodes = 0;
    var behaviorEncodes = 0;
    final appearanceKey = SettingKey<int>(
      id: 'appearance.counter',
      documentKind: appearanceDocument.kind,
      defaultValue: 0,
      codec: SettingCodec<int>((value) {
        appearanceEncodes++;
        return value;
      }, intDecode),
      validator: (_) {},
    );
    final behaviorKey = SettingKey<int>(
      id: 'behavior.counter',
      documentKind: behaviorDocument.kind,
      defaultValue: 0,
      codec: SettingCodec<int>((value) {
        behaviorEncodes++;
        return value;
      }, intDecode),
      validator: (_) {},
    );
    final registry = SettingsRegistry(
      keys: [appearanceKey, behaviorKey],
      documents: const [appearanceDocument, behaviorDocument],
    );
    final localStore = FakeSettingsStore();
    final localManager = AppSettingsManager(
      store: localStore,
      registry: registry,
      policy: const SettingsPersistencePolicy(debounce: Duration(hours: 1)),
    );
    addTearDown(localManager.close);
    await localManager.initialize();
    final initialAppearanceEncodes = appearanceEncodes;
    final initialBehaviorEncodes = behaviorEncodes;

    await localManager.set(appearanceKey, 4);

    expect(appearanceEncodes, initialAppearanceEncodes + 1);
    expect(behaviorEncodes, initialBehaviorEncodes);
    await localManager.flush();
    expect(localStore.writeBatches.single.single.kind, appearanceDocument.kind);
  });

  test(
    'collection settings cannot mutate memory through caller aliases',
    () async {
      final defaultNested = <Object?>[0];
      final defaultInput = <String, Object?>{'nested': defaultNested};
      final collectionKey = SettingKey<Map<String, Object?>>(
        id: 'appearance.extensions',
        documentKind: appearanceDocument.kind,
        defaultValue: defaultInput,
        codec: SettingCodec<Map<String, Object?>>((value) => value, (value) {
          if (value is! Map) {
            throw const FormatException('Expected settings map.');
          }
          return Map<String, Object?>.from(value);
        }, freeze: freezeJsonSettingMap),
        validator: (_) {},
      );
      final localStore = FakeSettingsStore();
      final localManager = AppSettingsManager(
        store: localStore,
        registry: SettingsRegistry(
          keys: [collectionKey],
          documents: const [appearanceDocument],
        ),
        policy: const SettingsPersistencePolicy(debounce: Duration(hours: 1)),
      );
      addTearDown(localManager.close);
      defaultInput['lateDefault'] = true;
      defaultNested.add(9);
      await localManager.initialize();
      final safeDefault = localManager.get(collectionKey);
      expect(safeDefault, {
        'nested': [0],
      });
      expect(() => safeDefault['lateDefault'] = true, throwsUnsupportedError);
      final nested = <Object?>[1];
      final input = <String, Object?>{'nested': nested};

      final setting = localManager.set(collectionKey, input);
      input['late'] = true;
      nested.add(2);
      await setting;

      final stored = localManager.get(collectionKey);
      expect(stored, {
        'nested': [1],
      });
      expect(() => stored['late'] = true, throwsUnsupportedError);
      expect(
        () => (stored['nested'] as List<Object?>).add(3),
        throwsUnsupportedError,
      );
      expect(
        localManager.status.documents[appearanceDocument.kind]!.generation,
        1,
      );
    },
  );

  test(
    'typed list settings retain their runtime type and immutability',
    () async {
      final mutableDefault = <String>['system'];
      final listKey = SettingKey<List<String>>(
        id: 'appearance.fontFallbacks',
        documentKind: appearanceDocument.kind,
        defaultValue: mutableDefault,
        codec: SettingCodec<List<String>>((value) => value, (value) {
          if (value is! List || value.any((item) => item is! String)) {
            throw const FormatException('Expected a string list.');
          }
          return List<String>.of(value.cast<String>());
        }, freeze: freezeSettingList<String>),
        validator: (_) {},
      );
      final localManager = AppSettingsManager(
        store: FakeSettingsStore(),
        registry: SettingsRegistry(
          keys: [listKey],
          documents: const [appearanceDocument],
        ),
        policy: const SettingsPersistencePolicy(debounce: Duration(hours: 1)),
      );
      addTearDown(localManager.close);
      mutableDefault.add('late-default');
      await localManager.initialize();

      final safeDefault = localManager.get(listKey);
      expect(safeDefault, isA<List<String>>());
      expect(safeDefault, ['system']);
      expect(() => safeDefault.add('mutated'), throwsUnsupportedError);

      final input = <String>['serif'];
      final setting = localManager.set(listKey, input);
      input.add('late-value');
      await setting;
      final stored = localManager.get(listKey);
      expect(stored, isA<List<String>>());
      expect(stored, ['serif']);
      expect(() => stored.add('mutated'), throwsUnsupportedError);
    },
  );

  test('write failure keeps the session value dirty and retries', () async {
    await manager.initialize();
    store.failWrites = 1;
    final observedStates = <SettingsState>[];
    final subscription = manager.statusChanges.listen(
      (status) => observedStates.add(status.state),
    );
    addTearDown(subscription.cancel);

    await manager.set(themeKey, 'dark');
    expect(manager.get(themeKey), 'dark');
    await waitUntil(() => observedStates.contains(SettingsState.degraded));
    expect(manager.status.isDirty, isTrue);
    expect(
      manager.status.documents[appearanceDocument.kind]!.lastErrorCode,
      'injected_write_failure',
    );

    await waitUntil(() => manager.status.isPersisted);
    expect(manager.state, SettingsState.ready);
    expect(store.writeCalls, 2);
    expect(
      store.documents[appearanceDocument.kind]!.values[themeKey.id],
      'dark',
    );
  });

  test('close is bounded when a persistence write never completes', () async {
    await manager.close();
    store = FakeSettingsStore()..writeGate = Completer<void>();
    manager = AppSettingsManager(
      store: store,
      registry: settingsTestRegistry,
      policy: const SettingsPersistencePolicy(
        debounce: Duration(hours: 1),
        closeTimeout: Duration(milliseconds: 30),
      ),
    );
    await manager.initialize();
    await manager.set(themeKey, 'dark');
    final started = Stopwatch()..start();

    await manager.close();

    started.stop();
    expect(started.elapsed, lessThan(const Duration(milliseconds: 500)));
    expect(manager.state, SettingsState.closed);
    expect(manager.status.lastErrorCode, 'close_flush_timeout');
    expect(manager.status.isDirty, isTrue);
    store.writeGate!.complete();
  });

  test(
    'close is bounded when a synchronous stream listener is paused',
    () async {
      await manager.close();
      store = FakeSettingsStore();
      manager = AppSettingsManager(
        store: store,
        registry: settingsTestRegistry,
        policy: const SettingsPersistencePolicy(
          closeTimeout: Duration(milliseconds: 30),
        ),
      );
      await manager.initialize();
      final subscription = manager.changes.listen((_) {});
      subscription.pause();
      final started = Stopwatch()..start();

      await manager.close();

      started.stop();
      expect(started.elapsed, lessThan(const Duration(milliseconds: 500)));
      expect(manager.state, SettingsState.closed);
      expect(manager.status.lastErrorCode, 'close_stream_timeout');
      await subscription.cancel();
    },
  );

  test(
    'flush bypasses a long debounce and persists the pending value',
    () async {
      await manager.close();
      store = FakeSettingsStore();
      manager = AppSettingsManager(
        store: store,
        registry: settingsTestRegistry,
        policy: const SettingsPersistencePolicy(debounce: Duration(hours: 1)),
      );
      await manager.initialize();
      await manager.set(themeKey, 'dark');

      final result = await manager.flush();

      expect(result.persisted, isTrue);
      expect(store.writeCalls, 1);
      expect(
        store.documents[appearanceDocument.kind]!.values[themeKey.id],
        'dark',
      );
    },
  );

  test('close forces pending work and waits for an in-flight write', () async {
    await manager.initialize();
    store.writeGate = Completer<void>();
    await manager.set(themeKey, 'dark');
    final flush = manager.flush();
    await waitUntil(() => store.writeCalls == 1);

    var closed = false;
    final closing = manager.close().then((_) => closed = true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(closed, isFalse);
    expect(manager.state, SettingsState.closing);

    store.writeGate!.complete();
    await flush;
    await closing;
    expect(manager.state, SettingsState.closed);
    expect(store.closeCalls, 1);
    expect(
      store.documents[appearanceDocument.kind]!.values[themeKey.id],
      'dark',
    );
  });

  test(
    'future and corrupt groups are degraded, defaulted, and read-only',
    () async {
      store.documents[appearanceDocument.kind] = SettingsDocument(
        id: appearanceDocument.id,
        kind: appearanceDocument.kind,
        values: const {},
        problem: SettingsDocumentProblem.futureVersion,
      );
      await manager.initialize();

      expect(manager.state, SettingsState.degraded);
      expect(manager.get(themeKey), 'system');
      expect(
        manager.status.documents[appearanceDocument.kind]!.readOnly,
        isTrue,
      );
      await expectLater(
        manager.set(themeKey, 'dark'),
        throwsA(isA<SettingsReadOnlyException>()),
      );
      expect(store.writeCalls, 0);
    },
  );

  test(
    'CAS conflict reloads and merges the local patch over new fields',
    () async {
      store.documents[appearanceDocument.kind] = SettingsDocument(
        id: appearanceDocument.id,
        kind: appearanceDocument.kind,
        values: {themeKey.id: 'system', 'unknown': 'old'},
        revision: 1,
      );
      await manager.initialize();
      await manager.set(themeKey, 'dark');
      store.externalWrite(appearanceDocument.kind, {
        themeKey.id: 'light',
        nullableLabelKey.id: 'external',
        'unknown': 'new',
      });

      final result = await manager.flush();

      expect(result.persisted, isTrue);
      expect(store.loadCalls, 2, reason: 'initial load plus conflict reload');
      final values = store.documents[appearanceDocument.kind]!.values;
      expect(values[themeKey.id], 'dark', reason: 'pending local key wins');
      expect(values[nullableLabelKey.id], 'external');
      expect(values['unknown'], 'new');
      expect(manager.get(nullableLabelKey), 'external');
    },
  );

  test(
    'CAS reload corruption clears the patch and exposes safe defaults',
    () async {
      store.documents[appearanceDocument.kind] = SettingsDocument(
        id: appearanceDocument.id,
        kind: appearanceDocument.kind,
        values: {themeKey.id: 'system'},
        revision: 1,
      );
      await manager.initialize();
      await manager.set(themeKey, 'dark');
      store.documents[appearanceDocument.kind] = SettingsDocument(
        id: appearanceDocument.id,
        kind: appearanceDocument.kind,
        values: const {},
        revision: 2,
        problem: SettingsDocumentProblem.corruption,
      );

      final result = await manager.flush();

      expect(manager.get(themeKey), 'system');
      expect(manager.state, SettingsState.degraded);
      expect(manager.status.isDirty, isFalse);
      expect(result.dirtyDocumentKinds, isEmpty);
      expect(
        manager.status.documents[appearanceDocument.kind]!.lastErrorCode,
        'corrupt_document',
      );
      expect(
        manager.status.documents[appearanceDocument.kind]!.readOnly,
        isTrue,
      );
      expect(store.writeCalls, 1);
    },
  );

  test('registry rejects duplicate and sensitive setting IDs', () {
    expect(
      () => SettingsRegistry.fromKeys(const [themeKey, themeKey]),
      throwsArgumentError,
    );
    const secretKey = SettingKey<String>(
      id: 'account.accessToken',
      documentKind: 'settings.appearance',
      defaultValue: '',
      codec: SettingCodec<String>(stringEncode, stringDecode),
      validator: validateNullableLabel,
    );
    expect(
      () => SettingsRegistry(
        keys: const [secretKey],
        documents: const [appearanceDocument],
      ),
      throwsArgumentError,
    );

    final unsafeCollectionKey = SettingKey<List<String>>(
      id: 'appearance.unsafeList',
      documentKind: appearanceDocument.kind,
      defaultValue: <String>[],
      codec: SettingCodec<List<String>>(
        (value) => value,
        (value) => List<String>.of((value! as List).cast<String>()),
      ),
      validator: (_) {},
    );
    expect(
      () => SettingsRegistry(
        keys: [unsafeCollectionKey],
        documents: const [appearanceDocument],
      ),
      throwsArgumentError,
    );
  });

  test(
    'manager rejects an unregistered key object that spoofs a stable ID',
    () async {
      await manager.initialize();
      final spoof = SettingKey<String>(
        id: themeKey.id,
        documentKind: themeKey.documentKind,
        defaultValue: 'dark',
        codec: const SettingCodec<String>(stringEncode, stringDecode),
        validator: validateTheme,
      );

      expect(() => manager.get(spoof), throwsArgumentError);
      await expectLater(manager.set(spoof, 'dark'), throwsArgumentError);
      expect(manager.get(themeKey), 'system');
    },
  );

  test(
    'oversized encoded values are rejected before changing memory',
    () async {
      final largeKey = SettingKey<Map<String, Object?>>(
        id: 'appearance.extensions',
        documentKind: appearanceDocument.kind,
        defaultValue: const {},
        codec: SettingCodec<Map<String, Object?>>((value) => value, (value) {
          if (value is! Map<String, Object?>) {
            throw const FormatException('Expected settings map.');
          }
          return Map<String, Object?>.of(value);
        }, freeze: freezeJsonSettingMap),
        validator: (_) {},
      );
      final registry = SettingsRegistry(
        keys: [largeKey],
        documents: const [appearanceDocument],
      );
      final localManager = AppSettingsManager(
        store: FakeSettingsStore(),
        registry: registry,
      );
      addTearDown(localManager.close);
      await localManager.initialize();
      final oversized = <String, Object?>{
        for (var index = 0; index < 10; index++)
          'extension$index': List.filled(7000, 'x').join(),
      };

      await expectLater(
        localManager.set(largeKey, oversized),
        throwsArgumentError,
      );
      expect(localManager.get(largeKey), isEmpty);
      expect(localManager.status.isDirty, isFalse);
    },
  );
}
