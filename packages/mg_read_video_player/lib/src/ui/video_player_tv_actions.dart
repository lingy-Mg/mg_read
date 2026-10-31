/// Remote key routing owned by the mounted player session.
/// Directions seek only on the stage; focused controls retain normal traversal.
/// Back dismisses controls before flushing progress through the normal exit.
part of 'video_player_view.dart';

extension _VideoPlayerTvActions on _VideoPlayerViewState {
  void _tvBack() {
    if (_controlsVisible && _status == VideoPlayerStatus.ready) {
      _controlsTimer?.cancel();
      _update(() => _controlsVisible = false);
      _focusNode.requestFocus();
    } else {
      unawaited(requestExit());
    }
  }

  void _tvReveal() {
    _controlsTimer?.cancel();
    _update(() => _controlsVisible = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _controlsVisible) _tvPlayFocus.requestFocus();
    });
  }

  KeyEventResult _handleTvKey(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final repeated = event is KeyRepeatEvent;
    if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.goBack) {
      if (!repeated) _tvBack();
      return KeyEventResult.handled;
    }
    if (_status != VideoPlayerStatus.ready) return KeyEventResult.ignored;
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
    } else if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight) {
      unawaited(
        skip(Duration(seconds: key == LogicalKeyboardKey.arrowLeft ? -10 : 10)),
      );
    } else if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowUp) {
      if (!repeated) _tvReveal();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }
}
