/// Process-scoped owner for the complete source-audio playback session.
///
/// Responsibilities:
/// - Create, replace and close one [AudioPlayerEngine] independently of UI.
/// - Retain Runtime data access, progress storage and Android media-session
///   attachment for exactly the active playback lifetime.
/// - Publish presentation and exit-confirmation state to transient views.
/// - Forward app lifecycle recovery to the engine without capturing a Widget.
///
/// Notes:
/// - Durable state contains only stable content/chapter IDs and position.
/// - Media URLs, request headers and Runtime authorization remain memory-only.
/// - The native Android foreground service remains provided by audio_service.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mg_read_audio_player/mg_read_audio_player.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_startup.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/network_proxy/application/flutter_network_proxy_manager.dart';
import 'package:mg_read/features/network_proxy/application/network_proxy_settings.dart';

import 'android_audio_background_service.dart';
import 'source_audio_playback_lifecycle.dart';
import 'source_audio_playlist_data_source.dart';
import 'transient_source_audio_playback_state_store.dart';

/// Source inputs retained only while their global audio session is active.
final class SourceAudioPlaybackRequest {
  const SourceAudioPlaybackRequest({
    required this.detail,
    required this.firstCatalogPage,
    required this.chapter,
    required this.libraryItemId,
  });

  final PluginContentDetail detail;
  final PluginChaptersResult firstCatalogPage;
  final PluginChapterSummary chapter;
  final String? libraryItemId;
}

enum SourceAudioPresentation { inactive, expanded, minimized }

/// Immutable presentation projection of the app-global playback service.
final class SourceAudioPlaybackState {
  const SourceAudioPlaybackState._({
    required this.presentation,
    required this.keepScreenOn,
    this.sessionId,
    this.request,
    this.controller,
    this.setupFailure,
    this.playerPresented = false,
    this.exitDecisionRequested = false,
  });

  const SourceAudioPlaybackState.inactive() : this._(presentation: SourceAudioPresentation.inactive, keepScreenOn: true);

  const SourceAudioPlaybackState.active({
    required int sessionId,
    required SourceAudioPlaybackRequest request,
    required SourceAudioPresentation presentation,
    required bool keepScreenOn,
    AudioPlayerController? controller,
    Object? setupFailure,
    bool playerPresented = false,
    bool exitDecisionRequested = false,
  }) : this._(
         presentation: presentation,
         sessionId: sessionId,
         request: request,
         controller: controller,
         setupFailure: setupFailure,
         playerPresented: playerPresented,
         exitDecisionRequested: exitDecisionRequested,
         keepScreenOn: keepScreenOn,
       );

  final SourceAudioPresentation presentation;
  final int? sessionId;
  final SourceAudioPlaybackRequest? request;
  final AudioPlayerController? controller;
  final Object? setupFailure;
  final bool playerPresented;
  final bool exitDecisionRequested;
  final bool keepScreenOn;

  bool get isActive => presentation != SourceAudioPresentation.inactive && sessionId != null && request != null;

  SourceAudioPlaybackState copyWith({
    SourceAudioPresentation? presentation,
    AudioPlayerController? controller,
    bool clearController = false,
    Object? setupFailure,
    bool clearSetupFailure = false,
    bool? playerPresented,
    bool? exitDecisionRequested,
    bool? keepScreenOn,
  }) {
    final currentSessionId = sessionId;
    final currentRequest = request;
    if (currentSessionId == null || currentRequest == null) {
      return const SourceAudioPlaybackState.inactive();
    }
    return SourceAudioPlaybackState.active(
      sessionId: currentSessionId,
      request: currentRequest,
      presentation: presentation ?? this.presentation,
      controller: clearController ? null : controller ?? this.controller,
      setupFailure: clearSetupFailure ? null : setupFailure ?? this.setupFailure,
      playerPresented: playerPresented ?? this.playerPresented,
      exitDecisionRequested: exitDecisionRequested ?? this.exitDecisionRequested,
      keepScreenOn: keepScreenOn ?? this.keepScreenOn,
    );
  }
}

/// Optional host transport seam; production uses the package MediaKit backend.
typedef SourceAudioPlaybackBackendFactory = AudioPlaybackBackend Function();

final sourceAudioPlaybackBackendFactoryProvider = Provider<SourceAudioPlaybackBackendFactory?>((ref) => null);

final sourceAudioPlaybackServiceProvider = NotifierProvider<SourceAudioPlaybackService, SourceAudioPlaybackState>(
  SourceAudioPlaybackService.new,
);

/// Owns the lifetime and dependencies of the one app-global audio session.
final class SourceAudioPlaybackService extends Notifier<SourceAudioPlaybackState> with WidgetsBindingObserver {
  int _nextSessionId = 0;
  int _operationGeneration = 0;
  AudioPlayerEngine? _engine;
  AudioPlayerController? _controller;
  SourceAudioPlaylistDataSource? _dataSource;
  SourceAudioPlaybackLifecycle? _screenLifecycle;
  Completer<void>? _completion;
  Future<void>? _stopFuture;
  bool _disposed = false;

  AudioPlayerController? get controller => _controller;

  @visibleForTesting
  AudioPlayerEngine? get engine => _engine;

  @override
  SourceAudioPlaybackState build() {
    WidgetsBinding.instance.addObserver(this);
    ref.onDispose(() {
      _disposed = true;
      _operationGeneration++;
      WidgetsBinding.instance.removeObserver(this);
      unawaited(_disposeCurrentResources());
      _completeCurrent();
    });
    return const SourceAudioPlaybackState.inactive();
  }

  /// Replaces any existing playback and expands the new global session.
  Future<void> open(SourceAudioPlaybackRequest request) async {
    await (_stopFuture ?? Future<void>.value());
    await stop();
    if (_disposed) return;
    final settings = ref.read(appSettingsProvider);
    final keepScreenOn = settings.supports(AppSettingKeys.audioKeepScreenOn) ? settings.get(AppSettingKeys.audioKeepScreenOn) : true;
    final sessionId = ++_nextSessionId;
    final completion = Completer<void>();
    _completion = completion;
    state = SourceAudioPlaybackState.active(
      sessionId: sessionId,
      request: request,
      presentation: SourceAudioPresentation.expanded,
      keepScreenOn: keepScreenOn,
    );
    unawaited(_prepare(sessionId, request));
    await completion.future;
  }

  Future<void> retryPreparation() async {
    final sessionId = state.sessionId;
    final request = state.request;
    if (_disposed || sessionId == null || request == null || _engine != null) {
      return;
    }
    state = state.copyWith(clearSetupFailure: true);
    await _prepare(sessionId, request);
  }

  Future<void> _prepare(int sessionId, SourceAudioPlaybackRequest request) async {
    final generation = ++_operationGeneration;
    AudioPlayerController? localController;
    SourceAudioPlaylistDataSource? localDataSource;
    try {
      final ContentLibrary? library = request.libraryItemId == null ? null : await ref.read(appStartupControllerProvider).contentLibrary;
      final itemId = request.libraryItemId == null ? null : LibraryItemId(request.libraryItemId!);
      final configuredProxyUri = await Future<Uri?>.value(
        ref.read(configuredFlutterNetworkProxyManagerProvider).proxyUriFor(NetworkProxyTraffic.audio),
      );
      if (!_isCurrent(sessionId, generation)) return;
      final proxyUri = configuredProxyUri?.scheme == 'http' ? configuredProxyUri : null;
      localDataSource = SourceAudioPlaylistDataSource(
        gateway: ref.read(sourceContentGatewayProvider),
        pluginId: request.detail.pluginId,
        initialTrackId: request.chapter.id,
        initialDetail: request.detail,
        initialCatalog: request.libraryItemId == null ? request.firstCatalogPage : null,
      );
      final stateStore = TransientSourceAudioPlaybackStateStore(
        collectionId: request.detail.summary.id,
        initialTrackId: request.chapter.id,
        library: library,
        libraryItemId: itemId,
      );
      localController = AudioPlayerController();
      final serviceObserver = _SourceAudioPlaybackServiceObserver(
        service: this,
        sessionId: sessionId,
        diagnostics: ref.read(appStartupControllerProvider).diagnostics,
      );
      final observer = await AndroidAudioBackgroundService.instance.attach(
        controller: localController,
        onSystemStop: () => stop(sessionId: sessionId),
        onPlatformEvent: serviceObserver.recordStage,
        observer: serviceObserver,
      );
      if (!_isCurrent(sessionId, generation)) {
        localDataSource.cancelPendingLoads();
        await AndroidAudioBackgroundService.instance.detach(localController);
        localController.dispose();
        return;
      }
      final engine = AudioPlayerEngine(
        collectionId: request.detail.summary.id,
        dataSource: localDataSource,
        stateStore: stateStore,
        controller: localController,
        backend: ref.read(sourceAudioPlaybackBackendFactoryProvider)?.call(),
        proxyUri: proxyUri,
        observer: observer,
        prefetchBatchSize: 1,
        prefetchLeadTime: const Duration(seconds: 30),
      );
      _controller = localController;
      _dataSource = localDataSource;
      _engine = engine;
      _screenLifecycle = SourceAudioPlaybackLifecycle(
        controller: localController,
        settings: ref.read(appSettingsProvider),
        onPreferenceChanged: _publishKeepScreenOn,
      );
      state = state.copyWith(controller: localController, clearSetupFailure: true, keepScreenOn: _screenLifecycle!.keepScreenOn);
      await engine.initialize();
    } on Object catch (error) {
      if (!_isCurrent(sessionId, generation)) return;
      localDataSource?.cancelPendingLoads();
      if (localController != null) {
        await AndroidAudioBackgroundService.instance.detach(localController);
        localController.dispose();
      }
      state = state.copyWith(clearController: true, setupFailure: error, playerPresented: false);
    }
  }

  bool _isCurrent(int sessionId, int generation) => !_disposed && state.sessionId == sessionId && generation == _operationGeneration;

  void minimize(int sessionId) {
    if (_disposed || state.sessionId != sessionId) return;
    state = state.copyWith(presentation: SourceAudioPresentation.minimized, exitDecisionRequested: false);
  }

  void expand() {
    if (_disposed || !state.isActive) return;
    state = state.copyWith(presentation: SourceAudioPresentation.expanded);
  }

  Future<void> resolveExitDecision({required int sessionId, required bool continuePlaying, required bool remember}) async {
    if (_disposed || state.sessionId != sessionId) return;
    state = state.copyWith(exitDecisionRequested: false);
    final settings = ref.read(appSettingsProvider);
    if (remember && settings.supports(AppSettingKeys.audioExitBehavior)) {
      try {
        await settings.set(AppSettingKeys.audioExitBehavior, continuePlaying ? 'continue' : 'stop');
      } on Object {
        // The immediate choice remains valid when persistence is degraded.
      }
    }
    if (_disposed || state.sessionId != sessionId) return;
    if (continuePlaying) {
      minimize(sessionId);
    } else {
      await stop(sessionId: sessionId);
    }
  }

  Future<void> _handleExitRequested(int sessionId) async {
    if (_disposed || state.sessionId != sessionId) return;
    final settings = ref.read(appSettingsProvider);
    final behavior = settings.supports(AppSettingKeys.audioExitBehavior) ? settings.get(AppSettingKeys.audioExitBehavior) : 'ask';
    if (behavior == 'continue') {
      minimize(sessionId);
    } else if (behavior == 'stop') {
      await stop(sessionId: sessionId);
    } else if (!_disposed && state.sessionId == sessionId) {
      state = state.copyWith(exitDecisionRequested: true);
    }
  }

  /// Pauses, cancels and releases the matching session before returning.
  Future<void> stop({int? sessionId}) {
    final activeSessionId = state.sessionId;
    if (activeSessionId == null || (sessionId != null && activeSessionId != sessionId)) {
      return _stopFuture ?? Future<void>.value();
    }
    return _stopFuture ??= _beginStop(activeSessionId).whenComplete(() {
      _stopFuture = null;
    });
  }

  Future<void> _beginStop(int sessionId) async {
    _operationGeneration++;
    if (!_disposed && state.sessionId == sessionId) {
      state = const SourceAudioPlaybackState.inactive();
    }
    await _disposeCurrentResources();
    _completeCurrent();
  }

  Future<void> _disposeCurrentResources() async {
    final engine = _engine;
    final controller = _controller;
    final dataSource = _dataSource;
    final screenLifecycle = _screenLifecycle;
    _engine = null;
    _controller = null;
    _dataSource = null;
    _screenLifecycle = null;
    dataSource?.cancelPendingLoads();
    if (controller != null) await controller.pause();
    if (engine != null) await engine.close();
    if (controller != null) {
      await AndroidAudioBackgroundService.instance.detach(controller);
    }
    screenLifecycle?.dispose();
    controller?.dispose();
  }

  void _markPresented(int sessionId) {
    if (_disposed || state.sessionId != sessionId || state.playerPresented) {
      return;
    }
    state = state.copyWith(playerPresented: true);
  }

  void _publishKeepScreenOn() {
    final lifecycle = _screenLifecycle;
    if (_disposed || lifecycle == null || !state.isActive) return;
    state = state.copyWith(keepScreenOn: lifecycle.keepScreenOn);
  }

  Future<void> setKeepScreenOn(bool enabled) => _screenLifecycle?.setKeepScreenOn(enabled) ?? Future<void>.value();

  void _completeCurrent() {
    final completion = _completion;
    _completion = null;
    if (completion != null && !completion.isCompleted) completion.complete();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final engine = _engine;
    if (engine == null) return;
    final normalized = switch (state) {
      AppLifecycleState.resumed => AudioPlayerLifecycleState.resumed,
      AppLifecycleState.inactive => AudioPlayerLifecycleState.inactive,
      AppLifecycleState.paused => AudioPlayerLifecycleState.paused,
      AppLifecycleState.hidden => AudioPlayerLifecycleState.hidden,
      AppLifecycleState.detached => AudioPlayerLifecycleState.detached,
    };
    unawaited(engine.handleLifecycle(normalized));
  }
}

/// Observer owned by the service; it never captures page or route state.
final class _SourceAudioPlaybackServiceObserver extends AudioPlayerObserver {
  const _SourceAudioPlaybackServiceObserver({required this.service, required this.sessionId, required this.diagnostics});

  final SourceAudioPlaybackService service;
  final int sessionId;
  final DiagnosticsManager diagnostics;

  @override
  FutureOr<void> onSessionStarted(String collectionId) {
    service._markPresented(sessionId);
    recordStage('sessionStarted');
  }

  @override
  FutureOr<void> onLifecycleChanged(AudioPlayerLifecycleState state, AudioPlaybackProgress? progress) {
    recordStage('lifecycle:${state.name}');
  }

  @override
  FutureOr<void> onSessionEnded(String collectionId, AudioPlaybackProgress? progress) {
    recordStage('sessionEnded');
  }

  @override
  void onFailure(AudioPlayerFailure failure) {
    service._markPresented(sessionId);
    if (diagnostics.isClosed) return;
    try {
      diagnostics.emit(
        AppDiagnosticEvents.audioPlaybackFailure,
        attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
          'errorCode': DiagnosticValue.string(failure.code),
          'errorLocation': DiagnosticValue.string(failure.location),
          if (failure.debugDetail case final detail?) 'errorText': DiagnosticValue.string(detail),
        }),
      );
    } on Object {
      // Diagnostics are fail-open and never delay playback recovery.
    }
  }

  @override
  FutureOr<void> onExitRequested(AudioPlaybackProgress? progress) => service._handleExitRequested(sessionId);

  void recordStage(String stage) {
    if (diagnostics.isClosed) return;
    final snapshot = service.controller?.snapshot;
    try {
      diagnostics.emit(
        AppDiagnosticEvents.audioPlaybackState,
        attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
          'sessionId': DiagnosticValue.int64(sessionId),
          'stage': DiagnosticValue.string(stage),
          if (snapshot != null) ...<String, DiagnosticValue>{
            'playbackDesired': DiagnosticValue.boolean(snapshot.playbackDesired),
            'playing': DiagnosticValue.boolean(snapshot.playing),
            'buffering': DiagnosticValue.boolean(snapshot.buffering),
            'resourceLoading': DiagnosticValue.boolean(snapshot.resourceLoading),
          },
        }),
      );
    } on Object {
      // Diagnostics are fail-open and never delay playback transitions.
    }
  }
}
