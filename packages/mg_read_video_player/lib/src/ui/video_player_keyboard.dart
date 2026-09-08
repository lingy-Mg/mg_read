/// Package-private keyboard mapping for the video session.
library;

// Cross-file UI helpers are intentionally package-private.
// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../api/controller.dart';
import '../api/models.dart';

KeyEventResult handleVideoPlayerKeyEvent(
  KeyEvent event,
  VideoPlayerControllerDelegate delegate,
  VideoPlayerSnapshot snapshot,
) {
  if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
    return KeyEventResult.ignored;
  }
  if (HardwareKeyboard.instance.isControlPressed ||
      HardwareKeyboard.instance.isAltPressed ||
      HardwareKeyboard.instance.isMetaPressed) {
    return KeyEventResult.ignored;
  }
  final key = event.logicalKey;
  if (snapshot.controlsLocked) {
    if (key == LogicalKeyboardKey.escape) {
      unawaited(delegate.setControlsLocked(false));
      return KeyEventResult.handled;
    }
    return KeyEventResult.handled;
  }
  final repeated = event is KeyRepeatEvent;
  if ((key == LogicalKeyboardKey.space || key == LogicalKeyboardKey.keyK) &&
      !repeated) {
    unawaited(delegate.playOrPause());
  } else if (key == LogicalKeyboardKey.arrowLeft ||
      key == LogicalKeyboardKey.keyJ) {
    unawaited(delegate.skip(const Duration(seconds: -10)));
  } else if (key == LogicalKeyboardKey.arrowRight ||
      key == LogicalKeyboardKey.keyL) {
    unawaited(delegate.skip(const Duration(seconds: 10)));
  } else if (key == LogicalKeyboardKey.arrowUp) {
    unawaited(delegate.setVolume(snapshot.volume + 5));
  } else if (key == LogicalKeyboardKey.arrowDown) {
    unawaited(delegate.setVolume(snapshot.volume - 5));
  } else if (key == LogicalKeyboardKey.keyM && !repeated) {
    unawaited(delegate.toggleMute());
  } else if (key == LogicalKeyboardKey.keyF && !repeated) {
    unawaited(delegate.requestFullscreen(!snapshot.fullscreenRequested));
  } else if (key == LogicalKeyboardKey.keyN && !repeated) {
    unawaited(delegate.playNextEpisode());
  } else if (key == LogicalKeyboardKey.keyP && !repeated) {
    unawaited(delegate.playPreviousEpisode());
  } else if (key == LogicalKeyboardKey.home) {
    unawaited(delegate.seek(Duration.zero));
  } else if (key == LogicalKeyboardKey.end) {
    unawaited(delegate.seek(snapshot.duration));
  } else if (key == LogicalKeyboardKey.escape) {
    unawaited(delegate.requestExit());
  } else {
    return KeyEventResult.ignored;
  }
  return KeyEventResult.handled;
}
