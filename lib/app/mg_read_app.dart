import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/app/app_strings.dart';
import 'package:mg_read/app/app_router.dart';
import 'package:mg_read/app/app_theme.dart';

/// The root widget for the MgRead host application.
class MgReadApp extends ConsumerWidget {
  /// Creates the application shell.
  const MgReadApp({super.key, this.themeMode = ThemeMode.system});

  /// The active visual mode; settings persistence will provide this later.
  final ThemeMode themeMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      title: AppStrings.applicationName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeMode,
      routerConfig: ref.watch(appRouterProvider),
    );
  }
}
