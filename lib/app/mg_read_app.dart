/// 应用路由、主题和后台服务的组合根。
/// 首屏遮罩由 AppStartupGate 持有；Runtime、更新和设备同步在首屏绘制后启动。
/// 异步完成后必须检查 mounted；全局订阅随根组件销毁而取消。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_router.dart';
import 'package:mg_read/app/app_startup.dart';
import 'package:mg_read/app/app_startup_gate.dart';
import 'package:mg_read/app/app_fatal_error_dialog_host.dart';
import 'package:mg_read/app/app_fatal_error_reporter.dart';
import 'package:mg_read/app/app_runtime_fatal_error_observer.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/app/app_theme_mode_scope.dart';
import 'package:mg_read/app/data_source_system_error_dialog_host.dart';
import 'package:mg_read/app/data_source_system_error_reporter.dart';
import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'app_background_tasks.dart';
import 'package:mg_read/features/lan_sync/application/device_sync_controller.dart';
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

class _MgReadAppState extends ConsumerState<MgReadApp> with WidgetsBindingObserver {
  Timer? _developmentSyncDebounce;
  StreamSubscription<RuntimeInitializationProgress>? _runtimeInitializationSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Subscribe before warmup so a Runtime startup failure and later Node
    // lifecycle diagnostics both reach the same root-level fatal boundary.
    ref.read(runtimeFatalErrorObserverProvider);
    // Let the first usable library frame render before warming the process-
    // scoped Runtime. Every feature joins this one global startup Future.
    final startup = ref.read(appStartupControllerProvider);
    _runtimeInitializationSubscription = ref.read(pluginRuntimeGatewayProvider).initialization.listen((progress) {
      final stage = switch (progress.stage) {
        RuntimeInitializationStage.pluginInboxScanned => 'runtimeInbox',
        RuntimeInitializationStage.developmentPluginsScanned => 'runtimeDevelopmentScan',
        RuntimeInitializationStage.installedPluginsSnapshotted => 'runtimeInstalledSnapshot',
        RuntimeInitializationStage.pendingPluginsActivated => 'runtimePendingActivation',
        RuntimeInitializationStage.serviceReady => 'runtimeServiceReady',
        _ => null,
      };
      if (stage == null || startup.isClosed) return;
      startup.recordStage(
        stage,
        resultState: 'complete',
        phaseDurationMicros: progress.durationMicros,
        itemCount: progress.itemCount,
        catalogState: progress.catalogState,
      );
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_warmAfterLibrary(startup));
    });
  }

  Future<void> _warmAfterLibrary(AppStartupController startup) async {
    await startup.waitForSuccessfulLibraryTerminalFrame();
    if (!mounted || startup.isClosed) return;
    // Present the uncovered route before scheduling background startup work.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || startup.isClosed) return;
    try {
      final runtimeReady = await _warmPluginRuntime();
      startup.recordStage('runtimeReady', resultState: runtimeReady ? 'ready' : 'failure');
      final lifecycle = WidgetsBinding.instance.lifecycleState;
      if (mounted && (lifecycle == null || lifecycle == AppLifecycleState.resumed)) {
        await ref.read(deviceSyncControllerProvider.notifier).start();
        startup.recordStage('deviceSyncReady', resultState: ref.read(deviceSyncControllerProvider).started ? 'ready' : 'failure');
      }
    } finally {
      // Retention is maintenance, not startup; it must follow Runtime warmup.
      final maintenanceResult = await startup.runDeferredDiagnosticsMaintenance();
      startup.recordStage('maintenanceComplete', resultState: maintenanceResult);
    }
  }

  Future<bool> _warmPluginRuntime() async {
    try {
      final connection = await ref.read(pluginRuntimeConnectionProvider.future);
      if (!mounted) return false;
      ref
          .read(dataSourceSystemErrorReporterProvider)
          .reportQuarantinedSources(quarantinedCount: connection.startupRecovery.quarantinedCount);
      await ref.read(availablePluginSourcesProvider.future);
      return true;
    } on Object catch (error, stackTrace) {
      if (!mounted) return false;
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
    final AppSettingsManager settings = ref.read(appSettingsProvider);
    unawaited(settings.set(AppSettingKeys.themeMode, currentBrightness == Brightness.dark ? 'light' : 'dark'));
  }

  void _handleDevelopmentChanges(DevelopmentPluginChangeBatch batch) {
    final successful = batch.changes.where((change) => !change.isFailure).toList(growable: false);
    if (successful.isNotEmpty) {
      final pluginIds = successful.map((change) => change.pluginId).whereType<String>().toSet();
      ref.read(pluginRuntimeCatalogChangeProvider.notifier).publish(pluginIds: pluginIds.length == successful.length ? pluginIds : null);
      _developmentSyncDebounce?.cancel();
      _developmentSyncDebounce = Timer(const Duration(seconds: 2), () {
        _developmentSyncDebounce = null;
        if (mounted) unawaited(_syncDevelopmentChanges());
      });
    }
    for (final change in batch.changes.where((change) => change.isFailure)) {
      ref
          .read(dataSourceSystemErrorReporterProvider)
          .reportDevelopmentReloadFailure(
            errorCode: change.kind == DevelopmentPluginChangeKind.buildFailed ? 'plugin_build_failed' : 'plugin_load_failed',
            pluginId: change.pluginId,
            pluginName: change.pluginName,
            buildOutput: change.buildOutput,
          );
    }
  }

  Future<void> _syncDevelopmentChanges() async {
    try {
      await ref.read(availablePluginSourcesProvider.future);
      await ref.read(deviceSyncControllerProvider.notifier).syncAvailablePeers(pushChanges: true);
    } on Object {
      // 自动同步会按退避与低频校准重试；开发热更新本身保持成功。
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        if (ref.read(appStartupControllerProvider).isInteractive) {
          unawaited(ref.read(deviceSyncControllerProvider.notifier).start());
        }
        break;
      case AppLifecycleState.hidden || AppLifecycleState.paused || AppLifecycleState.detached:
        unawaited(ref.read(deviceSyncControllerProvider.notifier).stop());
        break;
      case AppLifecycleState.inactive:
        break;
    }
  }

  @override
  void dispose() {
    _developmentSyncDebounce?.cancel();
    unawaited(_runtimeInitializationSubscription?.cancel());
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // SettingsManager keeps a stable identity, so watch its status stream to
    // rebuild the root when an appearance setting changes.
    ref.watch(appSettingsStatusProvider);
    final AppSettingsManager settings = ref.watch(appSettingsProvider);
    final AppThemeColor themeColor = AppThemeColor.fromId(settings.get(AppSettingKeys.themeColor));
    final AppDarkThemeColor darkThemeColor = AppDarkThemeColor.fromId(settings.get(AppSettingKeys.darkThemeColor));
    final ThemeMode themeMode = switch (settings.get(AppSettingKeys.themeMode)) {
      'dark' => ThemeMode.dark,
      'light' => ThemeMode.light,
      _ => ThemeMode.system,
    };
    ref.listen(pluginRuntimeDevelopmentChangesProvider, (_, next) {
      next.whenData(_handleDevelopmentChanges);
    });
    final router = ref.watch(appRouterProvider);
    return MaterialApp.router(
      title: 'MgRead',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(color: themeColor),
      darkTheme: AppTheme.dark(color: darkThemeColor),
      themeMode: themeMode,
      routerConfig: router,
      builder: (BuildContext context, Widget? child) {
        final pageBackground = AppThemeTokens.of(context).pageBackground;
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: (Theme.of(context).brightness == Brightness.dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark).copyWith(
            // Android 15 draws the status bar edge-to-edge. Declare its
            // contrast here so a platform default color cannot flash above a
            // loading destination before that page supplies its own chrome.
            statusBarColor: Colors.transparent,
            systemNavigationBarColor: pageBackground,
            systemNavigationBarDividerColor: pageBackground,
          ),
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              AppStartupGate(
                child: DataSourceSystemErrorDialogHost(
                  reporter: ref.watch(dataSourceSystemErrorReporterProvider),
                  child: AppFatalErrorDialogHost(
                    reporter: ref.watch(fatalErrorReporterProvider),
                    child: AppBottomNavigationMotionScope(
                      child: AppBackNavigationScope(
                        onBackRequested: popApplicationRoute,
                        child: AppThemeModeScope(
                          themeMode: themeMode,
                          onToggleTheme: _toggleTheme,
                          child: child ?? const SizedBox.shrink(),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const AppBackgroundTasks(),
              const ChapterCacheTaskBar(),
              SourceAudioPlaybackNavigator(backButtonDispatcher: router.backButtonDispatcher),
            ],
          ),
        );
      },
    );
  }
}
