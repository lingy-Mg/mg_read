import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/discovery/application/discovery_source_selection_store.dart';

import '../../../core/settings/settings_testkit.dart';

void main() {
  test('discovery source selection survives manager reopen', () async {
    final store = FakeSettingsStore();
    final firstManager = AppSettingsManager(
      store: store,
      registry: AppSettingKeys.registry,
      policy: const SettingsPersistencePolicy(debounce: Duration.zero),
    );
    await firstManager.initialize();
    addTearDown(firstManager.close);

    final firstSelection = AppSettingsDiscoverySourceSelectionStore(
      firstManager,
    );
    await firstSelection.save('org.mgread.aisishuwu');
    await firstManager.flush();

    final secondManager = AppSettingsManager(
      store: store,
      registry: AppSettingKeys.registry,
    );
    await secondManager.initialize();
    addTearDown(secondManager.close);

    expect(
      await AppSettingsDiscoverySourceSelectionStore(secondManager).load(),
      'org.mgread.aisishuwu',
    );
  });
}
