/// Foreground-triggered maintenance after the first usable local frame. Checks
/// are independently deduplicated by their owners. App updates bypass persisted
/// timing once per launch, then run every 30 minutes outside reader/player
/// sessions and active audio. Source updates download silently after ten idle
/// seconds and remain deferred until the next launch; no source prompts open.
/// App update prompts wait for an idle top-level route. The
/// widget owns and cancels its timer; navigation/audio exit releases due checks.
/// Update dialogs use the root navigator context because this maintenance
/// widget is mounted beside the router, outside its Navigator subtree.
library;

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app_navigation_activity.dart';
import 'app_router.dart';
import 'app_startup.dart';
import 'package:mg_read/features/app_update/application/github_apk_update.dart';
import 'package:mg_read/features/app_update/presentation/github_apk_update_prompt.dart';
import 'package:mg_read/features/library/application/library_catalog_refresh_coordinator.dart';
import 'package:mg_read/features/library/application/library_page_controller.dart';
import 'package:mg_read/features/media/application/source_audio_playback_service.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';
import 'package:mg_read/features/plugins/application/source_update_coordinator.dart';

class AppBackgroundTasks extends ConsumerStatefulWidget {
  const AppBackgroundTasks({super.key});
  @override
  ConsumerState<AppBackgroundTasks> createState() => _AppBackgroundTasksState();
}

class _AppBackgroundTasksState extends ConsumerState<AppBackgroundTasks> with WidgetsBindingObserver {
  late final AppNavigationActivity _navigation;
  bool _ready = false;
  bool _promptOpen = false;
  bool _installing = false;
  bool _startupApkCheckPending = true;
  bool _checkingApk = false;
  Timer? _apkCheckTimer;
  Timer? _sourceUpdateTimer;
  bool _checkingSources = false;
  GitHubApkRelease? _apk;
  GitHubApkRelease? _acceptedApk;
  final Set<String> _shown = {};
  bool get _foreground =>
      WidgetsBinding.instance.lifecycleState == null || WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  bool get _idle {
    final navigator = appRootNavigatorKey.currentState;
    if (navigator == null || navigator.canPop() || ref.read(sourceAudioPlaybackServiceProvider).isActive) return false;
    final path = ref.read(appRouterProvider).routerDelegate.currentConfiguration.uri.path;
    return {'/', '/discover', '/profile'}.contains(path);
  }

  bool get _canCheckApk {
    if (appRootNavigatorKey.currentState == null ||
        _navigation.hasContentSession ||
        ref.read(sourceAudioPlaybackServiceProvider).isActive) {
      return false;
    }
    final path = ref.read(appRouterProvider).routerDelegate.currentConfiguration.uri.path;
    return path != '/reader' && !path.startsWith('/reader/');
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _navigation = ref.read(appNavigationActivityProvider)..changes.addListener(_onNavigation);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final startup = ref.read(appStartupControllerProvider);
      await startup.waitForSuccessfulLibraryTerminalFrame();
      if (!mounted || startup.isClosed) return;
      _ready = true;
      _trigger();
    });
  }

  void _onNavigation() {
    if (!mounted) return;
    _scheduleSourceUpdates();
    if (appRootNavigatorKey.currentState?.canPop() == false) {
      _trigger();
    } else {
      _triggerAppUpdate();
    }
  }

  void _trigger() {
    if (!mounted || !_ready || !_foreground) return;
    _triggerAppUpdate();
    _scheduleSourceUpdates();
    unawaited(_refreshCatalog());
  }

  void _triggerAppUpdate() {
    unawaited(_checkApk().catchError((Object _) {}));
    unawaited(_flushPrompts());
  }

  Future<void> _checkApk() async {
    if (!mounted || !_ready || !_foreground || _checkingApk || _promptOpen || _installing || !_canCheckApk) return;
    _checkingApk = true;
    final force = _startupApkCheckPending;
    _startupApkCheckPending = false;
    try {
      final result = await ref.read(githubApkUpdateCoordinatorProvider).checkForUpdate(force: force);
      if (!mounted) return;
      if (result.status != UpdateCheckStatus.unsupported && (result.status != UpdateCheckStatus.skipped || _apkCheckTimer == null)) {
        _apkCheckTimer?.cancel();
        _apkCheckTimer = Timer(githubApkUpdateCheckInterval, () {
          _apkCheckTimer = null;
          _triggerAppUpdate();
        });
      }
      if (result.value != null) _apk = result.value;
      await _flushPrompts();
    } finally {
      _checkingApk = false;
    }
  }

  bool get _canUpdateSources =>
      mounted &&
      _ready &&
      _foreground &&
      _idle &&
      !_navigation.hasContentSession &&
      !_promptOpen &&
      !_installing &&
      !ref.read(pluginRuntimeSourceImportProvider).isImporting;

  void _scheduleSourceUpdates({Duration delay = const Duration(seconds: 10)}) {
    _sourceUpdateTimer?.cancel();
    _sourceUpdateTimer = null;
    if (!_canUpdateSources || _checkingSources) return;
    _sourceUpdateTimer = Timer(delay, () => unawaited(_checkSources()));
  }

  Future<void> _checkSources() async {
    if (!_canUpdateSources || _checkingSources) return;
    _checkingSources = true;
    try {
      await ref.read(sourceUpdateCoordinatorProvider).prepareAutomaticUpdates(mayContinue: () => _canUpdateSources);
    } on Object {
      // Maintenance never interrupts the foreground route.
    } finally {
      _checkingSources = false;
      if (mounted) _scheduleSourceUpdates(delay: const Duration(minutes: 1));
    }
  }

  Future<void> _refreshCatalog() async {
    try {
      final coordinator = ref.read(libraryCatalogRefreshCoordinatorProvider);
      final overview = ref.read(libraryPageControllerProvider).overview;
      if (coordinator == null || overview == null) return;
      await coordinator.maybeRefresh(
        bookIds: overview.items.map((item) => item.id),
        onChanged: (ids) async {
          if (!mounted) return;
          ref.read(libraryCatalogChangeProvider.notifier).publish(ids);
          await ref.read(libraryPageControllerProvider.notifier).silentRefresh();
        },
      );
    } on Object {
      /* Retained shelf data remains usable on maintenance failure. */
    }
  }

  Future<void> _flushPrompts() async {
    if (!mounted || !_ready || !_foreground || _promptOpen || _installing) return;
    final navigator = appRootNavigatorKey.currentState;
    if (navigator == null || !_idle) return;
    final dialogContext = navigator.context;
    _promptOpen = true;
    try {
      final apk = _apk;
      if (apk != null) {
        _apk = null;
        if (_shown.add('apk:${apk.tag}')) {
          if (await showGitHubApkUpdatePrompt(dialogContext, apk) == true && mounted) {
            _acceptedApk = apk;
            await _installAcceptedApk();
          }
        }
        return;
      }
    } finally {
      _promptOpen = false;
      if (mounted && _apk != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_flushPrompts());
        });
      }
    }
  }

  Future<void> _installAcceptedApk() async {
    final apk = _acceptedApk;
    final dialogContext = appRootNavigatorKey.currentContext;
    if (apk == null || _installing || !mounted || dialogContext == null) return;
    _installing = true;
    try {
      await showGitHubApkUpdateInstallProgress(
        dialogContext,
        (onProgress) => ref.read(githubApkUpdateCoordinatorProvider).install(apk, onProgress: onProgress),
      );
      _acceptedApk = null;
    } on Object catch (error) {
      if (!error.toString().contains('app_update_install_permission_required')) _acceptedApk = null;
    } finally {
      _installing = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_acceptedApk != null) unawaited(_installAcceptedApk());
      _trigger();
    }
  }

  @override
  void dispose() {
    _apkCheckTimer?.cancel();
    _sourceUpdateTimer?.cancel();
    _navigation.changes.removeListener(_onNavigation);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(sourceAudioPlaybackServiceProvider, (_, next) {
      _scheduleSourceUpdates();
      if (!next.isActive) _triggerAppUpdate();
    });
    return const SizedBox.shrink();
  }
}
