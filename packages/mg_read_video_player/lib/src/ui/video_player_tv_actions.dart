/// Remote key routing owned by the mounted player session.
/// Directions seek only on the stage; focused controls retain normal traversal.
/// Back dismisses controls before flushing progress through the normal exit.
part of 'video_player_view.dart';

extension _VideoPlayerTvActions on _VideoPlayerViewState {
  void _handleLifecycle(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _tvSeekGesture.cancel();
    _actionLifecycle(state);
  }

  void _handleTvSeekFocus() {
    if (!_focusNode.hasPrimaryFocus) _tvSeekGesture.cancel();
  }

  KeyEventResult _handleKey(FocusNode _, KeyEvent event) => widget.tvMode
      ? _handleTvKey(event)
      : handleVideoPlayerKeyEvent(event, this, _snapshot);

  void _tvHideControls() {
    _controlsTimer?.cancel();
    _focusNode.requestFocus();
    _update(() => _controlsVisible = false);
  }

  void _tvBack() {
    _tvSeekGesture.cancel();
    if (_controlsVisible && _status == VideoPlayerStatus.ready) {
      _tvHideControls();
    } else {
      unawaited(requestExit());
    }
  }

  void _tvReveal() {
    _tvSeekGesture.cancel();
    _controlsTimer?.cancel();
    _update(() => _controlsVisible = true);
    _scheduleControlsHide();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _controlsVisible) _tvPlayFocus.requestFocus();
    });
  }

  KeyEventResult _handleTvKey(KeyEvent event) {
    final key = event.logicalKey;
    final seekKey =
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight;
    if (event is KeyUpEvent && seekKey) {
      final active = _tvSeekGesture.isActive;
      _tvSeekGesture.release(key == LogicalKeyboardKey.arrowLeft ? -1 : 1);
      return active ? KeyEventResult.handled : KeyEventResult.ignored;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (!seekKey) _tvSeekGesture.cancel();
    final repeated = event is KeyRepeatEvent;
    if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.goBack) {
      if (!repeated) _tvBack();
      return KeyEventResult.handled;
    }
    if (_status != VideoPlayerStatus.ready) return KeyEventResult.ignored;
    if (_controlsVisible) _scheduleControlsHide();
    if (key == LogicalKeyboardKey.mediaPlayPause) {
      if (!repeated) unawaited(playOrPause());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.contextMenu) {
      if (!repeated) _tvReveal();
      return KeyEventResult.handled;
    }
    // Child buttons/sliders must receive their own activation and directions.
    if (!_focusNode.hasPrimaryFocus) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.gameButtonA) {
      if (!repeated) unawaited(playOrPause());
    } else if (seekKey) {
      if (!repeated) {
        _tvSeekGesture.press(key == LogicalKeyboardKey.arrowLeft ? -1 : 1);
      }
    } else if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowUp) {
      if (!repeated) _tvReveal();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }
}
