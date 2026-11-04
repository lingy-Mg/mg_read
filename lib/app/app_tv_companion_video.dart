/// Companion handoff into the app's existing source-video player.
///
/// Responsibilities:
/// - Resolve a trusted source identity and prepare its exact episode off-route.
/// - Keep the old route visible while a bounded, mounted preview decodes.
///
/// Notes:
/// - The staged surface remains mounted in a small preview while the current
///   player remains visible, allowing native decoding to reach a real frame.
/// - The existing player package owns all backend resources and handoff state.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mg_read_video_player/mg_read_video_player.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_router.dart';
import 'package:mg_read/app/app_navigation_activity.dart';
import 'package:mg_read/app/app_startup.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/lan_sync/application/device_identity_store.dart';
import 'package:mg_read/features/media/application/source_audio_playback_service.dart';
import 'package:mg_read/features/media/application/source_video_data_source.dart';
import 'package:mg_read/features/media/application/source_video_player_launcher.dart';
import 'package:mg_read/features/media/application/source_video_playback_platform_controller.dart';
import 'package:mg_read/features/media/application/source_video_preferences.dart';
import 'package:mg_read/features/media/application/transient_source_video_playback_state_store.dart';
import 'package:mg_read/features/network_proxy/application/flutter_network_proxy_manager.dart';
import 'package:mg_read/features/network_proxy/application/network_proxy_settings.dart';
import 'package:mg_read/features/tv_companion/application/companion_command_engine.dart';
import 'package:mg_read/features/tv_companion/application/companion_media_host.dart';
import 'package:mg_read/features/tv_companion/domain/companion_command.dart';
import 'package:mg_read/features/tv_companion/domain/companion_models.dart';

/// Prepares and adopts an exact Companion source-video selection.
Future<void> launchCompanionSourceVideo(
  Ref ref,
  CompanionContentRef content,
  CompanionExecutionContext execution, {
  VideoPlaybackBackendFactory? backendFactory,
}) async {
  execution.ensureCurrent();
  final navigator = appRootNavigatorKey.currentState;
  if (navigator == null || !navigator.mounted) {
    throw const CompanionFailure('media_host_unavailable');
  }
  final container = ProviderScope.containerOf(navigator.context, listen: false);
  final gateway = container.read(sourceContentGatewayProvider);
  final sources = await _awaitWhileCurrent(gateway.listSources(), execution);
  final source = sources.where((value) => value.id == content.pluginId).firstOrNull;
  if (source == null || !source.contentKinds.contains(PluginContentKind.video)) {
    throw const CompanionFailure('video_source_unavailable');
  }
  if (content.pluginVersion != 'unknown' && content.pluginVersion != source.pluginVersion) {
    throw const CompanionFailure('source_version_mismatch');
  }
  final detail = await _awaitWhileCurrent(gateway.getDetail(pluginId: content.pluginId, id: content.contentId), execution);
  if (detail.pluginId != content.pluginId ||
      detail.summary.id != content.contentId ||
      detail.summary.contentKind != PluginContentKind.video) {
    throw const CompanionFailure('video_content_identity_mismatch');
  }
  final catalog = await _awaitWhileCurrent(gateway.getChapters(pluginId: content.pluginId, id: content.contentId), execution);
  if (catalog.pluginId != content.pluginId) {
    throw const CompanionFailure('video_catalog_identity_mismatch');
  }

  final libraryFuture = container.read(appStartupControllerProvider).contentLibrary;
  final library = await _awaitWhileCurrent(libraryFuture, execution);
  final shelfItem = await _findShelfItem(library, pluginId: content.pluginId, contentId: content.contentId);
  final privateContent = false;
  final mediaHost = ref.read(companionMediaHostProvider);
  final active = mediaHost.active;
  if (content.useTvProgress &&
      active != null &&
      !active.privateContent &&
      active.content.pluginId == content.pluginId &&
      active.content.contentId == content.contentId &&
      active.content.groupId == content.groupId &&
      active.content.episodeId == content.episodeId) {
    execution.ensureCurrent();
    if (!active.controller.snapshot.playing) await active.controller.play();
    await _awaitWhileCurrent(_waitForPlaying(active.controller), execution);
    execution.ensureCurrent();
    return;
  }
  var initialPosition = Duration(milliseconds: content.positionMs);
  if (content.useTvProgress) {
    final shelfProgress = shelfItem == null ? null : await library.loadProgress(shelfItem.id);
    if (shelfProgress is LibraryVideoPlaybackProgress &&
        shelfProgress.groupId == content.groupId &&
        shelfProgress.episodeId == content.episodeId) {
      initialPosition = shelfProgress.position;
    } else {
      final history = await library.readVideoHistory(videoHistorySourceKey(content.pluginId, content.contentId));
      if (history != null && history.checkpoint.groupId == content.groupId && history.checkpoint.episodeId == content.episodeId) {
        initialPosition = history.checkpoint.position;
      }
    }
  }
  final diagnostics = container.read(diagnosticsManagerProvider);
  final startupSession = VideoStartupSession(diagnostics.idGenerator.nextId('video_startup'));
  final playbackSessionId = diagnostics.idGenerator.nextId('video_session');
  final identityFuture = container.read(deviceIdentityStoreProvider).loadOrCreateIdentity().then((identity) => identity.deviceId);
  final proxyUri = container.read(configuredFlutterNetworkProxyManagerProvider).playerProxyUriFor(NetworkProxyTraffic.video);
  final preferAndroidSurface = await readSourceVideoDirectSurfacePreference();
  final preferences = SourceVideoPreferences.fromSettings(container.read(appSettingsProvider));
  final dataSource = SourceVideoDataSource(gateway: gateway, pluginId: content.pluginId, initialDetail: detail, initialCatalog: catalog);
  final store = TransientSourceVideoPlaybackStateStore(
    contentId: content.contentId,
    initialGroupId: content.groupId,
    initialEpisodeId: content.episodeId,
    libraryFuture: libraryFuture,
    libraryItemId: shelfItem?.id,
    initialPosition: initialPosition,
    pluginId: content.pluginId,
    pluginVersion: source.pluginVersion,
    title: detail.summary.title,
    originDeviceIdFuture: identityFuture,
    playbackSessionId: playbackSessionId,
    controllerDeviceId: execution.peerId,
    privateContent: privateContent,
    initiallyActive: false,
  );
  final actualBackendFactory =
      backendFactory ??
      () => createMediaKitVideoPlaybackBackend(
        proxyUri: proxyUri,
        preferAndroidSurface: preferAndroidSurface,
        decoderMode: preferences.decoderMode,
        androidOutputMode: preferences.androidOutputMode,
      );
  final setup = SourceVideoPlayerSetup(
    dataSource: dataSource,
    stateStore: store,
    proxyUri: proxyUri,
    preferAndroidSurface: preferAndroidSurface,
    preferences: preferences,
    pluginVersion: source.pluginVersion,
    privateContent: privateContent,
    canSystemVolume: await _canControlSystemVolume(),
    backendFactory: actualBackendFactory,
  );
  final prepared = VideoPreparedSession(
    backendFactory: actualBackendFactory,
    dataSource: dataSource,
    contentId: content.contentId,
    groupId: content.groupId,
    episodeId: content.episodeId,
    initialPosition: initialPosition,
  );

  final overlay = navigator.overlay;
  if (overlay == null) throw const CompanionFailure('media_host_unavailable');
  final entry = OverlayEntry(
    builder: (_) => Positioned(
      right: 12,
      bottom: 12,
      width: 320,
      height: 180,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black,
            border: Border.all(color: Colors.white54, width: 2),
          ),
          child: prepared.buildSurface(),
        ),
      ),
    ),
  );
  entry.markNeedsBuild();
  overlay.insert(entry);
  var routePushed = false;
  var oldWasPlaying = false;
  var oldControllerPaused = false;
  var oldPlatformReleased = false;
  VideoPlayerController? oldController;
  Route<dynamic>? oldRoute;
  Route<dynamic>? candidateRoute;
  SourceVideoPlayerDestinationState? oldOwner;
  final destinationState = Completer<SourceVideoPlayerDestinationState>();
  try {
    execution.report(CompanionCommandPhase.buffering);
    await _awaitWhileCurrent(prepared.prepare(), execution);
    execution.ensureCurrent();
    if (!prepared.isReady) {
      throw CompanionFailure(prepared.failure?.code ?? 'video_prepare_failed');
    }

    final active = mediaHost.active;
    final activeOwner = active?.owner;
    if (activeOwner is SourceVideoPlayerDestinationState) oldOwner = activeOwner;
    if (activeOwner is SourceVideoPlayerDestinationState) oldRoute = activeOwner.modalRoute;
    if (active != null) {
      oldController = active.controller;
      oldWasPlaying = active.controller.snapshot.playing;
      if (oldWasPlaying) {
        await active.controller.pause();
        oldControllerPaused = true;
      }
      execution.ensureCurrent();
    }

    final audioStop = container.read(sourceAudioPlaybackServiceProvider.notifier).stop();
    await _awaitWhileCurrent(audioStop, execution);
    execution.ensureCurrent();

    final activation = Completer<void>();
    final route = MaterialPageRoute<void>(
      settings: const RouteSettings(name: appContentSessionRouteName),
      builder: (_) => SourceVideoPlayerDestination(
        container: container,
        navigator: navigator,
        detail: detail,
        initialCatalog: catalog,
        initialGroupId: content.groupId,
        initialEpisodeId: content.episodeId,
        libraryItemId: shelfItem?.id.value,
        initialPosition: initialPosition,
        playbackSessionId: playbackSessionId,
        controllerDeviceId: execution.peerId,
        playbackGate: Future<void>.value(),
        startupSession: startupSession,
        diagnostics: diagnostics,
        initialSetup: setup,
        preparedSession: prepared,
        activeCompleter: activation,
        autoPlay: false,
        deferPlatformActivation: true,
        beforePlaybackActivation: () async {
          if (activeOwner is SourceVideoPlayerDestinationState) {
            oldPlatformReleased = true;
            await activeOwner.relinquishPlatformSession();
          }
        },
        ensurePlaybackActivationCurrent: execution.ensureCurrent,
        stateCompleter: destinationState,
      ),
    );
    candidateRoute = route;
    unawaited(navigator.push<void>(route));
    routePushed = true;
    await _awaitWhileCurrent(activation.future.timeout(const Duration(seconds: 15)), execution);
    execution.ensureCurrent();
    await _awaitWhileCurrent(_waitForRouteVisible(route), execution);
    execution.ensureCurrent();
    await _awaitWhileCurrent(store.prepareActivation(), execution);
    execution.commitPlaybackChange();
    unawaited(store.activate());
    if (oldRoute != null && oldRoute.isActive) {
      navigator.removeRoute(oldRoute);
    }
  } on Object {
    final candidate = candidateRoute;
    if (routePushed && candidate != null && candidate.isActive) {
      navigator.removeRoute(candidate);
      if (destinationState.isCompleted) {
        try {
          await destinationState.future.then((state) => state.closedFuture).timeout(const Duration(seconds: 5));
        } on Object {
          // Route removal already initiated disposal; retain the original failure.
        }
      }
      if (candidate is TransitionRoute<dynamic>) {
        try {
          await candidate.completed.timeout(const Duration(seconds: 4));
        } on Object {
          // Route removal has already disposed its player subtree.
        }
      }
    }
    final currentOwner = ref.read(companionMediaHostProvider).active?.owner;
    final canRestoreOldOwner = currentOwner == null || identical(currentOwner, oldOwner);
    if (oldPlatformReleased && oldOwner != null && canRestoreOldOwner) {
      try {
        await oldOwner.reclaimPlatformSession();
        if (oldWasPlaying) await oldController?.play();
      } on Object {
        // Preserve the original handoff error; the old route can still retry.
      }
    }
    if (!oldPlatformReleased && oldControllerPaused && oldWasPlaying && canRestoreOldOwner) {
      try {
        await oldController?.play();
      } on Object {
        // A failed staged handoff should not block recovery of the old route.
      }
    }
    rethrow;
  } finally {
    if (entry.mounted) entry.remove();
    entry.dispose();
    if (!routePushed || !destinationState.isCompleted) prepared.dispose();
  }
}

Future<LibraryItem?> _findShelfItem(ContentLibrary library, {required String pluginId, required String contentId}) async {
  for (final visibility in <LibraryVisibility>[LibraryVisibility.normal]) {
    final items = await library.loadShelfProjection(visibility: visibility);
    for (final item in items) {
      if (item.source.pluginId == pluginId && item.source.remoteContentId == contentId && item.kind == ContentKind.video) {
        return library.getLibraryItem(item.itemId);
      }
    }
  }
  return null;
}

Future<void> _waitForPlaying(VideoPlayerController controller) async {
  final deadline = DateTime.now().add(const Duration(seconds: 8));
  while (!controller.snapshot.playing) {
    if (controller.snapshot.failure != null) throw StateError(controller.snapshot.failure!.code ?? 'player_failed');
    if (DateTime.now().isAfter(deadline)) throw TimeoutException('video_not_playing');
    await Future<void>.delayed(const Duration(milliseconds: 40));
  }
}

Future<void> _waitForRouteVisible(TransitionRoute<dynamic> route) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (route.animation?.status != AnimationStatus.completed) {
    if (!route.isActive || DateTime.now().isAfter(deadline)) throw TimeoutException('video_route_not_visible');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Future<bool> _canControlSystemVolume() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
  try {
    final fixed = await const MethodChannel(
      'mgread/media_system_volume',
    ).invokeMethod<bool>('isSystemVolumeFixed').timeout(const Duration(seconds: 2));
    return fixed == false;
  } on Object {
    return false;
  }
}

Future<T> _awaitWhileCurrent<T>(Future<T> operation, CompanionExecutionContext execution) async {
  final result = Completer<T>();
  Timer? timer;
  void checkCurrent() {
    if (result.isCompleted) return;
    if (!execution.isCurrent) {
      result.completeError(const CompanionCommandCancelledException());
      return;
    }
    timer = Timer(const Duration(milliseconds: 80), checkCurrent);
  }

  operation.then<void>(
    (value) {
      if (!result.isCompleted) result.complete(value);
    },
    onError: (Object error, StackTrace stackTrace) {
      if (!result.isCompleted) result.completeError(error, stackTrace);
    },
  );
  checkCurrent();
  try {
    final value = await result.future;
    execution.ensureCurrent();
    return value;
  } finally {
    timer?.cancel();
  }
}
