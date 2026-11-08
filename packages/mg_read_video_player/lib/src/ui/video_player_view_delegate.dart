/// Controller commands and stage callback wiring for the mounted video view.
///
/// Responsibilities:
/// - Compose the stage with existing session fields and command callbacks.
/// - Route host commands through the same actions as package-owned controls.
///
/// Notes:
/// - This mixin is private to the player view library and does not own state.
part of 'video_player_view.dart';

mixin _VideoPlayerViewDelegate on State<VideoPlayerView>
    implements VideoPlayerControllerDelegate {
  _VideoPlayerViewState get _player => this as _VideoPlayerViewState;

  @override
  Widget build(BuildContext context) => VideoPlayerStage(
    controller: _player._controller,
    backend: _player._backend,
    snapshot: _player._snapshot,
    activeEpisode: _player._episode,
    tvMode: widget.tvMode,
    topRightAction: widget.topRightAction,
    tvPlayFocus: _player._tvPlayFocus,
    focusNode: _player._focusNode,
    exitAuthorized: _player._exitAuthorized,
    onPopAttempt: () =>
        widget.tvMode ? _player._tvBack() : unawaited(requestExit()),
    onKeyEvent: _player._handleKey,
    onToggleControls: toggleControls,
    onRetry: _player._retry,
    onExit: requestExit,
    onPlayOrPause: playOrPause,
    onSeek: seek,
    onRate: setRate,
    onEnhancementMode: setEnhancementMode,
    onReplay: replay,
    onPreviousEpisode: playPreviousEpisode,
    onNextEpisode: playNextEpisode,
    onAutoAdvance: setAutoAdvance,
    onControlsLocked: setControlsLocked,
    onInteractionStart: _player._handleInteractionStart,
    onInteractionEnd: _player._handleInteractionEnd,
    onControlsHoverChanged: _player._handleControlsHoverChanged,
    onFit: cycleFitMode,
    onEpisodes: _player._showEpisodes,
    onFullscreen: requestFullscreen,
    onReadBrightness: _player._hostBridge.readBrightness,
    onBrightness: _player._hostBridge.setBrightness,
    onReadSystemVolume: _player._hostBridge.readSystemVolume,
    onSystemVolume: _player._hostBridge.setSystemVolume,
  );

  @override
  Future<void> play() => _player._actionPlay();

  @override
  Future<void> pause() => _player._actionPause();

  @override
  Future<void> playOrPause() => _player._actionPlayOrPause();

  @override
  Future<void> seek(Duration position) => _player._actionSeek(position);

  @override
  Future<void> skip(Duration delta) =>
      _player._actionSeek(_player._backendState.position + delta);

  @override
  Future<void> setRate(double rate) => _player._actionSetRate(rate);

  @override
  Future<void> setVolume(double volume) => _player._actionSetVolume(volume);

  @override
  Future<void> setEnhancementMode(VideoEnhancementMode mode) async {
    final backend = _player._backend;
    if (backend is! MediaKitVideoPlaybackBackend) return;
    await backend.setEnhancementMode(mode);
  }

  @override
  Future<void> toggleMute() => setVolume(
    _player._backendState.volume > 0
        ? 0
        : _player._volumeBeforeMute.clamp(1, 100).toDouble(),
  );

  @override
  Future<void> replay() => _player._actionReplay();

  @override
  Future<void> playPreviousEpisode() => _player._actionPlayPreviousEpisode();

  @override
  Future<void> playNextEpisode() => _player._selectAdjacentEpisode(1);

  @override
  Future<void> setAutoAdvance(bool enabled) =>
      _player._actionSetAutoAdvance(enabled);

  @override
  Future<void> setControlsLocked(bool locked) =>
      _player._actionSetControlsLocked(locked);

  @override
  Future<void> selectEpisode(String groupId, String episodeId) =>
      _player._actionSelectEpisode(groupId, episodeId);

  @override
  Future<void> cycleFitMode() => _player._actionCycleFitMode();

  @override
  Future<void> toggleControls() => _player._actionToggleControls();

  @override
  Future<void> requestFullscreen(bool fullscreen) =>
      _player._actionRequestFullscreen(fullscreen);

  @override
  Future<void> requestExit() => _player._actionRequestExit();

  @override
  Future<void> handleRemoteKey(VideoRemoteKey key) async {
    if (!_player.widget.tvMode) return;
    if (ModalRoute.of(_player.context)?.isCurrent == false) {
      switch (key) {
        case VideoRemoteKey.back:
          await Navigator.of(_player.context, rootNavigator: true).maybePop();
        case VideoRemoteKey.confirm:
          _activateFocusedControl();
        case VideoRemoteKey.up:
          _focusTvControl(TraversalDirection.up);
        case VideoRemoteKey.down:
          _focusTvControl(TraversalDirection.down);
        case VideoRemoteKey.left:
          _focusTvControl(TraversalDirection.left);
        case VideoRemoteKey.right:
          _focusTvControl(TraversalDirection.right);
      }
      return;
    }
    switch (key) {
      case VideoRemoteKey.up:
        if (!_focusTvControl(TraversalDirection.up)) _player._tvReveal();
      case VideoRemoteKey.down:
        if (!_focusTvControl(TraversalDirection.down)) _player._tvReveal();
      case VideoRemoteKey.left:
        if (!_focusTvControl(TraversalDirection.left)) {
          await skip(const Duration(seconds: -10));
        }
      case VideoRemoteKey.right:
        if (!_focusTvControl(TraversalDirection.right)) {
          await skip(const Duration(seconds: 10));
        }
      case VideoRemoteKey.confirm:
        if (!_activateFocusedControl()) await playOrPause();
      case VideoRemoteKey.back:
        _player._tvBack();
    }
  }

  bool _activateFocusedControl() {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null ||
        Actions.maybeFind<ActivateIntent>(
              context,
              intent: const ActivateIntent(),
            ) ==
            null) {
      return false;
    }
    Actions.invoke(context, const ActivateIntent());
    return true;
  }

  bool _focusTvControl(TraversalDirection direction) {
    if (!_player._controlsVisible || _player._focusNode.hasPrimaryFocus) {
      return false;
    }
    return FocusManager.instance.primaryFocus?.focusInDirection(direction) ??
        false;
  }

  void _handleInteractionStart() {
    _player._controlsTimer?.cancel();
    if (!_player._controlsVisible) {
      _player._update(() => _player._controlsVisible = true);
    }
  }

  void _handleControlsHoverChanged(bool hovering) {
    _player._pointerOverControls = hovering;
    if (hovering) {
      _handleInteractionStart();
    } else {
      _handleInteractionEnd();
    }
  }

  void _handleInteractionEnd() => _player._scheduleControlsHide();
}
