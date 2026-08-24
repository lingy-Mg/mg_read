import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/discovery/application/search_history_store.dart';

import '../../../core/settings/settings_testkit.dart';

void main() {
  test(
    'search history survives manager reopen through the app settings store',
    () async {
      final store = FakeSettingsStore();
      final firstManager = AppSettingsManager(
        store: store,
        registry: AppSettingKeys.registry,
        policy: const SettingsPersistencePolicy(debounce: Duration.zero),
      );
      await firstManager.initialize();
      addTearDown(firstManager.close);

      final firstHistory = AppSettingsSearchHistoryStore(firstManager);
      await firstHistory.save(const <String>['诡秘之主', '大道朝天']);
      await firstManager.flush();

      final secondManager = AppSettingsManager(
        store: store,
        registry: AppSettingKeys.registry,
      );
      await secondManager.initialize();
      addTearDown(secondManager.close);

      expect(
        await AppSettingsSearchHistoryStore(secondManager).load(),
        <String>['诡秘之主', '大道朝天'],
      );
    },
  );

  test(
    'save updates memory before the background persistence completes',
    () async {
      final writeGate = Completer<void>();
      final store = FakeSettingsStore()..writeGate = writeGate;
      final manager = AppSettingsManager(
        store: store,
        registry: AppSettingKeys.registry,
        policy: const SettingsPersistencePolicy(debounce: Duration.zero),
      );
      await manager.initialize();
      addTearDown(manager.close);

      final save = AppSettingsSearchHistoryStore(
        manager,
      ).save(const <String>['诡秘之主']);

      expect(manager.get(AppSettingKeys.searchHistory), <String>['诡秘之主']);
      expect(store.writeCalls, 0);
      writeGate.complete();
      await save;
      await manager.flush();
    },
  );
}
