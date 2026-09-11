/// Playback commands, persistence and user interaction actions for the view.
part of 'video_player_view.dart';

extension _VideoPlayerViewActions on _VideoPlayerViewState {
  void _actionNotifyStartup(
    VideoStartupPhase phase, {
    required VideoStartupState state,
    VideoStartupResourceRole? resourceRole,
  }) {
    final observer = widget.observer;
    if (observer == null) return;
    final event = _startupSession.mark(
      phase,
      state: state,
      resourceRole: resourceRole,
    );
    _notify(() => observer.onStartupEvent(event));
  }

  void _actionScheduleFirstFrameTimeout(int generation) {
    _firstFrameTimer?.cancel();
    if (_backendState.firstFrameReady ||
        widget.firstFrameTimeout <= Duration.zero) {
      return;
    }
    _firstFrameTimer = Timer(widget.firstFrameTimeout, () {
      if (_disposed ||
          generation != _episodeGeneration ||
          _backendState.firstFrameReady ||
          _status == VideoPlayerStatus.failure) {
        return;
      }
      _setFailure(
        const VideoPlayerFailure(
          VideoPlayerFailureKind.playback,
          '视频首帧等待超时，请检查网络或切换选集后重试',
          code: 'first_frame_timeout',
          location: '等待视频首帧',
        ),
      );
    });
  }

  void _actionCancelFirstFrameTimeout() {
    _firstFrameTimer?.cancel();
    _firstFrameTimer = null;
  }

  Future<void> _actionPlay() async {
    _playbackDesired = true;
    if (!_lifecycleAllowsPlayback) return;
    if (_backendState.completed) await _actionSeek(Duration.zero);
    await _runPlaybackCommand((backend) async {
      if (!_playbackDesired || !_lifecycleAllowsPlayback) return;
      await backend.play();
    }, code: 'play_failed');
  }

  Future<void> _actionPause() async {
    _playbackDesired = false;
    await _pauseBackend(code: 'pause_failed');
    await _flushProgress(force: true);
  }

  Future<void> _actionPlayOrPause() =>
      _backendState.playing ? _actionPause() : _actionPlay();

  Future<void> _actionSeek(Duration position) async {
    final target = _clampPosition(position, _backendState.duration);
    await _runPlaybackCommand(
      (backend) => backend.seek(target),
      code: 'seek_failed',
    );
    _progressDirty = true;
    _scheduleProgressSave();
    _showControls();
  }

  Future<void> _actionSetRate(double rate) => _runPlaybackCommand(
    (backend) => backend.setRate(rate.clamp(.25, 3).toDouble()),
    code: 'rate_failed',
  );

  Future<void> _actionSetVolume(double volume) async {
    final target = volume.clamp(0, 100).toDouble();
    if (target > 0) _volumeBeforeMute = target;
    await _runPlaybackCommand(
      (backend) => backend.setVolume(target),
      code: 'volume_failed',
    );
    _showControls();
  }

  Future<void> _actionReplay() async {
    if (!_backendState.completed) await _actionSeek(Duration.zero);
    await _actionPlay();
  }

  Future<void> _actionPlayPreviousEpisode() async {
    if (_backendState.position >= const Duration(seconds: 5)) {
      await _actionReplay();
      return;
    }
    await _selectAdjacentEpisode(-1);
  }

  Future<void> _actionSetAutoAdvance(bool enabled) async {
    _update(() => _autoAdvance = enabled);
    _showControls();
    if (enabled && _backendState.completed) {
      _completionGeneration = 0;
      await _handlePlaybackCompleted();
    }
  }

  Future<void> _actionSetControlsLocked(bool locked) async {
    _update(() {
      _controlsLocked = locked;
      _controlsVisible = true;
    });
    _scheduleControlsHide();
  }

  Future<void> _actionSelectEpisode(String groupId, String episodeId) async {
    if (_group?.id == groupId && _episode?.id == episodeId) return;
    final content = _content;
    if (content == null) return;
    final selection = videoSelectionById(content.groups, groupId, episodeId);
    if (selection == null) return;
    _playbackDesired = true;
    _startupSession = VideoStartupSession.create();
    await _openEpisode(
      selection.group,
      selection.episode,
      initialPosition: Duration.zero,
      play: true,
      flushCurrent: true,
    );
  }

  Future<void> _selectAdjacentEpisode(int direction) async {
    final content = _content;
    if (content == null) return;
    final selection = adjacentVideoSelection(
      content.groups,
      _group?.id,
      _episode?.id,
      direction: direction,
    );
    if (selection == null) return;
    await _actionSelectEpisode(selection.group.id, selection.episode.id);
  }

  Future<void> _actionHandlePlaybackCompleted() async {
    final generation = _episodeGeneration;
    if (_completionGeneration == generation) return;
    _completionGeneration = generation;
    final next = adjacentVideoSelection(
      _content?.groups ?? const <VideoEpisodeGroup>[],
      _group?.id,
      _episode?.id,
      direction: 1,
    );
    if (_autoAdvance && next != null) {
      await _actionSelectEpisode(next.group.id, next.episode.id);
      return;
    }
    _playbackDesired = false;
    await _flushProgress(force: true);
    if (_disposed || generation != _episodeGeneration) return;
    _showControls();
  }

  Future<void> _actionCycleFitMode() async {
    _update(() {
      _fitMode = VideoFitMode
          .values[(_fitMode.index + 1) % VideoFitMode.values.length];
      _controlsVisible = true;
    });
    _scheduleControlsHide();
  }

  Future<void> _actionToggleControls() async {
    _update(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _scheduleControlsHide();
  }

  Future<void> _actionRequestFullscreen(bool fullscreen) async {
    _update(() {
      _fullscreenRequested = fullscreen;
      if (!fullscreen) _controlsLocked = false;
      _controlsVisible = true;
    });
    final observer = widget.observer;
    if (observer != null) {
      await _notify(() => observer.onFullscreenRequested(fullscreen));
    }
    if (!_disposed && mounted) _focusNode.requestFocus();
    _scheduleControlsHide();
  }

  Future<void> _actionRequestExit() async {
    if (_fullscreenRequested) {
      await _actionRequestFullscreen(false);
      return;
    }
    if (_exitRequested) return;
    _exitRequested = true;
    _playbackDesired = false;
    await _pauseBackend(code: 'exit_pause_failed', reportFailure: false);
    await _flushProgress(force: true);
    if (_disposed) return;
    _update(() => _exitAuthorized = true);
    await WidgetsBinding.instance.endOfFrame;
    if (_disposed || !mounted) return;
    final route = ModalRoute.of(context);
    final observer = widget.observer;
    if (observer == null) {
      await Navigator.of(context).maybePop();
    } else {
      await _notify(() => observer.onExitRequested(_currentProgress));
    }
    if (!_disposed && mounted && (route?.isCurrent ?? true)) {
      _update(() {
        _exitAuthorized = false;
        _exitRequested = false;
      });
    }
  }

  Future<void> _runPlaybackCommand(
    Future<void> Function(VideoPlaybackBackend backend) command, {
    required String code,
    bool reportFailure = true,
    bool allowWithoutEpisode = false,
  }) async {
    if (_disposed || (!allowWithoutEpisode && _episode == null)) return;
    final backend = _backend;
    final episodeGeneration = _episodeGeneration;
    final operation = _backendCommands.enqueue(() async {
      if (_disposed || !identical(backend, _backend)) return;
      if (!allowWithoutEpisode &&
          (_episode == null || episodeGeneration != _episodeGeneration)) {
        return;
      }
      await command(backend);
    });
    try {
      await operation;
    } on Object {
      if (reportFailure) {
        _notifyFailure(
          VideoPlayerFailure(
            VideoPlayerFailureKind.playback,
            '播放操作失败，请重试',
            code: code,
            location: '执行视频播放操作',
          ),
        );
      }
    }
  }

  Future<void> _actionPauseBackend({
    String code = 'transition_pause_failed',
    bool reportFailure = true,
  }) => _runPlaybackCommand(
    (backend) => backend.pause(),
    code: code,
    reportFailure: reportFailure,
    allowWithoutEpisode: true,
  );

  void _actionScheduleProgressSave() {
    if (_saveTimer != null || _episode == null || _disposed) return;
    _saveTimer = Timer(widget.progressSaveThrottle, () {
      _saveTimer = null;
      unawaited(_flushProgress());
    });
  }

  Future<void> _actionFlushProgress({bool force = false}) async {
    _saveTimer?.cancel();
    _saveTimer = null;
    final progress = _currentProgress;
    if (progress == null || (!force && !_progressDirty)) return;
    _progressDirty = false;
    final store = _activeStateStore ?? widget.stateStore;
    final Future<void> operation = _saveQueue.then((_) => store.save(progress));
    _saveQueue = operation.then<void>((_) {}, onError: (_) {});
    try {
      await operation;
    } on Object {
      _progressDirty = true;
      _notifyFailure(
        const VideoPlayerFailure(
          VideoPlayerFailureKind.persistence,
          '播放进度保存失败',
          code: 'progress_save_failed',
          location: '保存播放进度',
        ),
      );
    }
  }

  VideoPlaybackProgress? get _actionCurrentProgress {
    final group = _group;
    final episode = _episode;
    final contentId = _activeContentId;
    if (group == null || episode == null || contentId == null) return null;
    return VideoPlaybackProgress(
      contentId: contentId,
      groupId: group.id,
      episodeId: episode.id,
      position: _clampPosition(_backendState.position, _backendState.duration),
      duration: _backendState.duration,
    );
  }

  Future<void> _actionPauseForBackground() async {
    await _pauseBackend(code: 'background_pause_failed', reportFailure: false);
    await _flushProgress(force: true);
  }

  void _actionLifecycle(AppLifecycleState state) {
    _lifecycleState = state;
    if (pausesVideoForLifecycle(state)) {
      unawaited(_actionPauseForBackground());
      return;
    }
    if (state == AppLifecycleState.resumed &&
        _playbackDesired &&
        _episode != null &&
        _status != VideoPlayerStatus.failure &&
        !_backendState.playing) {
      unawaited(_actionResumeForForeground());
    }
  }

  bool get _lifecycleAllowsPlayback =>
      _lifecycleState == null || _lifecycleState == AppLifecycleState.resumed;

  Future<void> _actionResumeForForeground() async {
    if (!_playbackDesired || !_lifecycleAllowsPlayback) return;
    await _runPlaybackCommand((backend) async {
      if (!_playbackDesired || !_lifecycleAllowsPlayback) return;
      await backend.play();
    }, code: 'foreground_resume_failed');
  }

  void _actionShowControls() {
    _update(() => _controlsVisible = true);
    _scheduleControlsHide();
  }

  void _actionScheduleControlsHide() {
    _controlsTimer?.cancel();
    _controlsTimer = null;
    if (!_backendState.playing || !_controlsVisible || _disposed) return;
    _controlsTimer = Timer(widget.controlsAutoHideDelay, () {
      if (_disposed || !_backendState.playing) return;
      _update(() => _controlsVisible = false);
    });
  }

  Future<void> _actionShowEpisodes() async {
    final content = _content;
    if (content == null ||
        firstPlayableVideoSelection(content.groups) == null) {
      return;
    }
    _controlsTimer?.cancel();
    final selected = await showVideoEpisodeSheet(
      context: context,
      groups: content.groups,
      activeGroupId: _group?.id,
      activeEpisodeId: _episode?.id,
      playbackState: _backend.state,
    );
    if (!mounted || selected == null) return;
    await _actionSelectEpisode(selected.groupId, selected.episodeId);
    _focusNode.requestFocus();
  }
}
