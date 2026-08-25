import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/app/app_router.dart';
import 'package:mg_read/app/app_fatal_error_dialog_host.dart';
import 'package:mg_read/app/app_fatal_error_reporter.dart';
import 'package:mg_read/app/app_runtime_fatal_error_observer.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/app/app_theme_mode_scope.dart';
import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';
import 'package:mg_read/shared/presentation/widgets/app_back_navigation_scope.dart';
import 'package:mg_read/shared/presentation/widgets/app_bottom_navigation.dart';

/// The root widget for the MgRead host application.
class MgReadApp extends ConsumerStatefulWidget {
  /// Creates the application shell.
  const MgReadApp({super.key});

  @override
  ConsumerState<MgReadApp> createState() => _MgReadAppState();
}

class _MgReadAppState extends ConsumerState<MgReadApp> {
  @override
  void initState() {
    super.initState();
    // Subscribe before warmup so a Runtime startup failure and later Node
    // lifecycle diagnostics both reach the same root-level fatal boundary.
    ref.read(runtimeFatalErrorObserverProvider);
    // Let the first frame render before warming the process-scoped Runtime.
    // Every feature then joins this one global startup Future instead of
    // making its first Runtime request when the user opens that feature.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_warmPluginRuntime());
    });
  }

  Future<void> _warmPluginRuntime() async {
    try {
      await ref.read(pluginRuntimeConnectionProvider.future);
      await ref.read(availablePluginSourcesProvider.future);
    } on Object catch (error, stackTrace) {
      // The provider preserves the stable failure for feature UI to render.
      // Its application-layer span already records the failure safely.
      final observer = ref.read(runtimeFatalErrorObserverProvider);
      observer.observeLatestDiagnostics();
      if (!observer.hasObservedFatal) {
        ref
            .read(fatalErrorReporterProvider)
            .reportFatalRuntimeFailure(AppError.fromUnknown(error), stackTrace);
      }
    }
  }

  void _toggleTheme(Brightness currentBrightness) {
    // Kept as a narrow no-op so callers can remain unchanged while the
    // temporary light-only product mode is active.
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(appRouterProvider);
    return MaterialApp.router(
      title: 'MgRead',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      themeMode: ThemeMode.light,
      routerConfig: router,
      builder: (BuildContext context, Widget? child) {
        return AppFatalErrorDialogHost(
          reporter: ref.watch(fatalErrorReporterProvider),
          child: AppBottomNavigationMotionScope(
            child: AppBackNavigationScope(
              onBackRequested: popApplicationRoute,
              child: AppThemeModeScope(
                themeMode: ThemeMode.light,
                onToggleTheme: _toggleTheme,
                child: child ?? const SizedBox.shrink(),
              ),
            ),
          ),
        );
      },
    );
  }
}
