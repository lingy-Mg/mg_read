import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/library/presentation/library_home_view_data.dart';

import '../../../core/settings/settings_testkit.dart';

void main() {
  test('home layout defaults to list and survives manager reopen', () async {
    final store = FakeSettingsStore();
    final firstManager = AppSettingsManager(
      store: store,
      registry: AppSettingKeys.registry,
      policy: const SettingsPersistencePolicy(debounce: Duration.zero),
    );
    await firstManager.initialize();
    addTearDown(firstManager.close);

    expect(LibraryHomeLayoutMode.fromSetting(firstManager.get(AppSettingKeys.homeLayoutMode)), LibraryHomeLayoutMode.list);

    await firstManager.set(AppSettingKeys.homeLayoutMode, 'card');
    await firstManager.flush();

    final secondManager = AppSettingsManager(store: store, registry: AppSettingKeys.registry);
    await secondManager.initialize();
    addTearDown(secondManager.close);

    expect(LibraryHomeLayoutMode.fromSetting(secondManager.get(AppSettingKeys.homeLayoutMode)), LibraryHomeLayoutMode.card);
  });

  test('invalid persisted layout falls back to list', () async {
    final store = FakeSettingsStore();
    store.documents[AppSettingKeys.appearanceDocument.kind] = SettingsDocument(
      id: AppSettingKeys.appearanceDocument.id,
      kind: AppSettingKeys.appearanceDocument.kind,
      values: const <String, Object?>{'appearance.homeLayoutMode': 'tiles'},
    );
    final manager = AppSettingsManager(store: store, registry: AppSettingKeys.registry);
    await manager.initialize();
    addTearDown(manager.close);

    expect(manager.get(AppSettingKeys.homeLayoutMode), 'list');
    expect(manager.status.documents[AppSettingKeys.appearanceDocument.kind]?.lastErrorCode, 'invalid_setting_value');
  });

  test('blurred cover book IDs survive manager reopen', () async {
    final store = FakeSettingsStore();
    final firstManager = AppSettingsManager(
      store: store,
      registry: AppSettingKeys.registry,
      policy: const SettingsPersistencePolicy(debounce: Duration.zero),
    );
    await firstManager.initialize();
    addTearDown(firstManager.close);

    await firstManager.set(AppSettingKeys.blurredCoverBookIds, <String>['book-b', 'book-a']);
    await firstManager.flush();

    final secondManager = AppSettingsManager(store: store, registry: AppSettingKeys.registry);
    await secondManager.initialize();
    addTearDown(secondManager.close);

    expect(secondManager.get(AppSettingKeys.blurredCoverBookIds), <String>['book-b', 'book-a']);
  });
}
