import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mg_read/app/mg_read_app.dart';
import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/core/settings/settings.dart';

import '../core/settings/settings_testkit.dart';

/// Provides the initialized settings boundary required by [MgReadApp] tests.
Future<AppSettingsManager> createTestAppSettings({
  String themeMode = 'system',
}) async {
  final FakeSettingsStore store = FakeSettingsStore();
  if (themeMode != 'system') {
    store.documents[AppSettingKeys.appearanceDocument.kind] = SettingsDocument(
      id: AppSettingKeys.appearanceDocument.id,
      kind: AppSettingKeys.appearanceDocument.kind,
      values: <String, Object?>{AppSettingKeys.themeMode.id: themeMode},
      revision: 1,
    );
  }
  final AppSettingsManager settings = AppSettingsManager(
    store: store,
    registry: AppSettingKeys.registry,
  );
  await settings.initialize();
  return settings;
}

Widget testMgReadApp(
  AppSettingsManager settings, {
  DiagnosticsManager? diagnostics,
}) {
  return ProviderScope(
    overrides: [
      appSettingsProvider.overrideWithValue(settings),
      if (diagnostics != null)
        diagnosticsManagerProvider.overrideWithValue(diagnostics),
    ],
    child: const MgReadApp(),
  );
}
