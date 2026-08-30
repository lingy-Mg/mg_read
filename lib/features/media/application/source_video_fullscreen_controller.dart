/// Host-owned fullscreen lifetime for transient source-video routes.
///
/// The controller serializes platform changes, keeps both portrait and
/// landscape orientations available while fullscreen, and restores the app's
/// default orientation and edge-to-edge system UI before the route is left.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Platform operations used by [SourceVideoFullscreenController].
///
/// This seam is public only so the host behavior can be tested without sending
/// real platform-channel messages.
@visibleForTesting
abstract interface class SourceVideoFullscreenPlatform {
  Future<void> enter();

  Future<void> exit();
}

/// Applies fullscreen through Flutter's system UI and orientation APIs.
final class SystemSourceVideoFullscreenPlatform implements SourceVideoFullscreenPlatform {
  const SystemSourceVideoFullscreenPlatform();

  @override
  Future<void> enter() async {
    await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  Future<void> exit() async {
    await SystemChrome.setPreferredOrientations(const <DeviceOrientation>[]);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }
}

/// Owns one video route's serialized fullscreen platform state.
final class SourceVideoFullscreenController {
  SourceVideoFullscreenController() : _platform = const SystemSourceVideoFullscreenPlatform();

  @visibleForTesting
  SourceVideoFullscreenController.withPlatform(this._platform);

  final SourceVideoFullscreenPlatform _platform;

  Future<void> _tail = Future<void>.value();
  bool _fullscreen = false;
  bool _restoreNeeded = false;
  bool _closed = false;

  /// Applies the latest player fullscreen intent in request order.
  Future<void> setFullscreen(bool fullscreen) {
    if (_closed) return Future<void>.value();
    return _append(() async {
      if (_closed || _fullscreen == fullscreen) return;
      if (fullscreen) {
        _restoreNeeded = true;
        await _platform.enter();
        _fullscreen = true;
        return;
      }
      await _restore();
    });
  }

  /// Rejects later intents and restores normal app chrome after pending work.
  Future<void> restoreAndClose() {
    _closed = true;
    return _append(_restore);
  }

  Future<void> _restore() async {
    if (!_restoreNeeded && !_fullscreen) return;
    await _platform.exit();
    _fullscreen = false;
    _restoreNeeded = false;
  }

  Future<void> _append(Future<void> Function() operation) {
    final next = _tail.then<void>((_) => operation(), onError: (_, _) => operation());
    _tail = next;
    return next;
  }
}
