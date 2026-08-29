/// View-owned observer proxy that authorizes a guarded host pop on exit.
///
/// Responsibilities:
/// - Rebuild PopScope with canPop enabled before forwarding exit to the host.
/// - Preserve every other observer callback unchanged.
///
/// Notes:
/// - The proxy does not navigate; the host remains the route owner.
library;

import 'dart:async';

import '../api/audio_contracts.dart';
import '../api/audio_models.dart';

typedef AudioExitAuthorizer = Future<bool> Function();

final class AudioPlayerObserverProxy extends AudioPlayerObserver {
  const AudioPlayerObserverProxy({required this.authorizeExit, this.delegate});

  final AudioExitAuthorizer authorizeExit;
  final AudioPlayerObserver? delegate;

  @override
  Future<void> onSessionStarted(String collectionId) async {
    await delegate?.onSessionStarted(collectionId);
  }

  @override
  Future<void> onSessionEnded(
    String collectionId,
    AudioPlaybackProgress? progress,
  ) async {
    await delegate?.onSessionEnded(collectionId, progress);
  }

  @override
  Future<void> onTrackChanged(AudioTrack track) async {
    await delegate?.onTrackChanged(track);
  }

  @override
  Future<void> onLifecycleChanged(
    AudioPlayerLifecycleState state,
    AudioPlaybackProgress? progress,
  ) async {
    await delegate?.onLifecycleChanged(state, progress);
  }

  @override
  Future<void> onFailure(AudioPlayerFailure failure) async {
    await delegate?.onFailure(failure);
  }

  @override
  Future<void> onExitRequested(AudioPlaybackProgress? progress) async {
    if (!await authorizeExit()) return;
    await delegate?.onExitRequested(progress);
  }
}
