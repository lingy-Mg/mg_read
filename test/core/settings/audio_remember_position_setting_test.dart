/// Audio resume preference defaults and durable settings round trip.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/settings/settings.dart';

import 'settings_testkit.dart';

void main() {
  test('older settings default to resume; the disabled choice survives reopening', () async {
    final store = FakeSettingsStore();
    final first = AppSettingsManager(store: store, registry: AppSettingKeys.registry);
    await first.initialize();
    expect(first.get(AppSettingKeys.audioRememberPosition), isTrue);
    await first.set(AppSettingKeys.audioRememberPosition, false);
    await first.close();

    final second = AppSettingsManager(store: store, registry: AppSettingKeys.registry);
    await second.initialize();
    addTearDown(second.close);
    expect(second.get(AppSettingKeys.audioRememberPosition), isFalse);
    expect(second.get(AppSettingKeys.audioKeepScreenOn), isTrue);
    expect(second.get(AppSettingKeys.audioExitBehavior), 'ask');
  });
}
