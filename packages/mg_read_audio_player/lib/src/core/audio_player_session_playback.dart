/// Intent-aware playback activation and its observable postcondition.
///
/// A transport Future returning only proves that the command was accepted. The
/// session keeps resource loading active until the backend publishes
/// `playing=true`, preventing Android audio focus from being released in the
/// Future/stream race that is more visible in AOT release builds.
part of 'audio_player_session.dart';

extension _AudioPlayerSessionPlayback on AudioPlayerSession {
  Future<bool> _playBackendAndConfirm({
    required int generation,
    required int intentRevision,
    required String? targetTrackId,
    required String failureCode,
    required String failureLocation,
    required String failureMessage,
  }) async {
    if (!_isPlaybackStartCurrent(generation, intentRevision)) return false;
    if (!_snapshot.resourceLoading) {
      _emit(_snapshot.copyWith(resourceLoading: true));
    }
    _recordOperation('trackPlayStarted', targetTrackId: targetTrackId);
    await backend.play();
    _recordOperation('trackPlayReturned', targetTrackId: targetTrackId);

    final stopwatch = Stopwatch()..start();
    final pollInterval =
        recoveryStallTimeout < const Duration(milliseconds: 100)
        ? recoveryStallTimeout
        : const Duration(milliseconds: 100);
    while (_isPlaybackStartCurrent(generation, intentRevision)) {
      final backendState = backend.snapshot;
      final backendError = backendState.errorMessage?.trim();
      if (backendError != null && backendError.isNotEmpty) {
        throw AudioPlayerLoadException(
          code: failureCode,
          location: failureLocation,
          message: failureMessage,
          debugDetail: _boundedDebugDetail(backendError),
        );
      }
      if (backendState.playing) {
        _applyReadySnapshot(backendState, resourceLoading: false);
        if (_snapshot.failure?.code == failureCode ||
            _snapshot.failure?.code == 'audio_continuation_failed' ||
            _snapshot.failure?.code == 'audio_recovery_failed' ||
            _snapshot.failure?.code == 'audio_backend_error') {
          _emit(_snapshot.copyWith(clearFailure: true));
        }
        return true;
      }
      if (stopwatch.elapsed >= recoveryStallTimeout) {
        throw AudioPlayerLoadException(
          code: failureCode,
          location: failureLocation,
          message: failureMessage,
          debugDetail: _playbackStartStateDetail(backendState),
        );
      }
      await Future<void>.delayed(pollInterval);
    }
    return false;
  }

  bool _isPlaybackStartCurrent(int generation, int intentRevision) =>
      _isCurrent(generation) &&
      _playbackDesired &&
      intentRevision == _playbackIntentRevision;

  String _playbackStartStateDetail(AudioPlaybackBackendSnapshot state) =>
      'play() 已返回，但 ${recoveryStallTimeout.inMilliseconds}ms 内未收到 '
      'playing=true；currentIndex=${state.currentIndex}, '
      'playing=${state.playing}, buffering=${state.buffering}, '
      'completed=${state.completed}, positionMs=${state.position.inMilliseconds}, '
      'durationMs=${state.duration.inMilliseconds}';
}
