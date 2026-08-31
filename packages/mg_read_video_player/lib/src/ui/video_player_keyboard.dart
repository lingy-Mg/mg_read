/// Package-private keyboard mapping for the video session.
library;

// Cross-file UI helpers are intentionally package-private.
// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../api/controller.dart';

KeyEventResult handleVideoPlayerKeyEvent(
  KeyEvent event,
  VideoPlayerControllerDelegate delegate,
) {
  if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
    return KeyEventResult.ignored;
  }
  if (event.logicalKey == LogicalKeyboardKey.space) {
    unawaited(delegate.playOrPause());
  } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
    unawaited(delegate.skip(const Duration(seconds: -10)));
  } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
    unawaited(delegate.skip(const Duration(seconds: 10)));
  } else if (event.logicalKey == LogicalKeyboardKey.escape) {
    unawaited(delegate.requestExit());
  } else {
    return KeyEventResult.ignored;
  }
  return KeyEventResult.handled;
}
