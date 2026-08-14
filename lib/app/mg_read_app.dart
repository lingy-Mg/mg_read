import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/app/app_router.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/app/app_theme_mode_scope.dart';
import 'package:mg_read/core/settings/settings.dart';

/// The root widget for the MgRead host application.
class MgReadApp extends ConsumerStatefulWidget {
  /// Creates the application shell.
  const MgReadApp({super.key});

  @override
  ConsumerState<MgReadApp> createState() => _MgReadAppState();
}

class _MgReadAppState extends ConsumerState<MgReadApp> {
  late final AppSettingsManager _settings;
  late ThemeMode _themeMode;
  StreamSubscription<SettingsSnapshot>? _settingsChanges;

  @override
  void initState() {
    super.initState();
    _settings = ref.read(appSettingsProvider);
    _themeMode = _themeModeFromSetting(_settings.get(AppSettingKeys.themeMode));
    _settingsChanges = _settings.changes.listen((SettingsSnapshot snapshot) {
      final ThemeMode nextMode = _themeModeFromSetting(
        snapshot.get(AppSettingKeys.themeMode),
      );
      if (mounted && nextMode != _themeMode) {
        setState(() {
          _themeMode = nextMode;
        });
      }
    });
  }

  @override
  void dispose() {
    _settingsChanges?.cancel();
    super.dispose();
  }

  void _toggleTheme(Brightness currentBrightness) {
    final ThemeMode nextMode = currentBrightness == Brightness.dark
        ? ThemeMode.light
        : ThemeMode.dark;
    unawaited(_settings.set(AppSettingKeys.themeMode, nextMode.name));
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'MgRead',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: _themeMode,
      routerConfig: ref.watch(appRouterProvider),
      builder: (BuildContext context, Widget? child) {
        return AppThemeModeScope(
          themeMode: _themeMode,
          onToggleTheme: _toggleTheme,
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
  }
}

ThemeMode _themeModeFromSetting(String value) => switch (value) {
  'light' => ThemeMode.light,
  'dark' => ThemeMode.dark,
  _ => ThemeMode.system,
};
