import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/diagnostics/application/diagnostics_capture_preference_store.dart';

import '../../../core/settings/settings_testkit.dart';

void main() {
  test('diagnostics and realtime detail preferences persist without diagnostics service', () async {
    final store = FakeSettingsStore();
    final firstManager = AppSettingsManager(
      store: store,
      registry: AppSettingKeys.registry,
      policy: const SettingsPersistencePolicy(debounce: Duration.zero),
    );
    await firstManager.initialize();
    addTearDown(firstManager.close);

    final firstPreference = AppSettingsDiagnosticsCapturePreferenceStore(firstManager);
    expect(await firstPreference.loadDiagnosticsEnabled(), isFalse);
    expect(await firstPreference.loadRealtimeDetailsEnabled(), isFalse);

    await firstPreference.saveDiagnosticsEnabled(true);
    await firstPreference.saveRealtimeDetailsEnabled(true);
    await firstManager.flush();

    final reopenedManager = AppSettingsManager(store: store, registry: AppSettingKeys.registry);
    await reopenedManager.initialize();
    addTearDown(reopenedManager.close);

    final reopenedPreference = AppSettingsDiagnosticsCapturePreferenceStore(reopenedManager);
    expect(await reopenedPreference.loadDiagnosticsEnabled(), isTrue);
    expect(await reopenedPreference.loadRealtimeDetailsEnabled(), isTrue);
  });
}
