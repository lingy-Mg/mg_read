/// Explicit catalog selection and post-resolution autoplay transitions.
///
/// Selection owns its target chapter generation. A newer selection, pause or
/// close invalidates the old continuation before it can produce audio.
part of 'audio_player_session.dart';

extension _AudioPlayerSessionSelection on AudioPlayerSession {
  /// Resolves a visible catalog entry only when the listener selects it.
  Future<void> _selectQueueEntry(String trackId) async {
    final playlist = _playlist;
    if (playlist == null ||
        _snapshot.status != AudioPlayerStatus.ready ||
        trackId.isEmpty ||
        trackId == _snapshot.currentTrack?.id) {
      return;
    }
    _recordPlaybackIntent(true);
    _cancelRecoveryTimers(resetAttempts: true);
    final intentRevision = _playbackIntentRevision;
    _emit(_snapshot.copyWith(clearFailure: true));
    _recordOperation('trackSelectionStarted', targetTrackId: trackId);
    final loadedIndex = playlist.tracks.indexWhere(
      (track) => track.id == trackId,
    );
    final generation = ++_generation;
    if (loadedIndex >= 0 && !_trackNeedsRefresh(playlist.tracks[loadedIndex])) {
      _cancelContinuationLoad(retry: false);
      await flushProgress();
      var failureCode = 'audio_track_jump_failed';
      var failureLocation = '已加载章节切换';
      var failureMessage = '无法切换到目标章节，请重试。';
      try {
        _recordOperation('trackJumpStarted', targetTrackId: trackId);
        await backend.jump(loadedIndex);
        if (!_isCurrent(generation)) return;
        _recordOperation('trackJumpReturned', targetTrackId: trackId);
        failureCode = 'audio_selected_autoplay_failed';
        failureLocation = '下一章节自动播放';
        failureMessage = '章节已经切换，但自动播放失败，请重试。';
        if (_playbackDesired && intentRevision == _playbackIntentRevision) {
          _recordOperation('trackPlayStarted', targetTrackId: trackId);
          await backend.play();
          _recordOperation('trackPlayReturned', targetTrackId: trackId);
        }
        if (!_isCurrent(generation)) return;
        if (!_playbackDesired || intentRevision != _playbackIntentRevision) {
          await backend.pause();
        }
      } on Object catch (error) {
        if (!_isCurrent(generation) ||
            intentRevision != _playbackIntentRevision) {
          return;
        }
        final failure = _failureFrom(
          error,
          code: failureCode,
          location: failureLocation,
          message: failureMessage,
        );
        _emit(_snapshot.copyWith(failure: failure));
        _recordOperation('trackSelectionFailed', targetTrackId: trackId);
        await _notify(() => observer?.onFailure(failure));
      }
      return;
    }
    final source = dataSource;
    if (source is! AudioPlaylistQueueDataSource) return;
    _cancelContinuationLoad(retry: true);
    var targetInstalled = false;
    var failureCode = 'audio_selected_resource_unavailable';
    var failureLocation = '所选章节的播放地址';
    var failureMessage = '当前章节暂时无法播放，请稍后重试。';
    await flushProgress();
    _emit(_snapshot.copyWith(resourceLoading: true, clearFailure: true));
    try {
      _recordOperation('resourceLoadStarted', targetTrackId: trackId);
      final track = await source.loadTrackById(collectionId, trackId: trackId);
      if (!_isCurrent(generation) ||
          !_playbackDesired ||
          intentRevision != _playbackIntentRevision) {
        return;
      }
      _recordOperation('resourceLoadReturned', targetTrackId: trackId);
      failureCode = 'audio_backend_open_failed';
      failureLocation = '播放器打开目标章节';
      failureMessage = '目标章节地址已解析，但播放器无法打开该资源。';
      _backendSnapshotsEnabled = false;
      _recordOperation('backendOpenStarted', targetTrackId: trackId);
      final opening = _backendInitializationTail.then<void>((_) async {
        if (!_isCurrent(generation)) return;
        await backend.open(<AudioTrack>[track], initialIndex: 0, play: false);
      });
      _backendInitializationTail = opening.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      );
      await opening;
      if (!_isCurrent(generation)) return;
      _recordOperation('backendOpenReturned', targetTrackId: trackId);
      _playlist = AudioPlaylist(
        collectionId: playlist.collectionId,
        title: playlist.title,
        creator: playlist.creator,
        tracks: <AudioTrack>[track],
        queueEntries: playlist.queueEntries,
      );
      targetInstalled = true;
      failureCode = 'audio_selected_autoplay_failed';
      failureLocation = '下一章节自动播放';
      failureMessage = '章节已经切换，但自动播放失败，请重试。';
      _backendSnapshotsEnabled = true;
      _applyReadySnapshot(backend.snapshot);
      if (_playbackDesired && intentRevision == _playbackIntentRevision) {
        _recordOperation('trackPlayStarted', targetTrackId: trackId);
        await backend.play();
        _recordOperation('trackPlayReturned', targetTrackId: trackId);
      }
      if (!_isCurrent(generation)) return;
      if (!_playbackDesired || intentRevision != _playbackIntentRevision) {
        await backend.pause();
        return;
      }
      _applyReadySnapshot(backend.snapshot, resourceLoading: false);
      _handleBackendError(backend.snapshot.errorMessage);
      _prefetchIfNeeded(0, snapshot: _snapshot);
      await _notify(() => observer?.onTrackChanged(track));
    } on Object catch (error) {
      _backendSnapshotsEnabled = true;
      if (!_isCurrent(generation) ||
          !_playbackDesired ||
          intentRevision != _playbackIntentRevision) {
        return;
      }
      if (!targetInstalled) _playlist = playlist;
      if (!targetInstalled &&
          backend.snapshot.currentIndex >= 0 &&
          backend.snapshot.currentIndex < playlist.tracks.length) {
        _applyReadySnapshot(backend.snapshot);
      }
      _lastPrefetchTriggerTrackId = null;
      _continuationRecoveryPending = true;
      final failure = _failureFrom(
        error,
        code: failureCode,
        location: failureLocation,
        message: failureMessage,
      );
      _emit(_snapshot.copyWith(resourceLoading: false, failure: failure));
      _recordOperation('trackSelectionFailed', targetTrackId: trackId);
      await _notify(() => observer?.onFailure(failure));
      _scheduleRecoveryRetry();
    }
  }

  Future<void> _selectAdjacentQueueEntry(int direction) async {
    if (_snapshot.status != AudioPlayerStatus.ready || direction == 0) return;
    final currentTrackId = _snapshot.currentTrack?.id;
    final currentCatalogIndex = _snapshot.queueEntries.indexWhere(
      (entry) => entry.id == currentTrackId,
    );
    if (currentCatalogIndex < 0) return;
    var targetIndex = currentCatalogIndex + direction;
    while (targetIndex >= 0 && targetIndex < _snapshot.queueEntries.length) {
      final target = _snapshot.queueEntries[targetIndex];
      if (!target.isLocked) {
        await _selectQueueEntry(target.id);
        return;
      }
      targetIndex += direction;
    }
  }
}
