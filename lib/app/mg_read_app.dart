import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/app/app_strings.dart';
import 'package:mg_read/app/app_router.dart';
import 'package:mg_read/app/app_theme.dart';

/// The root widget for the MgRead host application.
class MgReadApp extends ConsumerWidget {
  /// Creates the application shell.
  const MgReadApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      title: AppStrings.applicationName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      routerConfig: ref.watch(appRouterProvider),
    );
  }
}
