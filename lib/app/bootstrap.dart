import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'package:mg_read/app/app.dart';
import 'package:mg_read/app/app_settings_lifecycle.dart';
import 'package:mg_read/core/persistence/persistence.dart';
import 'package:mg_read/core/settings/settings.dart';

typedef SettingsDataRootResolver = Future<Directory> Function();
typedef MgReadAppRunner = void Function(Widget app);

/// Starts the Flutter host composition root.
///
/// This boundary owns framework initialization and the application ProviderScope.
/// Settings are opened on their background SQLite/JSON executors and fully
/// initialized before the explicitly overridden ProviderScope is mounted.
/// This boundary never starts the Node Runtime.
Future<void> bootstrapMgReadApp({
  AppSettingsManager? settingsManager,
  SettingsDataRootResolver dataRootResolver = _defaultSettingsDataRoot,
  MgReadAppRunner appRunner = runApp,
  Widget child = const MgReadApp(),
}) async {
  WidgetsFlutterBinding.ensureInitialized();
  final manager =
      settingsManager ??
      AppSettingsManager(
        registry: AppSettingKeys.registry,
        storeFactory: () async => PersistentSettingsStore.open(
          dataRoot: await dataRootResolver(),
          scope: const ScopeKey(kind: 'app', id: 'primary'),
          registry: AppSettingKeys.registry,
        ),
      );
  await manager.initialize();
  appRunner(
    ProviderScope(
      overrides: [appSettingsProvider.overrideWithValue(manager)],
      child: AppSettingsLifecycleHost(manager: manager, child: child),
    ),
  );
}

Future<Directory> _defaultSettingsDataRoot() async {
  final support = await getApplicationSupportDirectory();
  return Directory('${support.path}${Platform.pathSeparator}persistence');
}
