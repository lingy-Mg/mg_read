/// Foreground-triggered maintenance after the first usable local frame. Checks
/// are independently deduplicated by their owners; prompts wait for an idle
/// top-level route and never interrupt a reader, player, or another dialog.
library;

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app_navigation_activity.dart';
import 'app_router.dart';
import 'app_startup.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/app_update/application/github_apk_update.dart';
import 'package:mg_read/features/app_update/presentation/github_apk_update_prompt.dart';
import 'package:mg_read/features/library/application/library_catalog_refresh_coordinator.dart';
import 'package:mg_read/features/library/application/library_page_controller.dart';
import 'package:mg_read/features/media/application/source_audio_playback_service.dart';
import 'package:mg_read/features/plugins/application/source_collection_import.dart';
import 'package:mg_read/features/plugins/application/source_update_coordinator.dart';
import 'package:mg_read/features/plugins/presentation/source_update_actions.dart';

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
  GitHubApkRelease? _apk;
  GitHubApkRelease? _acceptedApk;
  List<SourceCollectionCandidate>? _sources;
  final Set<String> _shown = {};
  bool get _foreground =>
      WidgetsBinding.instance.lifecycleState == null || WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

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
    if (appRootNavigatorKey.currentState?.canPop() == false) _trigger();
  }

  void _trigger() {
    if (!mounted || !_ready || !_foreground) return;
    unawaited(_checkApk().catchError((Object _) {}));
    unawaited(_checkSources().catchError((Object _) {}));
    unawaited(_refreshCatalog());
    unawaited(_flushPrompts());
  }

  Future<void> _checkApk() async {
    final result = await ref.read(githubApkUpdateCoordinatorProvider).checkForUpdate();
    if (!mounted) return;
    if (result.value != null) _apk = result.value;
    await _flushPrompts();
  }

  Future<void> _checkSources() async {
    final result = await ref.read(sourceUpdateCoordinatorProvider).check();
    if (!mounted) return;
    if (result.status == UpdateCheckStatus.available) _sources = result.value;
    await _flushPrompts();
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
    final path = ref.read(appRouterProvider).routerDelegate.currentConfiguration.uri.path;
    if (navigator == null ||
        navigator.canPop() ||
        !{'/', '/discover', '/profile'}.contains(path) ||
        ref.read(sourceAudioPlaybackServiceProvider).isActive) {
      return;
    }
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
      final settings = ref.read(appSettingsProvider);
      final sources = _sources;
      _sources = null;
      if (sources != null &&
          settings.supports(AppSettingKeys.sourceAutoUpdateCheckEnabled) &&
          settings.get(AppSettingKeys.sourceAutoUpdateCheckEnabled)) {
        _sources = null;
        final fresh = sources.where((item) => !_shown.contains('source:${item.plugin.id}:${item.plugin.version}')).toList();
        if (fresh.isNotEmpty) {
          _shown.addAll(fresh.map((item) => 'source:${item.plugin.id}:${item.plugin.version}'));
          await offerSourceUpdates(dialogContext, ref, fresh);
        }
      }
    } finally {
      _promptOpen = false;
      if (mounted && (_apk != null || _sources != null)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_flushPrompts());
        });
      }
    }
  }

  Future<void> _installAcceptedApk() async {
    final apk = _acceptedApk;
    if (apk == null || _installing || !mounted) return;
    _installing = true;
    try {
      await showGitHubApkUpdateInstallProgress(
        context,
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
    _navigation.changes.removeListener(_onNavigation);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(sourceAudioPlaybackServiceProvider, (_, next) {
      if (!next.isActive) unawaited(_flushPrompts());
    });
    return const SizedBox.shrink();
  }
}
