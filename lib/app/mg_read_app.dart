import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/app_update/application/github_apk_update.dart';
import 'package:mg_read/features/app_update/presentation/github_apk_update_prompt.dart';
import 'package:mg_read/features/lan_sync/application/device_sync_controller.dart';
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

class _MgReadAppState extends ConsumerState<MgReadApp> with WidgetsBindingObserver {
  Timer? _developmentSyncDebounce;
  StreamSubscription<RuntimeInitializationProgress>? _runtimeInitializationSubscription;
  GitHubApkRelease? _pendingApkUpdate;
  bool _apkUpdatePromptOpen = false;

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
      unawaited(_checkForApkUpdate());
    });
  }

  Future<void> _checkForApkUpdate() async {
    try {
      final release = await ref.read(githubApkUpdateCoordinatorProvider).checkForUpdate();
      if (mounted && release != null) await _showApkUpdatePrompt(release);
    } on Object {
      // Update discovery is best effort and must not affect startup.
    }
  }

  Future<void> _showApkUpdatePrompt(GitHubApkRelease release) async {
    if (_apkUpdatePromptOpen || !mounted) return;
    final navigator = appRootNavigatorKey.currentState;
    if (navigator == null) return;
    _apkUpdatePromptOpen = true;
    try {
      final accepted = await showGitHubApkUpdatePrompt(navigator.context, release);
      if (accepted == true && mounted) {
        _pendingApkUpdate = release;
        await _installPendingApkUpdate();
      }
    } on Object {
      // Dialog failures are also best effort and stay out of the user's way.
    } finally {
      _apkUpdatePromptOpen = false;
    }
  }

  Future<void> _installPendingApkUpdate() async {
    final release = _pendingApkUpdate;
    if (release == null || !mounted) return;
    try {
      await showGitHubApkUpdateInstallProgress(
        context,
        (onProgress) => ref.read(githubApkUpdateCoordinatorProvider).install(release, onProgress: onProgress),
      );
      _pendingApkUpdate = null;
    } on Object catch (error) {
      // Android opens its per-app "install unknown apps" settings page when
      // required. Keep this offer so it can resume automatically on return.
      if (!error.toString().contains('app_update_install_permission_required')) _pendingApkUpdate = null;
    }
  }

  Future<void> _warmAfterLibrary(AppStartupController startup) async {
    await startup.waitForSuccessfulLibraryTerminalFrame();
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
        unawaited(ref.read(deviceSyncControllerProvider.notifier).start());
        if (_pendingApkUpdate != null) unawaited(_installPendingApkUpdate());
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
              _AppStartupGate(
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
              const ChapterCacheTaskBar(),
              SourceAudioPlaybackNavigator(backButtonDispatcher: router.backButtonDispatcher),
            ],
          ),
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
    // Startup failure uses one fixed message at this boundary.
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
