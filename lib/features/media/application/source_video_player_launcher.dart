/// Video-source route launcher for the independently maintained player.
///
/// This host keeps source groups neutral, creates video playback sessions, and
/// owns route-scoped orientation, system UI, screen-awake and brightness
/// lifetimes. It retains no media URL, request header, cookie or Runtime state.
/// Shelf launches discard their placeholder catalog before player setup.
/// Playback failures also dismiss the entry cover so retry remains reachable.
/// Native hardware policy, sampled once per setup, selects compatible Android
/// video output independently of the TV layout setting.
/// User decoder/output overrides are also sampled once; rebuilds never replace
/// the live player's native configuration.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mg_read_video_player/mg_read_video_player.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_startup.dart';
import 'package:mg_read/app/app_navigation_activity.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/media/application/source_audio_playback_service.dart';
import 'package:mg_read/features/media/application/source_video_data_source.dart';
import 'package:mg_read/features/media/application/source_video_audio_session_controller.dart';
import 'package:mg_read/features/media/application/source_video_fullscreen_controller.dart';
import 'package:mg_read/features/media/application/source_video_playback_platform_controller.dart';
import 'package:mg_read/features/media/application/source_video_preferences.dart';
import 'package:mg_read/features/media/application/transient_source_video_playback_state_store.dart';
import 'package:mg_read/features/media/presentation/media_entry_cover.dart';
import 'package:mg_read/features/network_proxy/application/flutter_network_proxy_manager.dart';
import 'package:mg_read/features/network_proxy/application/network_proxy_settings.dart';
import 'package:mg_read/features/lan_sync/application/device_identity_store.dart';
import 'package:mg_read/features/tv_companion/application/companion_media_host.dart';
import 'package:mg_read/features/tv_companion/domain/companion_models.dart';

/// Opens one selected neutral video group/episode in the video player.
Future<void> openTransientSourceVideoPlayer(
  BuildContext context, {
  required NavigatorState navigator,
  required PluginContentDetail detail,
  required PluginChaptersResult firstCatalogPage,
  required PluginChapterSummary chapter,
  String? libraryItemId,
  String? initialGroupId,
  Duration? initialPosition,
  String? playbackSessionId,
  String? controllerDeviceId,
}) async {
  if (!context.mounted || !navigator.mounted) return;
  final groups = firstCatalogPage.groups;
  final explicitlySelected = initialGroupId == null
      ? null
      : groups.where((group) => group.id == initialGroupId && group.episodes.any((episode) => episode.id == chapter.id)).firstOrNull;
  final identicalMatches = groups.where((group) => group.episodes.any((episode) => identical(episode, chapter))).toList();
  final idMatches = groups.where((group) => group.episodes.any((episode) => episode.id == chapter.id)).toList();
  final group =
      explicitlySelected ??
      (identicalMatches.length == 1
          ? identicalMatches.single
          : idMatches.length == 1
          ? idMatches.single
          : null);
  if (group == null && idMatches.length > 1) throw StateError('ambiguous_video_group');
  final container = ProviderScope.containerOf(context, listen: false);
  final diagnostics = container.read(diagnosticsManagerProvider);
  final startupSession = VideoStartupSession(diagnostics.idGenerator.nextId('video_startup'));
  _recordStartupEvent(diagnostics, startupSession.mark(VideoStartupPhase.click, state: VideoStartupState.started));
  final audioStop = container.read(sourceAudioPlaybackServiceProvider.notifier).stop();
  if (!navigator.mounted) {
    await audioStop;
    return;
  }
  return navigator.push<void>(
    MaterialPageRoute<void>(
      settings: const RouteSettings(name: appContentSessionRouteName),
      builder: (_) => SourceVideoPlayerDestination(
        container: container,
        navigator: navigator,
        detail: detail,
        initialCatalog: firstCatalogPage,
        initialGroupId: group?.id ?? initialGroupId ?? 'default',
        initialEpisodeId: chapter.id,
        libraryItemId: libraryItemId,
        initialPosition: initialPosition,
        playbackSessionId: playbackSessionId ?? diagnostics.idGenerator.nextId('video_session'),
        controllerDeviceId: controllerDeviceId,
        playbackGate: audioStop,
        startupSession: startupSession,
        diagnostics: diagnostics,
      ),
    ),
  );
}

final class SourceVideoPlayerDestination extends StatefulWidget {
  const SourceVideoPlayerDestination({
    super.key,
    required this.container,
    required this.navigator,
    required this.detail,
    required this.initialCatalog,
    required this.initialGroupId,
    required this.initialEpisodeId,
    required this.libraryItemId,
    required this.initialPosition,
    required this.playbackSessionId,
    required this.controllerDeviceId,
    required this.playbackGate,
    required this.startupSession,
    required this.diagnostics,
    this.initialSetup,
    this.preparedSession,
    this.activeCompleter,
    this.autoPlay = true,
    this.deferPlatformActivation = false,
    this.beforePlaybackActivation,
    this.ensurePlaybackActivationCurrent,
    this.stateCompleter,
  });

  final ProviderContainer container;
  final NavigatorState navigator;
  final PluginContentDetail detail;
  final PluginChaptersResult initialCatalog;
  final String initialGroupId;
  final String initialEpisodeId;
  final String? libraryItemId;
  final Duration? initialPosition;
  final String playbackSessionId;
  final String? controllerDeviceId;
  final SourceVideoPlayerSetup? initialSetup;
  final VideoPreparedSession? preparedSession;
  final Completer<void>? activeCompleter;
  final bool autoPlay;
  final bool deferPlatformActivation;
  final Future<void> Function()? beforePlaybackActivation;
  final VoidCallback? ensurePlaybackActivationCurrent;
  final Completer<SourceVideoPlayerDestinationState>? stateCompleter;
  final Future<void> playbackGate;
  final VideoStartupSession startupSession;
  final DiagnosticsManager diagnostics;

  @override
  State<SourceVideoPlayerDestination> createState() => SourceVideoPlayerDestinationState();
}

final class SourceVideoPlayerDestinationState extends State<SourceVideoPlayerDestination> {
  late SourceVideoFullscreenController _fullscreenController;
  late SourceVideoPlaybackPlatformController _playbackPlatformController;
  late SourceVideoAudioSessionController _audioSessionController;
  late final VideoPlayerController _playerController;
  SourceVideoPlayerSetup? _setup;
  Object? _setupFailure;
  bool _firstFramePresented = false;
  bool _registeredWithCompanion = false;
  bool _preparedPlaybackStarted = false;
  final Completer<void> _closedCompleter = Completer<void>();
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _fullscreenController = SourceVideoFullscreenController(tvMode: widget.container.read(appSettingsProvider).get(AppSettingKeys.tvMode));
    _playbackPlatformController = SourceVideoPlaybackPlatformController();
    _playerController = VideoPlayerController();
    _audioSessionController = SourceVideoAudioSessionController(onPauseRequested: _pauseForSystemInterruption);
    if (widget.stateCompleter case final completer?) {
      if (!completer.isCompleted) completer.complete(this);
    }
    if (!widget.deferPlatformActivation) unawaited(_fullscreenController.activate());
    _recordStartupEvent(
      widget.diagnostics,
      widget.startupSession.mark(VideoStartupPhase.routePresented, state: VideoStartupState.completed),
    );
    _playerController.addListener(_completeActivationIfReady);
    final initialSetup = widget.initialSetup;
    if (initialSetup != null) {
      _setup = initialSetup;
      _completeActivationIfReady();
    } else {
      unawaited(_prepare());
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final setup = _setup;
    if (setup != null) _registerCompanionMedia(setup);
  }

  Future<void> _prepare() async {
    final generation = ++_generation;
    setState(() {
      _setup = null;
      _setupFailure = null;
      _firstFramePresented = false;
    });
    try {
      final libraryFuture = widget.container.read(appStartupControllerProvider).contentLibrary;
      final itemId = widget.libraryItemId == null ? null : LibraryItemId(widget.libraryItemId!);
      final proxyUri = widget.container.read(configuredFlutterNetworkProxyManagerProvider).playerProxyUriFor(NetworkProxyTraffic.video);
      final preferAndroidSurface = await readSourceVideoDirectSurfacePreference();
      final videoPreferences = SourceVideoPreferences.fromSettings(widget.container.read(appSettingsProvider));
      if (!mounted || generation != _generation) return;
      final sources = await widget.container.read(sourceContentGatewayProvider).listSources();
      final pluginVersion = sources.where((source) => source.id == widget.detail.pluginId).firstOrNull?.pluginVersion ?? 'unknown';
      final identityFuture = widget.container
          .read(deviceIdentityStoreProvider)
          .loadOrCreateIdentity()
          .then((identity) => identity.deviceId);
      final library = await libraryFuture;
      final privateContent = itemId == null ? false : (await library.getLibraryItem(itemId))?.visibility == LibraryVisibility.private;
      if (!mounted || generation != _generation) return;
      final setup = SourceVideoPlayerSetup(
        dataSource: SourceVideoDataSource(
          gateway: widget.container.read(sourceContentGatewayProvider),
          pluginId: widget.detail.pluginId,
          initialDetail: widget.detail,
          // Shelf entry data may contain only the stable launch placeholder.
          // Force the player to resolve the real source catalog in that case.
          initialCatalog: widget.libraryItemId == null ? widget.initialCatalog : null,
          playbackGate: widget.playbackGate,
        ),
        stateStore: TransientSourceVideoPlaybackStateStore(
          contentId: widget.detail.summary.id,
          initialGroupId: widget.initialGroupId,
          initialEpisodeId: widget.initialEpisodeId,
          libraryFuture: libraryFuture,
          libraryItemId: itemId,
          initialPosition: widget.initialPosition,
          pluginId: widget.detail.pluginId,
          pluginVersion: pluginVersion,
          title: widget.detail.summary.title,
          originDeviceIdFuture: identityFuture,
          playbackSessionId: widget.playbackSessionId,
          controllerDeviceId: widget.controllerDeviceId,
          privateContent: privateContent,
        ),
        proxyUri: proxyUri,
        preferAndroidSurface: preferAndroidSurface,
        preferences: videoPreferences,
        pluginVersion: pluginVersion,
        privateContent: privateContent,
        canSystemVolume: await _canControlSystemVolume(),
      );
      setState(() => _setup = setup);
      _registerCompanionMedia(setup);
      _completeActivationIfReady();
    } on Object catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() => _setupFailure = error);
    }
  }

  void _registerCompanionMedia(SourceVideoPlayerSetup setup) {
    if (!mounted) return;
    final host = widget.container.read(companionMediaHostProvider);
    final route = ModalRoute.of(context);
    if (_registeredWithCompanion && host.active?.owner == this && host.active?.route == route) return;
    _registeredWithCompanion = true;
    host.register(
      CompanionMediaBinding(
        owner: this,
        controller: _playerController,
        content: CompanionContentRef(
          pluginId: setup.dataSource.pluginId,
          pluginVersion: setup.pluginVersion,
          contentId: widget.detail.summary.id,
          title: widget.detail.summary.title,
          groupId: widget.initialGroupId,
          episodeId: widget.initialEpisodeId,
        ),
        sessionId: widget.playbackSessionId,
        systemVolumeRead: _playbackPlatformController.readSystemVolume,
        systemVolumeWrite: _playbackPlatformController.setSystemVolume,
        canSystemVolume: setup.canSystemVolume,
        privateContent: setup.privateContent,
        onSaveFailure: () => setup.stateStore.saveFailure,
        route: route,
      ),
    );
  }

  void _completeActivationIfReady() {
    final snapshot = _playerController.snapshot;
    if (widget.preparedSession != null && widget.deferPlatformActivation && snapshot.firstFrameReady && !_preparedPlaybackStarted) {
      _preparedPlaybackStarted = true;
      unawaited(_activatePreparedPlayback());
    }
    final completer = widget.activeCompleter;
    if (completer == null || completer.isCompleted) return;
    if (snapshot.failure != null) {
      _presentPlayer();
      completer.completeError(StateError(snapshot.failure?.code ?? 'player_failed'));
      return;
    }
    if (snapshot.firstFrameReady && snapshot.playing) {
      _presentPlayer();
      completer.complete();
    }
  }

  Future<void> _activatePreparedPlayback() async {
    try {
      widget.ensurePlaybackActivationCurrent?.call();
      await widget.beforePlaybackActivation?.call();
      widget.ensurePlaybackActivationCurrent?.call();
      if (!mounted) return;
      await _fullscreenController.activate();
      widget.ensurePlaybackActivationCurrent?.call();
      if (!mounted) return;
      await _playbackPlatformController.setPlaybackActive(true);
      widget.ensurePlaybackActivationCurrent?.call();
      if (!mounted) return;
      await _audioSessionController.setPlaybackActive(true);
      widget.ensurePlaybackActivationCurrent?.call();
      if (!mounted) return;
      await _playerController.play();
      try {
        widget.ensurePlaybackActivationCurrent?.call();
      } on Object {
        await _playerController.pause();
        rethrow;
      }
    } on Object catch (error) {
      final completer = widget.activeCompleter;
      if (completer != null && !completer.isCompleted) completer.completeError(error);
    }
  }

  bool get isCurrentRoute => ModalRoute.of(context)?.isCurrent == true;
  Route<dynamic>? get modalRoute => ModalRoute.of(context);
  Future<void> get closedFuture => _closedCompleter.future;

  Future<void> relinquishPlatformSession() async {
    await Future.wait<void>(<Future<void>>[
      _fullscreenController.restoreAndClose(),
      _playbackPlatformController.restoreAndClose(),
      _audioSessionController.restoreAndClose(),
    ], eagerError: false);
  }

  Future<void> reclaimPlatformSession() async {
    if (!mounted) return;
    _fullscreenController = SourceVideoFullscreenController(tvMode: widget.container.read(appSettingsProvider).get(AppSettingKeys.tvMode));
    _playbackPlatformController = SourceVideoPlaybackPlatformController();
    _audioSessionController = SourceVideoAudioSessionController(onPauseRequested: _pauseForSystemInterruption);
    await _fullscreenController.activate();
    await _playbackPlatformController.setPlaybackActive(_playerController.snapshot.playing);
    await _audioSessionController.setPlaybackActive(_playerController.snapshot.playing);
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

  void _exit() {
    if (widget.navigator.mounted && widget.navigator.canPop()) widget.navigator.pop();
  }

  void _presentPlayer() {
    if (mounted && !_firstFramePresented) setState(() => _firstFramePresented = true);
  }

  Future<void> _pauseForSystemInterruption() async {
    if (!mounted || !_playerController.snapshot.playing) return;
    await _playerController.pause();
  }

  @override
  Widget build(BuildContext context) {
    final setup = _setup;
    if (setup == null) {
      return PopScope<void>(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop) _exit();
        },
        child: MediaEntryCoverSurface(
          kind: MediaEntryKind.video,
          title: widget.detail.summary.title,
          coverBytes: widget.detail.summary.coverBytes,
          failureMessage: _setupFailure == null ? null : '播放器准备失败，请重试。',
          onRetry: _setupFailure == null ? null : () => unawaited(_prepare()),
          onExit: _exit,
        ),
      );
    }
    return MediaEntryCoverTransition(
      kind: MediaEntryKind.video,
      title: widget.detail.summary.title,
      coverBytes: widget.detail.summary.coverBytes,
      presented: _firstFramePresented,
      onExit: _exit,
      child: VideoPlayerView(
        tvMode: widget.container.read(appSettingsProvider).get(AppSettingKeys.tvMode),
        key: const Key('source-video-player'),
        contentId: widget.detail.summary.id,
        dataSource: setup.dataSource,
        stateStore: setup.stateStore,
        controller: _playerController,
        preparedSession: widget.preparedSession,
        autoPlay: widget.autoPlay,
        observer: _VideoEntryObserver(
          delegate: _DismissVideoPlayerObserver(
            widget.navigator,
            _fullscreenController,
            _playbackPlatformController,
            _audioSessionController,
          ),
          onPresented: _presentPlayer,
          onActivationFailure: (failure) {
            final pending = widget.activeCompleter;
            if (pending != null && !pending.isCompleted) {
              pending.completeError(
                VideoPlayerLoadException(message: failure.message, code: failure.code ?? 'video_activation_failed', location: '激活候选视频'),
              );
            }
          },
          diagnostics: widget.diagnostics,
        ),
        startupSession: widget.startupSession,
        backendFactory:
            setup.backendFactory ??
            () => createMediaKitVideoPlaybackBackend(
              proxyUri: setup.proxyUri,
              preferAndroidSurface: setup.preferAndroidSurface,
              decoderMode: setup.preferences.decoderMode,
              androidOutputMode: setup.preferences.androidOutputMode,
            ),
      ),
    );
  }

  @override
  void dispose() {
    _generation++;
    widget.container.read(companionMediaHostProvider).unregister(this);
    _playerController.removeListener(_completeActivationIfReady);
    widget.preparedSession?.dispose();
    unawaited(
      relinquishPlatformSession().whenComplete(() {
        if (!_closedCompleter.isCompleted) _closedCompleter.complete();
      }),
    );
    _playerController.dispose();
    super.dispose();
  }
}

final class SourceVideoPlayerSetup {
  const SourceVideoPlayerSetup({
    required this.dataSource,
    required this.stateStore,
    required this.proxyUri,
    required this.preferAndroidSurface,
    required this.preferences,
    required this.pluginVersion,
    required this.privateContent,
    required this.canSystemVolume,
    this.backendFactory,
  });

  final SourceVideoDataSource dataSource;
  final TransientSourceVideoPlaybackStateStore stateStore;
  final Uri? proxyUri;
  final bool preferAndroidSurface;
  final SourceVideoPreferences preferences;
  final String pluginVersion;
  final bool privateContent;
  final bool canSystemVolume;
  final VideoPlaybackBackendFactory? backendFactory;
}

final class _VideoEntryObserver extends VideoPlayerObserver {
  const _VideoEntryObserver({required this.delegate, required this.onPresented, required this.diagnostics, this.onActivationFailure});

  final VideoPlayerObserver delegate;
  final VoidCallback onPresented;
  final DiagnosticsManager diagnostics;
  final ValueChanged<VideoPlayerFailure>? onActivationFailure;

  @override
  FutureOr<void> onStartupEvent(VideoStartupEvent event) {
    _recordStartupEvent(diagnostics, event);
    return delegate.onStartupEvent(event);
  }

  @override
  FutureOr<void> onFirstFrame(VideoPlayerSnapshot snapshot) {
    onPresented();
    return delegate.onFirstFrame(snapshot);
  }

  @override
  FutureOr<void> onFailure(VideoPlayerFailure failure) {
    onActivationFailure?.call(failure);
    if (failure.kind == VideoPlayerFailureKind.data || failure.kind == VideoPlayerFailureKind.playback) onPresented();
    return delegate.onFailure(failure);
  }

  @override
  FutureOr<void> onFullscreenRequested(bool fullscreen) => delegate.onFullscreenRequested(fullscreen);

  @override
  FutureOr<void> onPlaybackActiveChanged(bool active) => delegate.onPlaybackActiveChanged(active);

  @override
  FutureOr<double?> onBrightnessReadRequested() => delegate.onBrightnessReadRequested();

  @override
  FutureOr<void> onBrightnessRequested(double brightness) => delegate.onBrightnessRequested(brightness);

  @override
  FutureOr<double?> onSystemVolumeReadRequested() => delegate.onSystemVolumeReadRequested();

  @override
  FutureOr<void> onSystemVolumeRequested(double volume) => delegate.onSystemVolumeRequested(volume);

  @override
  FutureOr<void> onExitRequested(VideoPlaybackProgress? progress) => delegate.onExitRequested(progress);
}

void _recordStartupEvent(DiagnosticsManager diagnostics, VideoStartupEvent event) {
  if (diagnostics.isClosed) return;
  try {
    diagnostics.emit(
      AppDiagnosticEvents.videoPlaybackStartup,
      attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
        'sessionId': DiagnosticValue.string(event.sessionId),
        'phase': DiagnosticValue.string(event.phase.name),
        'elapsedMicros': DiagnosticValue.int64(event.elapsed.inMicroseconds),
        'resultState': DiagnosticValue.string(event.state.name),
        if (event.resourceRole != null) 'resourceRole': DiagnosticValue.string(event.resourceRole!.name),
        if (event.byteCount != null) 'bytes': DiagnosticValue.int64(event.byteCount!),
      }),
    );
  } on Object {
    // Startup diagnostics must never delay or fail playback.
  }
}

final class _DismissVideoPlayerObserver extends VideoPlayerObserver {
  const _DismissVideoPlayerObserver(
    this._navigator,
    this._fullscreenController,
    this._playbackPlatformController,
    this._audioSessionController,
  );

  final NavigatorState _navigator;
  final SourceVideoFullscreenController _fullscreenController;
  final SourceVideoPlaybackPlatformController _playbackPlatformController;
  final SourceVideoAudioSessionController _audioSessionController;

  @override
  Future<void> onFullscreenRequested(bool fullscreen) => _fullscreenController.setFullscreen(fullscreen);

  @override
  Future<void> onPlaybackActiveChanged(bool active) => Future.wait<void>(<Future<void>>[
    _playbackPlatformController.setPlaybackActive(active),
    _audioSessionController.setPlaybackActive(active),
  ], eagerError: false);

  @override
  Future<double?> onBrightnessReadRequested() => _playbackPlatformController.readBrightness();

  @override
  Future<void> onBrightnessRequested(double brightness) => _playbackPlatformController.setBrightness(brightness);

  @override
  Future<double?> onSystemVolumeReadRequested() => _playbackPlatformController.readSystemVolume();

  @override
  Future<void> onSystemVolumeRequested(double volume) => _playbackPlatformController.setSystemVolume(volume);

  @override
  Future<void> onExitRequested(VideoPlaybackProgress? progress) async {
    try {
      await Future.wait<void>(<Future<void>>[
        _fullscreenController.restoreAndClose(),
        _playbackPlatformController.restoreAndClose(),
        _audioSessionController.restoreAndClose(),
      ], eagerError: false);
    } on Object {
      // Platform cleanup failures must not trap the user in the player route.
    } finally {
      if (_navigator.mounted && _navigator.canPop()) _navigator.pop();
    }
  }
}
