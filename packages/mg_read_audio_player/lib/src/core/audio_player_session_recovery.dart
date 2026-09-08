part of 'audio_player_session.dart';

extension _AudioPlayerSessionRecovery on AudioPlayerSession {
  void _recordPlaybackIntent(bool desired) {
    _playbackDesired = desired;
    _playbackIntentRevision++;
  }

  bool _trackNeedsRefresh(AudioTrack track) {
    if (track.resourcePolicy != AudioResourcePolicy.refreshable) return false;
    final expiresAt = track.expiresAt;
    return expiresAt == null ||
        !expiresAt.isAfter(_clock().toUtc().add(const Duration(seconds: 10)));
  }

  void _prefetchIfNeeded(
    int currentIndex, {
    required AudioPlayerSnapshot snapshot,
  }) {
    final playlist = _playlist;
    final source = dataSource;
    final leadTime = prefetchLeadTime;
    final remaining = snapshot.duration - snapshot.position;
    final mediaLead = leadTime == null
        ? Duration.zero
        : Duration(
            microseconds: (leadTime.inMicroseconds * snapshot.rate).round(),
          );
    final isPrefetchWindow = switch (leadTime) {
      null =>
        playlist != null &&
            currentIndex + prefetchThreshold >= playlist.tracks.length - 1,
      _ =>
        playlist != null &&
            currentIndex == playlist.tracks.length - 1 &&
            (snapshot.duration <= Duration.zero ||
                remaining <= mediaLead ||
                backend.snapshot.completed),
    };
    if (playlist == null ||
        source is! AudioPlaylistContinuationDataSource ||
        !isPrefetchWindow ||
        _prefetchRequest != null ||
        _closing ||
        _closed) {
      return;
    }
    final triggerTrackId = playlist.tracks[currentIndex].id;
    if (_lastPrefetchTriggerTrackId == triggerTrackId) return;
    _lastPrefetchTriggerTrackId = triggerTrackId;
    _startContinuationLoad(
      source,
      generation: _generation,
      afterTrackId: playlist.tracks.last.id,
    );
  }

  Future<void> _startContinuationLoad(
    AudioPlaylistContinuationDataSource source, {
    required int generation,
    required String afterTrackId,
  }) {
    final requestRevision = ++_continuationRequestRevision;
    late final Future<void> request;
    request =
        _loadFollowingTracks(
          source,
          generation: generation,
          requestRevision: requestRevision,
          afterTrackId: afterTrackId,
        ).whenComplete(() {
          if (identical(_prefetchRequest, request)) _prefetchRequest = null;
        });
    _prefetchRequest = request;
    return request;
  }

  Future<void> _loadFollowingTracks(
    AudioPlaylistContinuationDataSource source, {
    required int generation,
    required int requestRevision,
    required String afterTrackId,
  }) async {
    try {
      final loaded = await source.loadFollowingTracks(
        collectionId,
        afterTrackId: afterTrackId,
        limit: prefetchBatchSize,
      );
      if (!_isContinuationCurrent(generation, requestRevision)) return;
      _continuationRecoveryPending = false;
      if (loaded.isEmpty) {
        if (backend.snapshot.completed) _recordPlaybackIntent(false);
        _cancelRecoveryTimers(resetAttempts: true);
        return;
      }
      final playlist = _playlist;
      if (playlist == null || playlist.tracks.last.id != afterTrackId) return;
      final knownIds = playlist.tracks.map((track) => track.id).toSet();
      final additions = loaded
          .where(
            (track) =>
                track.id.trim().isNotEmpty &&
                track.resource.hasScheme &&
                knownIds.add(track.id),
          )
          .toList(growable: false);
      if (additions.isEmpty ||
          !_isContinuationCurrent(generation, requestRevision)) {
        return;
      }
      final intentRevision = _playbackIntentRevision;
      final wasCompleted = backend.snapshot.completed;
      final previousTailIndex = playlist.tracks.length - 1;
      await backend.append(additions);
      if (!_isContinuationCurrent(generation, requestRevision)) return;
      _playlist = AudioPlaylist(
        collectionId: playlist.collectionId,
        title: playlist.title,
        creator: playlist.creator,
        tracks: <AudioTrack>[...playlist.tracks, ...additions],
        queueEntries: playlist.queueEntries,
      );
      _applyReadySnapshot(backend.snapshot);
      if (wasCompleted &&
          _playbackDesired &&
          intentRevision == _playbackIntentRevision) {
        if (backend.snapshot.currentIndex == previousTailIndex) {
          await backend.next();
        }
        if (_playbackDesired && intentRevision == _playbackIntentRevision) {
          await backend.play();
        }
      }
      _cancelRecoveryTimers(resetAttempts: true);
    } on Object catch (error) {
      if (!_isContinuationCurrent(generation, requestRevision)) return;
      _continuationRecoveryPending = true;
      _lastPrefetchTriggerTrackId = null;
      final failure = AudioPlayerFailure(
        code: 'audio_continuation_failed',
        location: '下一章节恢复',
        message: '下一章节暂时无法继续，播放器会在网络恢复后重试。',
        debugDetail: _boundedDebugDetail(error),
      );
      _emit(_snapshot.copyWith(failure: failure));
      unawaited(_notify(() => observer?.onFailure(failure)));
      if (_playbackDesired) _scheduleRecoveryRetry();
    }
  }

  bool _isContinuationCurrent(int generation, int requestRevision) =>
      _isCurrent(generation) && requestRevision == _continuationRequestRevision;

  void _cancelContinuationLoad({required bool retry}) {
    _continuationRequestRevision++;
    if (dataSource case final AudioPlayerCancellationDataSource source) {
      source.cancelPendingLoads();
    }
    _prefetchRequest = null;
    _lastPrefetchTriggerTrackId = null;
    _continuationRecoveryPending = retry;
  }

  /// Retries interrupted work without overriding a later user pause.
  Future<void> recover() {
    _cancelRecoveryTimers(resetAttempts: true);
    return _runRecovery(singleFlight: true);
  }

  Future<void> _runRecovery({required bool singleFlight}) {
    final active = _recoveryRequest;
    if (singleFlight && active != null) return active;
    final request = _recoverInterruptedPlayback();
    _recoveryRequest = request;
    return request.whenComplete(() {
      if (identical(_recoveryRequest, request)) _recoveryRequest = null;
    });
  }

  Future<void> _recoverInterruptedPlayback() async {
    if (_closing || _closed || !_playbackDesired) return;
    final activeContinuation = _prefetchRequest;
    if (activeContinuation != null) {
      try {
        await activeContinuation.timeout(const Duration(milliseconds: 500));
      } on TimeoutException {
        // A stalled Runtime request is superseded below through the source's
        // cancellation boundary instead of blocking foreground recovery.
      } on Object {
        // The regular continuation failure path records the retry state.
      }
      if (_closing || _closed || !_playbackDesired) return;
      if (_snapshot.playing &&
          !_snapshot.buffering &&
          !backend.snapshot.completed &&
          !_continuationRecoveryPending) {
        return;
      }
    }
    _cancelContinuationLoad(retry: _continuationRecoveryPending);
    final intentRevision = _playbackIntentRevision;
    final hasBackendFailure =
        _snapshot.failure?.code == 'audio_backend_error' ||
        (backend.snapshot.errorMessage?.trim().isNotEmpty ?? false);
    final shouldReopen =
        hasBackendFailure ||
        (_snapshot.status == AudioPlayerStatus.ready &&
            !backend.snapshot.completed &&
            (_snapshot.buffering || !_snapshot.playing));
    if (shouldReopen && dataSource is AudioPlaylistQueueDataSource) {
      await _reopenCurrentTrack(
        dataSource as AudioPlaylistQueueDataSource,
        intentRevision: intentRevision,
      );
      return;
    }
    final playlist = _playlist;
    final source = dataSource;
    if (playlist == null || source is! AudioPlaylistContinuationDataSource) {
      return;
    }
    if (!_continuationRecoveryPending && !backend.snapshot.completed) return;
    await _startContinuationLoad(
      source,
      generation: _generation,
      afterTrackId: playlist.tracks.last.id,
    );
  }

  Future<void> _reopenCurrentTrack(
    AudioPlaylistQueueDataSource source, {
    required int intentRevision,
  }) async {
    final playlist = _playlist;
    final track = _snapshot.currentTrack;
    if (playlist == null || track == null) return;
    final position = _snapshot.position;
    final generation = ++_generation;
    try {
      final refreshed = await source.loadTrackById(
        collectionId,
        trackId: track.id,
      );
      if (!_isCurrent(generation) ||
          !_playbackDesired ||
          intentRevision != _playbackIntentRevision) {
        return;
      }
      _backendSnapshotsEnabled = false;
      await backend.open(<AudioTrack>[refreshed], initialIndex: 0, play: false);
      if (!_isCurrent(generation)) return;
      if (position > Duration.zero) await backend.seek(position);
      if (!_isCurrent(generation)) return;
      _playlist = AudioPlaylist(
        collectionId: playlist.collectionId,
        title: playlist.title,
        creator: playlist.creator,
        tracks: <AudioTrack>[refreshed],
        queueEntries: playlist.queueEntries,
      );
      _backendSnapshotsEnabled = true;
      _applyReadySnapshot(backend.snapshot);
      if (!_playbackDesired || intentRevision != _playbackIntentRevision) {
        await backend.pause();
        return;
      }
      await backend.play();
      if (!_isCurrent(generation)) return;
      _applyReadySnapshot(backend.snapshot);
      _handleBackendError(backend.snapshot.errorMessage);
      _prefetchIfNeeded(0, snapshot: _snapshot);
    } on Object catch (error) {
      if (!_isCurrent(generation)) return;
      _backendSnapshotsEnabled = true;
      _playlist = playlist;
      _continuationRecoveryPending = true;
      final failure = AudioPlayerFailure(
        code: 'audio_recovery_failed',
        location: '当前章节恢复',
        message: '当前章节暂时无法恢复，播放器会稍后重试。',
        debugDetail: _boundedDebugDetail(error),
      );
      _emit(_snapshot.copyWith(failure: failure));
      unawaited(_notify(() => observer?.onFailure(failure)));
      _scheduleRecoveryRetry();
    }
  }

  void _observeRecoveryState(AudioPlaybackBackendSnapshot value) {
    if (!_playbackDesired || _closing || _closed) {
      _cancelRecoveryTimers(resetAttempts: true);
      return;
    }
    final hasError = value.errorMessage?.trim().isNotEmpty ?? false;
    if (hasError || value.completed) {
      _stallTimer?.cancel();
      _stallTimer = null;
      _scheduleRecoveryRetry();
      return;
    }
    if (value.playing && !value.buffering) {
      if (!_continuationRecoveryPending) {
        _cancelRecoveryTimers(resetAttempts: true);
      }
      return;
    }
    _stallTimer ??= Timer(recoveryStallTimeout, () {
      _stallTimer = null;
      if (_playbackDesired) _scheduleRecoveryRetry();
    });
  }

  void _scheduleRecoveryRetry() {
    if (_closing ||
        _closed ||
        !_playbackDesired ||
        _recoveryTimer != null ||
        _recoveryRequest != null ||
        _recoveryAttempt >= recoveryBackoff.length) {
      return;
    }
    final delay = recoveryBackoff[_recoveryAttempt++];
    _recoveryTimer = Timer(delay, () {
      _recoveryTimer = null;
      if (_closing || _closed || !_playbackDesired) return;
      unawaited(
        _runRecovery(singleFlight: true).whenComplete(() {
          if (_playbackDesired &&
              (_continuationRecoveryPending ||
                  _snapshot.failure?.code == 'audio_backend_error' ||
                  _snapshot.buffering ||
                  !_snapshot.playing)) {
            _scheduleRecoveryRetry();
          }
        }),
      );
    });
  }

  void _cancelRecoveryTimers({required bool resetAttempts}) {
    _stallTimer?.cancel();
    _recoveryTimer?.cancel();
    _stallTimer = null;
    _recoveryTimer = null;
    if (resetAttempts) _recoveryAttempt = 0;
  }
}
