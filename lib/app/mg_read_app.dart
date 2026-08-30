import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_router.dart';
import 'package:mg_read/app/app_startup.dart';
import 'package:mg_read/app/app_fatal_error_dialog_host.dart';
import 'package:mg_read/app/app_fatal_error_reporter.dart';
import 'package:mg_read/app/app_runtime_fatal_error_observer.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/app/app_theme_mode_scope.dart';
import 'package:mg_read/app/data_source_system_error_dialog_host.dart';
import 'package:mg_read/app/data_source_system_error_reporter.dart';
import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/library/presentation/library_home_view_data.dart';
import 'package:mg_read/features/library/application/library_page_controller.dart';
import 'package:mg_read/features/library/presentation/widgets/library_home_shell.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';
import 'package:mg_read/features/media/presentation/source_audio_playback_host.dart';
import 'package:mg_read/features/reader/presentation/chapter_cache_task_bar.dart';
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
    // Let the first usable library frame render before warming the process-
    // scoped Runtime. Every feature joins this one global startup Future.
    final startup = ref.read(appStartupControllerProvider);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_warmAfterLibrary(startup));
    });
  }

  Future<void> _warmAfterLibrary(AppStartupController startup) async {
    await startup.waitForSuccessfulLibraryTerminalFrame();
    if (!mounted || startup.isClosed) return;
    try {
      final runtimeReady = await _warmPluginRuntime();
      startup.recordStage('runtimeReady', resultState: runtimeReady ? 'ready' : 'failure');
    } finally {
      // Retention is maintenance, not startup; it must follow Runtime warmup.
      final maintenanceResult = await startup.runDeferredDiagnosticsMaintenance();
      startup.recordStage('maintenanceComplete', resultState: maintenanceResult);
    }
  }

  Future<bool> _warmPluginRuntime() async {
    try {
      final connection = await ref.read(pluginRuntimeConnectionProvider.future);
      ref
          .read(dataSourceSystemErrorReporterProvider)
          .reportQuarantinedSources(quarantinedCount: connection.startupRecovery.quarantinedCount);
      await ref.read(availablePluginSourcesProvider.future);
      return true;
    } on Object catch (error, stackTrace) {
      // The provider preserves the stable failure for feature UI to render.
      // Its application-layer span already records the failure safely.
      final observer = ref.read(runtimeFatalErrorObserverProvider);
      observer.observeLatestDiagnostics();
      if (!observer.hasObservedFatal) {
        ref.read(fatalErrorReporterProvider).reportFatalRuntimeFailure(AppError.fromUnknown(error), stackTrace, originalError: error);
      }
      return false;
    }
  }

  void _toggleTheme(Brightness currentBrightness) {
    // Kept as a narrow no-op so callers can remain unchanged while the
    // temporary light-only product mode is active.
  }

  void _handleDevelopmentChanges(DevelopmentPluginChangeBatch batch) {
    final successful = batch.changes.any((change) => !change.isFailure);
    if (successful) {
      ref.invalidate(pluginRuntimeConnectionProvider);
      ref.invalidate(pluginRuntimeStatusProvider);
      ref.invalidate(availablePluginSourcesProvider);
    }
    for (final change in batch.changes.where((change) => change.isFailure)) {
      ref
          .read(dataSourceSystemErrorReporterProvider)
          .reportDevelopmentReloadFailure(
            errorCode: change.kind == DevelopmentPluginChangeKind.buildFailed ? 'plugin_build_failed' : 'plugin_load_failed',
          );
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(pluginRuntimeDevelopmentChangesProvider, (_, next) {
      next.whenData(_handleDevelopmentChanges);
    });
    final router = ref.watch(appRouterProvider);
    return MaterialApp.router(
      title: 'MgRead',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      themeMode: ThemeMode.light,
      routerConfig: router,
      builder: (BuildContext context, Widget? child) {
        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            _AppStartupGate(
              child: DataSourceSystemErrorDialogHost(
                reporter: ref.watch(dataSourceSystemErrorReporterProvider),
                child: AppFatalErrorDialogHost(
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
                ),
              ),
            ),
            const ChapterCacheTaskBar(),
            SourceAudioPlaybackNavigator(backButtonDispatcher: router.backButtonDispatcher),
          ],
        );
      },
    );
  }
}

final class _AppStartupGate extends ConsumerStatefulWidget {
  const _AppStartupGate({required this.child});

  final Widget child;

  @override
  ConsumerState<_AppStartupGate> createState() => _AppStartupGateState();
}

final class _AppStartupGateState extends ConsumerState<_AppStartupGate> {
  AppStartupStatus? _lastStatus;
  bool _shellFrameScheduled = false;
  bool _loadingArmed = false;
  bool _failureSignalScheduled = false;

  @override
  Widget build(BuildContext context) {
    final startup = ref.watch(appStartupControllerProvider);
    return ValueListenableBuilder<AppStartupState>(
      valueListenable: startup,
      builder: (context, state, child) => _buildForState(context, startup, state),
    );
  }

  Widget _buildForState(BuildContext context, AppStartupController startup, AppStartupState state) {
    final previous = _lastStatus;
    _lastStatus = state.status;
    if (state.isBooting && previous == AppStartupStatus.retryableFailure) {
      _loadingArmed = false;
      _failureSignalScheduled = false;
      _shellFrameScheduled = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref.invalidate(libraryPageControllerProvider);
        ref.invalidate(privateLibraryPageControllerProvider);
      });
    }
    if (!_shellFrameScheduled) {
      _shellFrameScheduled = true;
      final firstFrameState = state.status;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        startup.recordShellFirstFrame(resultState: firstFrameState.name);
        if (!startup.isInteractive && !_loadingArmed) {
          setState(() {
            _loadingArmed = true;
          });
        }
      });
    }
    if (startup.isInteractive) {
      _loadingArmed = false;
      return widget.child;
    }
    if (state.isBooting || state.isReady) {
      return Stack(
        fit: StackFit.expand,
        children: <Widget>[
          IgnorePointer(
            child: ExcludeSemantics(child: Offstage(child: widget.child)),
          ),
          IgnorePointer(
            child: ExcludeSemantics(
              child: Overlay(
                initialEntries: <OverlayEntry>[
                  OverlayEntry(
                    builder: (context) => LibraryHomeShell(
                      data: LibraryHomeViewData.empty(),
                      onRefresh: () async {},
                      isRefreshing: false,
                      showLoading: _loadingArmed,
                      callbacks: const LibraryHomeCallbacks(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }
    // Startup failure deliberately has a fixed, safe message. Raw exception
    // text and paths never cross this boundary.
    if (!_failureSignalScheduled) {
      _failureSignalScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          startup.recordStage('libraryFirstUsableFrame', resultState: 'failure');
        }
      });
    }
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Text('启动失败'),
            const SizedBox(height: 8),
            const Text('startup_failed'),
            const SizedBox(height: 8),
            Text('诊断代码：${state.errorCode ?? 'startup_failed'}'),
            const SizedBox(height: 16),
            FilledButton(key: const Key('startup-retry'), onPressed: () => startup.retry(), child: const Text('重试')),
            const SizedBox(height: 8),
            TextButton(
              key: const Key('startup-diagnostics'),
              onPressed: () {
                const DiagnosticsRoute().go(context);
              },
              child: const Text('查看诊断'),
            ),
          ],
        ),
      ),
    );
  }
}
