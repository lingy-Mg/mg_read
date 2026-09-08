/// Public, route-independent owner for one audio playback session.
///
/// Responsibilities:
/// - Own the private session state machine and its playback backend.
/// - Expose one stable controller to any number of transient UI surfaces.
/// - Forward application lifecycle signals without depending on a Widget.
/// - Close playback, pending source work and persistence exactly once.
///
/// Notes:
/// - Hosts that supply a controller retain responsibility for disposing it.
/// - A controlled [AudioPlayerView] never closes this engine.
library;

import '../backend/media_kit_audio_backend.dart';
import '../core/audio_player_session.dart';
import 'audio_contracts.dart';
import 'audio_controller.dart';
import 'audio_models.dart';

/// Owns one audio player session independently from presentation lifetimes.
final class AudioPlayerEngine {
  factory AudioPlayerEngine({
    required String collectionId,
    required AudioPlayerDataSource dataSource,
    required AudioPlaybackStateStore stateStore,
    AudioPlayerObserver? observer,
    AudioPlayerController? controller,
    AudioPlaybackBackend? backend,
    Uri? proxyUri,
    Duration saveInterval = const Duration(milliseconds: 800),
    bool autoplay = true,
    int prefetchThreshold = 1,
    int prefetchBatchSize = 3,
    Duration? prefetchLeadTime,
    Duration recoveryStallTimeout = const Duration(seconds: 8),
    List<Duration> recoveryBackoff = const <Duration>[
      Duration(seconds: 1),
      Duration(seconds: 3),
      Duration(seconds: 8),
      Duration(seconds: 20),
    ],
    DateTime Function()? clock,
  }) {
    final effectiveController = controller ?? AudioPlayerController();
    final session = AudioPlayerSession(
      collectionId: collectionId,
      dataSource: dataSource,
      stateStore: stateStore,
      backend: backend ?? AudioMediaKitPlaybackBackend(proxyUri: proxyUri),
      controller: effectiveController,
      observer: observer,
      saveInterval: saveInterval,
      autoplay: autoplay,
      prefetchThreshold: prefetchThreshold,
      prefetchBatchSize: prefetchBatchSize,
      prefetchLeadTime: prefetchLeadTime,
      recoveryStallTimeout: recoveryStallTimeout,
      recoveryBackoff: recoveryBackoff,
      clock: clock,
    );
    return AudioPlayerEngine._(
      controller: effectiveController,
      session: session,
      ownsController: controller == null,
    );
  }

  AudioPlayerEngine._({
    required this.controller,
    required this._session,
    required this._ownsController,
  });

  final AudioPlayerController controller;
  final AudioPlayerSession _session;
  final bool _ownsController;
  Future<void>? _initialization;
  Future<void>? _closeFuture;

  AudioPlayerSnapshot get snapshot => controller.snapshot;
  bool get isClosed => _closeFuture != null;

  /// Initializes the session once. Later callers join the same operation.
  Future<void> initialize() => _initialization ??= _session.initialize();

  /// Flushes or resumes session work for the supplied app lifecycle state.
  Future<void> handleLifecycle(AudioPlayerLifecycleState state) {
    if (_closeFuture != null) return Future<void>.value();
    return _session.handleLifecycle(state);
  }

  /// Stops all playback and source work. Safe to invoke repeatedly.
  Future<void> close() => _closeFuture ??= _beginClose();

  Future<void> _beginClose() async {
    await _session.close();
    if (_ownsController) controller.dispose();
  }
}
