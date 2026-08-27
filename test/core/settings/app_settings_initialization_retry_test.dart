import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/settings/settings.dart';

import 'settings_testkit.dart';

void main() {
  test('retries a transient first load failure with a fresh store', () async {
    final firstStore = FakeSettingsStore()..failLoads = true;
    final secondStore = FakeSettingsStore();
    var factoryCalls = 0;
    final manager = AppSettingsManager(
      storeFactory: () async {
        factoryCalls++;
        return factoryCalls == 1 ? firstStore : secondStore;
      },
      registry: settingsTestRegistry,
    );
    addTearDown(manager.close);

    await manager.initialize();
    expect(manager.state, SettingsState.failed);

    await manager.retryInitialization();

    expect(manager.state, SettingsState.ready);
    expect(factoryCalls, 2);
    expect(firstStore.loadCalls, 1);
    expect(firstStore.closeCalls, 1);
    expect(secondStore.loadCalls, 1);
  });

  test('coalesces concurrent retries into one reopen and load', () async {
    final firstStore = FakeSettingsStore()..failLoads = true;
    final secondStore = FakeSettingsStore()..loadGate = Completer<void>();
    var factoryCalls = 0;
    final manager = AppSettingsManager(
      storeFactory: () async {
        factoryCalls++;
        return factoryCalls == 1 ? firstStore : secondStore;
      },
      registry: settingsTestRegistry,
    );
    addTearDown(manager.close);

    await manager.initialize();
    final firstRetry = manager.retryInitialization();
    await waitUntil(() => factoryCalls == 2);
    final secondRetry = manager.retryInitialization();

    expect(identical(firstRetry, secondRetry), isTrue);
    expect(secondStore.loadCalls, 1);
    secondStore.loadGate!.complete();
    await Future.wait([firstRetry, secondRetry]);
    expect(manager.state, SettingsState.ready);
  });

  test('retry after ready is an idempotent no-op', () async {
    final store = FakeSettingsStore();
    final manager = AppSettingsManager(store: store, registry: settingsTestRegistry);
    addTearDown(manager.close);

    await manager.initialize();
    await manager.retryInitialization();

    expect(manager.state, SettingsState.ready);
    expect(store.loadCalls, 1);
    expect(store.closeCalls, 0);
  });

  test('close during retry closes a late factory store without loading it', () async {
    final firstStore = FakeSettingsStore()..failLoads = true;
    final factoryGate = Completer<SettingsStore>();
    final lateStore = FakeSettingsStore();
    var factoryCalls = 0;
    final manager = AppSettingsManager(
      storeFactory: () {
        factoryCalls++;
        return factoryCalls == 1 ? Future<SettingsStore>.value(firstStore) : factoryGate.future;
      },
      registry: settingsTestRegistry,
      policy: const SettingsPersistencePolicy(closeTimeout: Duration(seconds: 1)),
    );
    addTearDown(manager.close);

    await manager.initialize();
    final retry = manager.retryInitialization();
    await waitUntil(() => factoryCalls == 2);
    final closing = manager.close();
    expect(manager.state, SettingsState.closing);
    factoryGate.complete(lateStore);

    await retry;
    await closing;
    expect(manager.state, SettingsState.closed);
    expect(lateStore.loadCalls, 0);
    expect(lateStore.closeCalls, 1);
  });
}
